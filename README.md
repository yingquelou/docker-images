# docker images

预构建的 Debian / Ubuntu rootfs 与 Alpine 基础镜像，发布在 GitHub Packages 的容器仓库
`ghcr.io/yingquelou/*`。所有包都是 public，可直接 `docker pull`。

## 镜像

| 包 | 内容 | 标签 | 平台 |
| --- | --- | --- | --- |
| `ghcr.io/yingquelou/debian` | Debian 各发布套件的 rootfs | `<suite>`、`latest`、`lts` | 该套件官方可用架构（见下） |
| `ghcr.io/yingquelou/ubuntu` | Ubuntu 各发布套件的 rootfs | `<suite>`、`latest`、`lts` | 该套件官方可用架构（见下） |
| `ghcr.io/yingquelou/alpine` | Alpine 官方 minirootfs | `<version>`、`<major.minor>`、`latest` | 官方全部架构 |
| `ghcr.io/yingquelou/wsl` | 基于 `alpine:latest` 的 WSL 镜像 | `alpine` | linux/amd64 |

每个套件/版本只发布**一个多架构标签**，架构是索引里的 platform 条目，不存在
`<suite>-amd64`、`<suite>-i386`、`<version>-<arch>` 这类逐架构标签。

## 标签语义

- **`<suite>`**：套件代号，如 `debian:trixie`、`debian:bookworm`、`ubuntu:noble`、
  `ubuntu:jammy`。一个标签对应一个包含该套件全部已构建架构的索引。
- **`latest`**：官方最新稳定版。Debian 取 `dists/stable` 的套件（当前 `trixie`）；
  Ubuntu 取 `meta-release` 中 `Supported: 1` 的最高版本（当前 `resolute`）。
- **`lts`**：官方仍在维护的 LTS。Debian 取 `dists/oldstable`（当前 `bookworm`，遵循其 LTS
  项目实际维护的套件）；Ubuntu 取 `meta-release-lts` 中 `Supported: 1` 的最高版本。
- **`alpine:<version>`**：完整补丁版本（如 `3.24.4`）；**`alpine:<major.minor>`**（如 `3.24`）
  指向该系列最新补丁；**`alpine:latest`** 指向官方最新稳定版。Alpine 没有 LTS，不发布 `alpine:lts`。
- `latest` / `lts` 每次发布时从官方元数据动态解析；若目标版本本次没有构建，标签不会移动。

## 架构覆盖

| 发行版 | 架构 |
| --- | --- |
| Debian trixie | amd64、arm64、armel、armhf、i386、ppc64el、riscv64、s390x |
| Debian bookworm | 上述 + mips64el、mipsel |
| Debian bullseye | amd64、arm64、armhf、i386 |
| Debian buster…potato | amd64、i386 |
| Debian buzz…slink | i386 |
| Ubuntu trusty | amd64、arm64、armhf、i386、powerpc、ppc64el |
| Ubuntu xenial | 上述 + s390x |
| Ubuntu bionic | amd64、arm64、armhf、i386、ppc64el、s390x |
| Ubuntu focal 及之后 | amd64、arm64、armhf、i386、ppc64el、riscv64、s390x |
| Ubuntu 其他归档套件 | amd64、i386 |
| Alpine | x86_64、x86、aarch64、armhf、armv7、ppc64le、s390x、riscv64、loongarch64 |

平台名：`x86_64→linux/amd64`、`x86→linux/386`、`aarch64→linux/arm64`、
`armhf→linux/arm/v6`、`armv7→linux/arm/v7`，其余同名；Debian 的 armel 为 `linux/arm/v5`，
ppc64el 为 `linux/ppc64le`。

## 拉取与使用

```bash
# Debian / Ubuntu rootfs（CMD 为 bash）
docker pull ghcr.io/yingquelou/debian:bookworm
docker run --rm -it ghcr.io/yingquelou/debian:bookworm bash

# 指定架构
docker pull --platform linux/arm64 ghcr.io/yingquelou/ubuntu:noble

# Alpine（CMD 为 sh），apk 可直接使用
docker run --rm -it ghcr.io/yingquelou/alpine:3.24.4 sh

# WSL 镜像
docker pull ghcr.io/yingquelou/wsl:alpine
```

镜像内 `apt` / `dpkg`、`apk` 均完整可用：构建阶段只清理缓存、文档和语言包，
不删除 `/var/lib/dpkg`、`/etc/apt/sources.list*`、`/lib/apk/db` 或 `/etc/apk/repositories`。

## 已知限制

- Debian buzz…slink 早于 apt 的诞生，只保留 dpkg 状态库，无法要求 apt 可用。
- Ubuntu warty/hoary 的 i386 使用模拟运行，构建很慢，但可用。
- Alpine 没有 LTS 发布线，因此没有 `alpine:lts`。
- 镜像不含 buildx attestation（`provenance` 已关闭）。
- 历史上的逐架构标签（Ubuntu 的 `<suite>-amd64` / `-i386`、`debian:lenny-i386`、
  `alpine:3.24.2-x86*`）已冻结、不再更新；`latest` / `lts` 不再指向 `debian:forky`、
  `ubuntu:stonking` 这类历史标签。完整清单见
  [docs/operations.md](docs/operations.md#冻结标签)。

## 维护者文档

构建脚本、瘦身与包管理保证见 [docs/build.md](docs/build.md)；
Actions 矩阵、架构解析、qemu/skopeo 依赖与发布机制见 [docs/ci.md](docs/ci.md)；
权限配置、手动运行、核对与排障见 [docs/operations.md](docs/operations.md)。
