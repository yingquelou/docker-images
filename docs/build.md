# 构建与本地发布

本仓库有两条构建线：Debian / Ubuntu rootfs 由 debootstrap 或 mmdebstrap 生成；Alpine 直接使用官方
minirootfs。产物统一发布为 OCI 多架构索引。

## 脚本

| 脚本 | 用途 |
| --- | --- |
| `scripts/debian-debootstrap.sh` | Debian 主线套件（trixie / bookworm / bullseye）的 rootfs |
| `scripts/debian-mmdebstrap.sh` | Debian 主线套件的 mmdebstrap 版本 |
| `scripts/debian-ancient.py` | Debian 归档套件（buster 及更早，含 buzz…slink），只构建 i386 |
| `scripts/ubuntu-debootstrap.sh` | Ubuntu 套件（含归档套件）的 rootfs |
| `scripts/ubuntu-mmdebstrap.sh` | Ubuntu 主线套件的 mmdebstrap 版本 |
| `scripts/publish-rootfs.sh` | 把 rootfs tarball 合成多架构索引并推送到 GHCR |
| `scripts/oci-rootfs-layout.py` | 生成 OCI image layout（层就是原始 tarball） |
| `scripts/publish-alpine-image.sh` | 下载官方 minirootfs，合成为一个多架构索引并推送 |
| `scripts/suite-arches.py` | 从官方 Release 解析每个套件实际可用的架构 |

## 本地构建

```bash
# 只构建 rootfs（产物在 ./debian、./ubuntu，日志在同级 logs/）
ONLY="trixie buster" ARCHES="amd64 i386" bash scripts/debian-debootstrap.sh
ONLY="noble jammy"   ARCHES="amd64 i386" bash scripts/ubuntu-debootstrap.sh

# Debian 归档套件（i386）
sudo env ONLY="buster" ARCHES="i386" python3 scripts/debian-ancient.py

# Alpine 基础镜像（默认官方最新稳定版 + 全部官方架构）
scripts/publish-alpine-image.sh
```

构建脚本支持 `ONLY`（套件过滤）、`ARCHES`（架构过滤）、`LIST_SUITES=1` / `--list-suites`
（只打印套件清单，供 CI 生成矩阵）、`LIST_MODERN=1`（只打印主线套件）。

## 发布

```bash
docker login ghcr.io
scripts/publish-rootfs.sh all --dir debian --latest debian:trixie --lts debian:bookworm
scripts/publish-rootfs.sh all --dir ubuntu --latest ubuntu:resolute --lts ubuntu:resolute
DRY_RUN=1 scripts/publish-rootfs.sh all --dir debian   # 只预览命令
```

发布逻辑：

1. 按 `distro + suite` 分组 tarball，用 `oci-rootfs-layout.py` 生成一个 OCI image layout：
   层是原始压缩 tarball，`config.Cmd` 为 `["/bin/sh","-c","bash"]`（Alpine 为 `sh`）。
2. `skopeo copy --all oci:<layout>:<tag> docker://…` 推送。子清单以 digest 形式上传，仓库里只出现
   一个 `<suite>` / `<version>` 标签，不产生 `<suite>-<arch>` 临时标签。
3. `latest` / `lts` / `<major.minor>` 用 `skopeo copy --all` 从目标标签复制，digest 不变。
4. GHCR 推送带 3 次指数退避重试。

## 体积与包管理器

rootfs 构建阶段只清理缓存、文档、语言包和临时文件，保证包管理器可直接使用：

- `debootstrap` 版通过 `tar -X exclude.txt` 去掉 `var/cache/apt/archives`、`var/lib/apt/lists`、
  `var/cache/debconf`、`/usr/share/{doc,man,info,groff,locale,i18n/locales}`、日志与
  `machine-id`；**不删** `/var/lib/dpkg`、`/etc/apt/sources.list*`、`extended_states`。
  `apt update` 会按 sources 重新拉取索引，安装/升级/卸载不受影响。
- `mmdebstrap` 版使用 dpkg 的 `path-exclude/path-include`（保留 man1-9 与 copyright /
  changelog），apt 的数据库与源配置完整保留。
- Alpine 使用官方 minirootfs，`apk` 与 `/lib/apk/db`、`/etc/apk/repositories` 原样保留。
- Debian 远古套件（buzz/rex/bo/hamm/slink）年代早于 apt，只保留 dpkg 状态库，无法要求 apt 可用，
  这是历史产物本身的限制。

## 跨架构

- 非本机架构通过 qemu-user binfmt 模拟；CI 里由 `docker/setup-qemu-action` 与
  `qemu-user-binfmt` 提供。
- Ubuntu 非 amd64/i386 架构走 `ports.ubuntu.com`（可用 `UBUNTU_PORTS_MIRROR` 覆盖）。
- warty / hoary 的 i386 是 2004–2005 年的 glibc，在新内核上会触发 ld.so 断言；Ubuntu 26.04 的
  qemu-user 不再带 i386 目标，CI 会临时下载 Debian bookworm 的 `qemu-i386-static` 并注册 binfmt，
  构建完成后撤销。这两个套件的 i386 因此明显慢于其他架构。
