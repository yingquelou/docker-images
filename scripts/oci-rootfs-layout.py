#!/usr/bin/env python3
"""把一个套件/版本的多份 rootfs tarball 合成为一个多架构 OCI 镜像布局。

为什么不走 docker import + 逐架构 docker push：
GHCR 不允许单独删除被索引引用的清单，先推 <tag>-<arch> 再合并清单会把逐架构标签
永久留在包里。这里直接合成 OCI layout（层就是原始 rootfs tarball，字节与
docker import 的输入完全一致），再用 skopeo copy --all 推送，注册表里只会出现
一个指向多架构索引的标签。

每个架构生成一个 manifest（config 里的 Cmd 与 docker import 的结果对齐：
debian/ubuntu 为 ["/bin/sh","-c","bash"]，alpine 为 ["/bin/sh","-c","sh"]），
顶层 index.json 用一个带 ref.name 注解的索引描述符指向它们。

用法：
  python3 scripts/oci-rootfs-layout.py --out /tmp/layout --ref trixie --distro debian \\
      --arch amd64=/path/debian-trixie-amd64-rootfs.tar.gz \\
      --arch i386=/path/debian-trixie-i386-rootfs.tar.gz
"""

import argparse
import gzip
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

OCI_MANIFEST = "application/vnd.oci.image.manifest.v1+json"
OCI_INDEX = "application/vnd.oci.image.index.v1+json"
OCI_CONFIG = "application/vnd.oci.image.config.v1+json"
OCI_LAYER_GZIP = "application/vnd.oci.image.layer.v1.tar+gzip"
OCI_LAYER_TAR = "application/vnd.oci.image.layer.v1.tar"

# 架构名 → (os, 平台架构, variant)。未知架构按原名作为平台架构名。
PLATFORMS = {
    "amd64": ("linux", "amd64", ""),
    "x86_64": ("linux", "amd64", ""),
    "i386": ("linux", "386", ""),
    # 决策 E：新构建的 x86 统一用标准 linux/386，旧的 alpine:3.24.2-x86 保持原样
    "x86": ("linux", "386", ""),
    "arm64": ("linux", "arm64", ""),
    "aarch64": ("linux", "arm64", ""),
    # Debian/Ubuntu 的 armhf 是 ARMv7 硬浮点；Alpine 的 armhf 是 ARMv6（见 platform_for）
    "armhf": ("linux", "arm", "v7"),
    "armv7": ("linux", "arm", "v7"),
    "armel": ("linux", "arm", "v5"),
    "arm": ("linux", "arm", "v5"),
    "mips": ("linux", "mips", ""),
    "mipsel": ("linux", "mipsle", ""),
    "mips64el": ("linux", "mips64le", ""),
    "powerpc": ("linux", "ppc", ""),
    "ppc64": ("linux", "ppc64", ""),
    "ppc64el": ("linux", "ppc64le", ""),
    "ppc64le": ("linux", "ppc64le", ""),
    "s390": ("linux", "s390", ""),
    "s390x": ("linux", "s390x", ""),
    "riscv64": ("linux", "riscv64", ""),
    "alpha": ("linux", "alpha", ""),
    "hppa": ("linux", "parisc", ""),
    "m68k": ("linux", "m68k", ""),
    "sh4": ("linux", "sh", ""),
    "sparc": ("linux", "sparc", ""),
    "sparc64": ("linux", "sparc64", ""),
    "ia64": ("linux", "ia64", ""),
    "loong64": ("linux", "loong64", ""),
    "loongarch64": ("linux", "loongarch64", ""),
    "x32": ("linux", "amd64", "x32"),
}

# Alpine 官方 armhf 目标是 ARMv6，与 Debian/Ubuntu 的 armhf（ARMv7）不同
ALPINE_PLATFORMS = {
    "armhf": ("linux", "arm", "v6"),
}

TAG_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}")


def fail(message):
    print("[oci] ERROR: %s" % message, file=sys.stderr)
    sys.exit(1)


def dumps(obj):
    return json.dumps(obj, separators=(",", ":"), sort_keys=True).encode()


def platform_for(arch, distro):
    if distro == "alpine" and arch in ALPINE_PLATFORMS:
        return ALPINE_PLATFORMS[arch]
    return PLATFORMS.get(arch, ("linux", arch, ""))


def write_blob(out, data):
    digest = hashlib.sha256(data).hexdigest()
    path = os.path.join(out, "blobs", "sha256", digest)
    if not os.path.exists(path):
        tmp = path + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    return digest, len(data)


def copy_layer(out, path):
    """把 tarball 原样复制进 blobs，顺便算出压缩后摘要。"""
    sha = hashlib.sha256()
    size = 0
    tmp = os.path.join(out, "blobs", "sha256", "layer.tmp")
    with open(path, "rb") as src, open(tmp, "wb") as dst:
        while True:
            chunk = src.read(1024 * 1024)
            if not chunk:
                break
            sha.update(chunk)
            size += len(chunk)
            dst.write(chunk)
    digest = sha.hexdigest()
    os.replace(tmp, os.path.join(out, "blobs", "sha256", digest))
    return digest, size


def is_gzip(path):
    with open(path, "rb") as fh:
        return fh.read(2) == b"\x1f\x8b"


def diff_id(path, compressed):
    """rootfs 解压后的摘要（OCI config 的 diff_ids 要求未压缩层的 sha256）。"""
    sha = hashlib.sha256()
    opener = gzip.open if compressed else open
    with opener(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            sha.update(chunk)
    return sha.hexdigest()


def created_time(path):
    epoch = os.environ.get("SOURCE_DATE_EPOCH", "").strip()
    try:
        stamp = int(epoch) if epoch else int(os.stat(path).st_mtime)
    except (TypeError, ValueError):
        stamp = 0
    return datetime.fromtimestamp(stamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_manifest(out, arch, tarball, distro, source):
    os_name, oci_arch, variant = platform_for(arch, distro)
    if not os.path.isfile(tarball):
        fail("找不到 tarball：%s" % tarball)

    compressed = is_gzip(tarball)
    layer_digest, layer_size = copy_layer(out, tarball)
    uncompressed_digest = diff_id(tarball, compressed)
    created = created_time(tarball)

    cmd = ["/bin/sh", "-c", "sh" if distro == "alpine" else "bash"]
    config = {
        "created": created,
        "architecture": oci_arch,
        "os": os_name,
        "config": {
            "Cmd": cmd,
            "Labels": {"org.opencontainers.image.source": source},
        },
        "rootfs": {"type": "layers", "diff_ids": ["sha256:" + uncompressed_digest]},
        "history": [
            {"created": created, "created_by": "rootfs tarball import"},
        ],
    }
    if variant:
        config["variant"] = variant

    config_digest, config_size = write_blob(out, dumps(config))
    manifest = {
        "schemaVersion": 2,
        "mediaType": OCI_MANIFEST,
        "config": {
            "mediaType": OCI_CONFIG,
            "digest": "sha256:" + config_digest,
            "size": config_size,
        },
        "layers": [
            {
                "mediaType": OCI_LAYER_GZIP if compressed else OCI_LAYER_TAR,
                "digest": "sha256:" + layer_digest,
                "size": layer_size,
            }
        ],
    }
    manifest_digest, manifest_size = write_blob(out, dumps(manifest))

    platform = {"os": os_name, "architecture": oci_arch}
    if variant:
        platform["variant"] = variant
    print("[oci]   %s/%s%s <- %s" % (
        os_name, oci_arch, ("/" + variant) if variant else "", tarball))
    return {
        "mediaType": OCI_MANIFEST,
        "digest": "sha256:" + manifest_digest,
        "size": manifest_size,
        "platform": platform,
    }


def main(argv):
    parser = argparse.ArgumentParser(
        description="合成单标签多架构 OCI 镜像布局",
    )
    parser.add_argument("--out", required=True, help="输出目录（会被当作 OCI layout 根目录）")
    parser.add_argument("--ref", required=True, help="布局内的引用名，即要推送的标签名")
    parser.add_argument("--distro", required=True, choices=["debian", "ubuntu", "alpine"],
                        help="决定导入后的 CMD：debian/ubuntu=bash，alpine=sh")
    parser.add_argument("--source", default="https://github.com/yingquelou/docker-images",
                        help="org.opencontainers.image.source 标签值")
    parser.add_argument("--arch", action="append", default=[], metavar="ARCH=PATH",
                        help="架构与对应 rootfs tarball，可重复")
    args = parser.parse_args(argv)

    if not TAG_RE.fullmatch(args.ref):
        fail("引用名不是合法标签：%s" % args.ref)
    if not args.arch:
        fail("至少需要一个 --arch ARCH=PATH")

    entries = []
    seen = {}
    for spec in args.arch:
        if "=" not in spec:
            fail("--arch 需要 ARCH=PATH 形式：%s" % spec)
        arch, tarball = spec.split("=", 1)
        arch = arch.strip()
        if not arch:
            fail("--arch 的架构名为空：%s" % spec)
        if arch in seen:
            fail("架构 %s 重复：%s 与 %s" % (arch, seen[arch], tarball))
        seen[arch] = tarball
        entries.append((arch, tarball))

    out = args.out
    os.makedirs(os.path.join(out, "blobs", "sha256"), exist_ok=True)
    # 目录必须是空的，避免上一次的残留索引混进新布局
    for name in ("index.json", "oci-layout"):
        path = os.path.join(out, name)
        if os.path.exists(path):
            os.remove(path)

    descriptors = []
    for arch, tarball in sorted(entries):
        descriptors.append(build_manifest(out, arch, tarball, args.distro, args.source))

    index = {
        "schemaVersion": 2,
        "mediaType": OCI_INDEX,
        "manifests": descriptors,
    }
    index_digest, index_size = write_blob(out, dumps(index))

    # skopeo 通过 index.json 里的 ref.name 注解解析 oci:<dir>:<ref>
    root = {
        "schemaVersion": 2,
        "mediaType": OCI_INDEX,
        "manifests": [
            {
                "mediaType": OCI_INDEX,
                "digest": "sha256:" + index_digest,
                "size": index_size,
                "annotations": {"org.opencontainers.image.ref.name": args.ref},
            }
        ],
    }
    with open(os.path.join(out, "index.json"), "wb") as fh:
        fh.write(dumps(root))
    with open(os.path.join(out, "oci-layout"), "wb") as fh:
        fh.write(dumps({"imageLayoutVersion": "1.0.0"}))

    print("[oci] %s: %d 个架构 → %s" % (args.ref, len(descriptors), out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
