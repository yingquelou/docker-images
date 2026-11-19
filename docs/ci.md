# CI 与发布流程

两个 workflow，均可手动触发；`rootfs-images.yml` 默认全量构建，`alpine-image.yml` 负责 Alpine
基础镜像与 `wsl:alpine`。

## `.github/workflows/rootfs-images.yml`

- 触发：`workflow_dispatch`。默认 `distributions=both`，即 Debian 全部 18 个套件、Ubuntu 全部
  44 个套件；架构默认按官方 `Release` 逐套件解析（`arches` 留空）。
- 输入：`distributions`（both/debian/ubuntu）、`suites`（空格/逗号分隔，留空=全集）、
  `arches`（留空=官方该套件的全部架构）、`builder`（debootstrap/mmdebstrap）、`publish`。
- 矩阵：每个套件一个 job（`max-parallel: 20`，超时 360 分钟），套件内的架构串行构建；62 个
  套件约 177 个套件×架构组合。全量实测墙钟 38 分 53 秒。
- 架构解析：`prepare` 用 `LIST_SUITES=1` / `--list-suites` 读套件清单，用 `suite-arches.py` 读
  `dists/<suite>/Release` 的 `Architectures:`；过滤掉 `kfreebsd-*`、`hurd-*`、`ia64`、`s390`
  以及 `amd64v3`（会把 amd64 变成两个平台条目）。
- `latest` / `lts`：每次运行从官方元数据动态解析，不写死：
  - `debian:latest`：`dists/stable/Release` 的 `Codename`；`debian:lts`：`dists/oldstable/Release`。
  - `ubuntu:latest`：`meta-release` 中 `Supported: 1` 的最高版本；
    `ubuntu:lts`：`meta-release-lts` 中 `Supported: 1` 的最高版本。
- 依赖：`debootstrap`、`mmdebstrap`、`debian-archive-keyring`、`ubuntu-keyring`、
  `qemu-user-binfmt`、`skopeo`；`qemu-user-static` 在 Ubuntu 26.04 上已成为虚拟包，不再直接安装。
- qemu：`docker/setup-qemu-action` 注册常见架构，`qemu-user-binfmt` 补 mipsel/ppc 等；
  warty/hoary 的 i386 额外使用 Debian 的 `qemu-i386-static`。
- 发布：每个 build job 在本套件全部架构完成后，用 `publish-rootfs.sh push` 生成并推送一个
  `<suite>` 多架构索引；不推逐架构标签。`merge` job 只把已发布的套件索引复制成 `latest` / `lts`。
- 重试：GHCR 推送与别名复制有 3 次指数退避；构建失败按套件 job 重跑（Actions「Re-run failed
  jobs」），不整体重来。
- artifact：只上传 `artifacts/*.tsv` 与 `*/logs/**`，不保留 rootfs tarball。

## `.github/workflows/alpine-image.yml`

- 触发：push 到 `master` 且改动 `Dockerfile.alpine`、`alpine.ico` 或 workflow 文件时只重建
  `wsl:alpine`；`workflow_dispatch` 可同时重建基础镜像。
- 输入：`alpine_version`（留空=官方最新稳定版）、`alpine_arches`（留空=官方全部架构）、
  `build_base`、`update_latest`、`platforms`（`wsl:alpine` 的目标平台，默认 `linux/amd64`）。
- 基础镜像：`publish-alpine-image.sh` 从 `dl-cdn.alpinelinux.org` 下载各架构 minirootfs，
  合成一个 `<version>` 索引；`<major.minor>` 与 `latest` 仅在该版本是系列/官方最新时前进。
- `wsl:alpine`：`docker/build-push-action` 构建，`provenance: false`，单架构清单，无 attestation。
- 缓存：基础镜像没有编译环节，耗时主要是 9 个 minirootfs 的下载（约 20 MB）与推送；
  buildx cache 不适用，按版本缓存 tarball 只能省十几秒，且会占用 Actions 缓存配额，
  收益低于维护成本，因此不加缓存。

## 发布机制

推送使用 OCI image layout + `skopeo copy --all`，不是 `docker import` + buildx：

- 层是原始压缩 tarball，保持 `docker import` 等价的内容与体积。
- 子清单按 digest 上传，注册表里只出现一个套件/版本标签；GHCR 不允许删除被索引引用的清单，
  因此不能“先推逐架构标签再清理”。
- 索引的平台条目由 `oci-rootfs-layout.py` 根据架构生成（x86_64→amd64、x86→386、armel→arm/v5、
  armhf→arm/v7、ppc64el→ppc64le 等）。

## 实测记录

- 全量 `rootfs-images`（2026-11-18）：prepare + 62 个 build job + merge，**单次运行 64/64 全部成功**，
  墙钟 38 分 53 秒。
- 单套件 bookworm：9 架构索引，压缩层 31.63 MB，解包 94.5 MB，`apt update` / `apt install` 正常。
- 全量运行中镜像偶发 502（aliyun 的单个 deb）；脚本会清理并重试该架构，最多 2 次。
