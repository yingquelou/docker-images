# docker images

Debian / Ubuntu rootfs 构建脚本与 Alpine WSL 镜像的构建、发布仓库。所有镜像发布到
GitHub Packages 的**容器（container）**类型仓库 `ghcr.io/yingquelou/*`。

## 镜像清单

| 包 | 构建来源 | 标签 | 平台 |
| --- | --- | --- | --- |
| `ghcr.io/yingquelou/debian` | `scripts/debian-debootstrap.sh`、`scripts/debian-mmdebstrap.sh`、`scripts/debian-ancient.py` | `<suite>`、`latest`、`lts` | 该套件官方全部架构（现代）/ amd64+i386（归档，见下） |
| `ghcr.io/yingquelou/ubuntu` | `scripts/ubuntu-debootstrap.sh`、`scripts/ubuntu-mmdebstrap.sh` | `<suite>`、`latest`、`lts` | 该套件官方全部架构（现代）/ amd64+i386（归档，见下） |
| `ghcr.io/yingquelou/alpine` | `scripts/publish-alpine-image.sh`（官方 alpine-minirootfs） | `<version>`、`<major.minor>`、`latest` | 官方全部架构（见下） |
| `ghcr.io/yingquelou/wsl` | `Dockerfile.alpine`（`FROM ghcr.io/yingquelou/alpine:latest`） | `alpine` | linux/amd64（单一镜像清单，无 attestation） |

- 每个套件/版本只发布**一个多架构标签**，架构只作为镜像索引里的 platform 条目存在，
  不生成 `<suite>-amd64`、`<suite>-i386`、`<version>-<arch>` 这类逐架构标签。
  构建仍可逐架构进行：`scripts/oci-rootfs-layout.py` 把同一套件的 tarball 合成一个
  OCI layout（层就是原始 rootfs tarball），再用 `skopeo copy --all` 推送，
  注册表里只会出现合并后的多架构清单。
- 镜像 `CMD` 与原先 `docker image import` 的结果一致：debian/ubuntu 为 `bash`，
  alpine 为 `sh`。rootfs tarball 不作为 Actions artifact 保留，只上传构建日志。
- 标签由 workflow 每次运行时从官方元数据动态解析，不写死版本号：
  - `debian:latest`：`deb.debian.org` 的 `dists/stable/Release` 里的 `Codename`。
  - `debian:lts`：`dists/oldstable/Release` 里的 `Codename`（Debian LTS 覆盖 oldstable；
    Debian 没有 Ubuntu 那样的独立 LTS 发布线，这里以其 LTS 项目实际维护的套件为准）。
  - `ubuntu:latest`：`changelogs.ubuntu.com/meta-release` 中 `Supported: 1` 的最高版本；
    `ubuntu:lts`：`meta-release-lts` 中 `Supported: 1` 的最高版本。
  - `alpine:<major.minor>`（如 `3.24`）：该系列官方最新补丁；只有构建的正是最新补丁时才前进，
    旧补丁构建不会让别名回退。
  - `alpine:latest`：`latest-stable/releases/` 下最新的官方 minirootfs 版本；Alpine 没有 LTS，故不发布 `alpine:lts`。
- 若解析出的官方版本本次没有构建（例如尚未加入构建脚本的套件），对应 `latest`/`lts`
  不会移动，并在 Actions 日志里给出警告。
- Debian/Ubuntu 只使用套件代号，不使用 `13`、`26.04` 这类纯数字版本别名。

### Alpine 架构

架构从官方发布源枚举并逐项 HEAD 校验该版本确实可下载（当前 3.24 系列共 9 个）：
`x86_64`、`x86`、`aarch64`、`armhf`、`armv7`、`ppc64le`、`s390x`、`riscv64`、`loongarch64`。
平台映射：`x86_64→linux/amd64`、`x86→linux/386`、`aarch64→linux/arm64`、
`armhf→linux/arm/v6`、`armv7→linux/arm/v7`，其余同名。

### Debian / Ubuntu 架构覆盖

架构集合不写死：`scripts/suite-arches.py` 读取官方 `dists/<suite>/Release` 的
`Architectures:` 字段（Debian 用 `deb.debian.org`，Ubuntu 合并 `archive.ubuntu.com` 与
`ports.ubuntu.com`），再过滤掉非 Linux 与无法构建的项。现代套件覆盖官方全部架构，
古早归档套件只按实际仍可下载的 amd64/i386 降级构建。

| 发行版 | 套件 | 架构 |
| --- | --- | --- |
| debian | trixie（stable） | amd64、arm64、armel、armhf、i386、ppc64el、riscv64、s390x（8） |
| debian | bookworm（oldstable） | amd64、arm64、armel、armhf、i386、mips64el、mipsel、ppc64el、s390x（9） |
| debian | bullseye（oldoldstable） | amd64、arm64、armhf、i386（4） |
| debian | buster…potato（10 个归档套件） | amd64、i386（降级；缺哪个由脚本按 Release 跳过） |
| debian | buzz/hamm/bo/rex/slink（5 个远古） | i386（`debian-ancient.py` 的构建器限制） |
| ubuntu | trusty | amd64、arm64、armhf、i386、powerpc、ppc64el（6） |
| ubuntu | xenial | 上述 + s390x（7） |
| ubuntu | bionic | amd64、arm64、armhf、i386、ppc64el、s390x（6） |
| ubuntu | focal/jammy/noble/plucky/questing/resolute | amd64、arm64、armhf、i386、ppc64el、riscv64、s390x（7） |
| ubuntu | 35 个归档套件 | amd64、i386（降级） |

- 跨架构构建依赖 qemu-user binfmt：Actions 的 build job 用 `docker/setup-qemu-action`
  注册常见处理器，再用 `qemu-user-binfmt`（Ubuntu 26.04 起它取代虚拟包 `qemu-user-static`，
  带 `qemu-user` 静态二进制与 `/usr/lib/binfmt.d` 定义）补齐 mipsel/ppc 等未覆盖的架构，
  `debootstrap`/`mmdebstrap` 在目标 chroot 里直接执行目标架构二进制。
- Ubuntu 的非 amd64/i386 架构从 `https://ports.ubuntu.com/ubuntu-ports` 取包
  （可用 `UBUNTU_PORTS_MIRROR` 覆盖），amd64/i386 仍走原有镜像。
- 不单独发布的架构：`amd64v3`（Ubuntu 26.04 起的 x86-64-v3 包变体，与 amd64 共用
  OCI 平台，单列会让 `docker pull` 在两条 amd64 清单间产生歧义）、`ia64`/`s390`
  （qemu-user 无可用用户态模拟）、`kfreebsd-*`/`hurd-*`（非 Linux 用户态）。
- 平台映射：`armel→linux/arm/v5`、`armhf→linux/arm/v7`（Debian/Ubuntu）或
  `linux/arm/v6`（Alpine）、`mipsel→linux/mipsle`、`mips64el→linux/mips64le`、
  `powerpc→linux/ppc`、`ppc64el→linux/ppc64le`，其余同名。

## 镜像瘦身与包管理

rootfs 构建阶段只清理缓存、文档、语言包和临时文件，保证包管理器在镜像里可直接使用：

- `debootstrap` 版通过 `tar -X exclude.txt` 去掉 `var/cache/apt/archives`、`var/lib/apt/lists`、
  `var/cache/debconf`、`/usr/share/{doc,man,info,groff,locale,i18n/locales}`、日志与
  `machine-id`；**不删** `/var/lib/dpkg`、`/etc/apt/sources.list*`、`extended_states`。
  `apt update` 会按 sources 重新拉取索引，安装/升级/卸载不受影响。
- `mmdebstrap` 版使用 dpkg 的 `path-exclude/path-include`（保留 man1-9 与 copyright/
  changelog），apt 的数据库与源配置完整保留。
- alpine 使用官方 minirootfs（`apk` 与 `/lib/apk/db`、`/etc/apk/repositories` 原样保留），
  不做事后手工修补；镜像层就是官方压缩 tarball 原字节。
- Debian 远古套件（buzz/rex/bo/hamm/slink）年代早于 apt 的诞生，只保留 dpkg 状态库，
  无法要求 apt 可用；这是历史产物本身的限制，不做人为删减。

## GitHub Actions

### `.github/workflows/rootfs-images.yml`（手动触发）

- 触发：`workflow_dispatch`；默认全量构建 `debian` 全部 18 个套件、`ubuntu` 全部 44 个套件，
  共 62 个 job、约 177 个套件×架构组合。每个套件的架构按官方 Release 现查（见“架构覆盖”）。
- 输入：`distributions`（both/debian/ubuntu）、`suites`（留空=全集，仅用于调试裁剪）、
  `arches`（留空=按官方每套件集合，非空时作为过滤）、`builder`（debootstrap/mmdebstrap）、`publish`。
- 流程：`prepare` 用 `LIST_SUITES=1` / `--list-suites` 读取套件清单、`LIST_MODERN=1` 区分
  现代/归档套件，再用 `scripts/suite-arches.py` 解析每个套件的架构并生成矩阵，同时解析官方
  `latest`/`lts` → 每个套件一个 job 并行构建（`ONLY`/`ARCHES` 复用现有脚本，build job 先
  `setup-qemu` 注册 binfmt）→ `publish-rootfs.sh push` 把该套件的全部架构合成一条多架构索引
  并推送 `<suite>` → 全部成功后 `merge` job 用 `skopeo copy --all` 把对应套件的索引复制成
  `latest`/`lts`。
- 耗时：现代套件的 job 要串行构建 4–9 个架构，非原生架构走 qemu 模拟（单个约 5–15 分钟），
  单 job 约 30–90 分钟；`max-parallel: 20`（GitHub Free 的账户并发上限，Pro 为 40）下总墙钟
  约 1.5–2 小时，下限是最长的现代套件 job（约 80 分钟）。
- 并行策略：保持单 workflow、每个套件一个 job；同一套件的架构仍然串行（全部架构就绪才能推
  索引）。没有改成套件×架构拆分——那需要各架构按 digest 推未打标签清单再合并，GHCR 侧更复杂
  且无法在本地验证；也没有拆多个 workflow 或引入自托管 runner——账户级并发上限不变，
  收益与提高 `max-parallel` 重叠。`fail-fast: false`，单个套件失败不影响其他套件，
  可以在 Actions 里只重跑失败的 job。
- 重试：GHCR 推送/别名复制在发布脚本里做 3 次指数退避重试；归档源失败按“重跑该套件 job”
  处理，不做整 job 自动重试（避免把 80 分钟的现代套件 job 翻倍，也避免掩盖确定性错误）。

### `.github/workflows/alpine-image.yml`（push + 手动触发）

- push 到 `master` 且改动 `Dockerfile.alpine` / `alpine.ico` 时只重建 `wsl:alpine`。
- 手动触发可同时重建 alpine 基础镜像（`build_base`，默认开）：版本与架构留空即自动取官方
  最新稳定版与全部可下载架构；也可显式固定版本/架构。

## 本地构建 / 发布（WSL 或 Linux）

发布需要 `skopeo` 与 `python3`（Debian/Ubuntu：`sudo apt-get install -y skopeo python3`）。
跨架构构建还需要 qemu 静态二进制并注册 binfmt（Ubuntu 26.04：
`sudo apt-get install -y qemu-user-binfmt && sudo systemctl restart systemd-binfmt`；
24.04 及更早可用 `qemu-user-static binfmt-support`）。

```bash
# wsl:alpine（沿用 compose.yaml）
docker compose build alpine

# 只构建 rootfs（产物在 ./debian、./ubuntu，日志在同级 logs/）
ONLY="trixie buster" ARCHES="amd64 i386" bash scripts/debian-debootstrap.sh
ONLY="noble jammy"   ARCHES="amd64 i386" bash scripts/ubuntu-debootstrap.sh

# 全架构：现代套件的官方架构集合可用 suite-arches.py 现查
ARCHES="$(python3 scripts/suite-arches.py --distro debian --suite trixie --modern)" \
    ONLY="trixie" bash scripts/debian-debootstrap.sh
ARCHES="$(python3 scripts/suite-arches.py --distro ubuntu --suite noble --modern)" \
    ONLY="noble" bash scripts/ubuntu-debootstrap.sh

# 先 docker login ghcr.io，再发布（合成多架构索引 → 推送 <suite> → 更新 latest/lts）
scripts/publish-rootfs.sh all --dir debian --latest debian:trixie --lts debian:bookworm
scripts/publish-rootfs.sh all --dir ubuntu --latest ubuntu:resolute --lts ubuntu:resolute
scripts/publish-alpine-image.sh          # 最新稳定版 + 官方全部架构

# 只预览命令
DRY_RUN=1 scripts/publish-rootfs.sh all --dir debian
```

`scripts/publish-rootfs.sh` 是发布流程的唯一实现，Actions 与本地共用；它调用
`scripts/oci-rootfs-layout.py` 合成多架构索引，再用 `skopeo copy --all` 推送，
可用 `IMAGE_OWNER` / `REGISTRY` / `IMAGE_SOURCE` / `SKOPEO` 覆盖默认值。
`skopeo` 会自动复用 `docker login` 写入的 `~/.docker/config.json` 凭据。

## GitHub 侧需要配置的权限

- 工作流已声明 `permissions: packages: write`，使用内置 `GITHUB_TOKEN` 即可推送，
  **不需要额外 secrets**。若组织策略禁用了写权限，需要在
  Settings → Actions → General → Workflow permissions 允许读写。
- 现有 `alpine`、`debian`、`ubuntu`、`wsl` 包均为 public，新标签会继承包可见性；
  如果新建了别的包名，默认是 private，需要在包设置里改为 public。
- 镜像带有 `org.opencontainers.image.source` 标签，新版本会自动关联到本仓库。

## 冻结的历史标签与逐架构标签

新流程不再生成任何逐架构标签。以下历史标签保留但不再更新，供既有引用继续拉取；
`latest`/`lts` 不再指向它们：

- `debian:forky`：此前 `debian:latest` 实际指向的 testing 内容。脚本只构建 stable/oldstable
  与归档套件，新流程不再重建 forky。
- `ubuntu:stonking`：此前 `ubuntu:latest` 指向的 26.10；官方 `meta-release` 未列入该版本，
  脚本也不构建它。
- `debian:lenny-i386`：旧流程留下的逐架构标签（该套件的 amd64 归档缺失）。
- `ubuntu:<suite>-amd64` / `ubuntu:<suite>-i386`（共 88 个）：旧流程“先推逐架构、再合并清单”
  留下的标签，新流程不再更新。
- `alpine:3.24.2`、`alpine:3.24.2-x86_64`、`alpine:3.24.2-x86`：历史补丁版本及其逐架构标签。
  其中 `3.24.2-x86` 的平台标记是旧的 `linux/x86`；新流程不生成逐架构标签，也不会再用这个平台名。

### 旧逐架构标签的处置建议（建议冻结，不删除）

- 建议：全部保留、不再更新，在本文件标注为冻结。新流程的 `<suite>` / `<version>` 标签与它们
  完全独立，继续使用旧标签的引用仍能拉到原镜像。
- 影响：这些标签的内容停留在旧构建，不会随官方更新，也可能缺少后续修正；新用户应改用
  `<suite>` / `<version>` 多架构清单，`docker pull` 会按平台自动选择架构。
  旧标签不会与新清单联动，二者内容可能逐渐分叉。
- 不自动清理的原因：GHCR 只能按“版本”删除，删掉后不可恢复；Ubuntu 的 88 个逐架构标签目前是
  独立清单（理论上可逐个删除），但一旦有引用就会直接断掉。若后续确认无人使用，
  可在包设置里手动删除，不建议放进 Actions 自动执行。

## 已知边界

- 构建脚本内置的套件清单按官方 release 列表维护；Debian `testing`（forky）不是发布版本，
  脚本默认不构建它，因此 `debian:latest` 指向当前 stable 而不是 testing。
- 同一套件的全部架构必须在同一次 `push` 中给出：`<suite>` 索引只包含本次传入的架构。
  Actions 矩阵是一个套件一个 job（该套件的全部架构在同一次 push 中提交），所以不会丢架构；
  手动只构建 `--arches amd64` 时，该套件的索引就只会有 amd64。
- 归档套件只做 amd64/i386 降级覆盖（用户确认古早套件不为凑架构额外折腾）；其中
  Debian buster 及更早、Ubuntu oracular 及更早仍依赖归档/旧镜像源，上游限流或 Release
  过期时可能失败，日志随 artifact 上传（保留 7 天）。
- 不单独发布的架构：`amd64v3`（x86-64-v3 包变体，与 amd64 共用平台）、`ia64`/`s390`
  （qemu-user 无模拟）、`kfreebsd-*`/`hurd-*`（非 Linux 用户态）。
- 非原生架构的构建速度取决于 qemu 模拟，且依赖 build job 里的 `setup-qemu`；
  本地构建需要自行安装 qemu-user-static 并注册 binfmt。
- `wsl:alpine` 关闭了 buildx provenance，不再产生 `unknown/unknown` attestation 条目。
- `debian-ancient.py` 只产出 i386（归档里没有这些套件的 amd64 索引），矩阵里也只排 i386。
