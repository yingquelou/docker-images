#!/usr/bin/env python3
"""解析某个 Debian/Ubuntu 套件官方实际提供的架构集合。

数据来源是官方发布源的 Release 文件里的 `Architectures:` 字段（与
dists/<suite>/binary-<arch> 目录一一对应）：

  Debian  https://deb.debian.org/debian/dists/<suite>/Release
  Ubuntu  https://archive.ubuntu.com/ubuntu/dists/<suite>/Release
          https://ports.ubuntu.com/ubuntu-ports/dists/<suite>/Release（合并取并集）

只有“现代套件”（官方仍在提供的发布线）才做完整的官方架构解析；古早归档套件
按项目约定只构建实际仍可获取的 amd64/i386，不做额外折腾，由 --legacy 标记。

用法：
  python3 scripts/suite-arches.py --distro debian --suite trixie --modern
  python3 scripts/suite-arches.py --distro ubuntu --suite trusty --modern
  python3 scripts/suite-arches.py --distro debian --suite buster --legacy
"""

import argparse
import sys
import urllib.request

SOURCES = {
    "debian": ["https://deb.debian.org/debian/dists/{suite}/Release"],
    "ubuntu": [
        "https://archive.ubuntu.com/ubuntu/dists/{suite}/Release",
        "https://ports.ubuntu.com/ubuntu-ports/dists/{suite}/Release",
    ],
}

# 归档套件的降级覆盖：只构建官方归档里仍可下载的 amd64/i386
LEGACY_ARCHES = ["amd64", "i386"]

# 不是 Linux 用户态（无法用 debootstrap/qemu 构建）
NON_LINUX_PREFIXES = ("kfreebsd-", "hurd-")
# 不单独发布的架构：
#   s390/ia64  qemu-user 没有可用的用户态模拟
#   amd64v3     Ubuntu 26.04 起的 x86-64-v3 包变体，与 amd64 共用 OCI 平台；
#               两条 linux/amd64 清单会让 docker pull 产生歧义，故按基线 amd64 覆盖
UNSUPPORTED_ARCHES = {"s390", "ia64", "amd64v3"}


def fetch(url, attempts=3):
    last = None
    for _ in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                return resp.read().decode("utf-8", "replace")
        except Exception as exc:  # noqa: BLE001 - 网络失败只记录，换下一个源
            last = exc
    print("WARN: %s: %s" % (url, last), file=sys.stderr)
    return ""


def parse_architectures(text):
    for line in text.splitlines():
        if line.startswith("Architectures:"):
            return line.split(":", 1)[1].split()
    return []


def official_arches(distro, suite):
    arches = []
    for template in SOURCES[distro]:
        url = template.format(suite=suite)
        for arch in parse_architectures(fetch(url)):
            if arch == "all":
                continue
            if arch.startswith(NON_LINUX_PREFIXES):
                continue
            if arch in UNSUPPORTED_ARCHES:
                continue
            if arch not in arches:
                arches.append(arch)
    return arches


def main(argv):
    parser = argparse.ArgumentParser(description="输出套件官方架构集合")
    parser.add_argument("--distro", required=True, choices=sorted(SOURCES))
    parser.add_argument("--suite", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--modern", action="store_true",
                      help="官方仍在维护的发布线：解析官方 Release 的全部架构")
    mode.add_argument("--legacy", action="store_true",
                      help="古早归档套件：只构建实际可下载的 amd64/i386")
    args = parser.parse_args(argv)

    if args.legacy:
        arches = list(LEGACY_ARCHES)
    else:
        arches = official_arches(args.distro, args.suite)
        if not arches:
            print("ERROR: 没有解析到 %s/%s 的官方架构" % (args.distro, args.suite),
                  file=sys.stderr)
            return 1
    print(" ".join(arches))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
