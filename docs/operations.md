# 维护者操作与权限

## GitHub 侧权限

- 工作流使用内置 `GITHUB_TOKEN`，**不需要额外 secrets**。
- 仓库设置 Settings → Actions → General → Workflow permissions 必须是
  **Read and write permissions**（`default_workflow_permissions: write`）。
- **已存在的包**需要在各包的 Package settings → Manage Actions access 里把
  `yingquelou/docker-images` 加为 **Write**；否则 `GITHUB_TOKEN` 会报
  `denied: permission_denied: write_package`。新建包由 Actions 首次推送时会自动获得写权限。
  需要授权的包：`debian`、`ubuntu`、`alpine`、`wsl`。
- 包的可见性：现有四个包均为 public；新标签继承包可见性。新建包默认 private，需要手动改 public。
- 镜像带 `org.opencontainers.image.source` 标签，新版本会自动关联到本仓库。

## 手动运行

```bash
# 冒烟：一个 Debian + 一个 Ubuntu 套件
gh workflow run rootfs-images.yml -f distributions=both -f suites="trixie noble"

# 全量（留空 suites/arches）
gh workflow run rootfs-images.yml -f distributions=both

# 只重跑两个套件
gh workflow run rootfs-images.yml -f distributions=ubuntu -f suites="warty hoary"

# Alpine 基础镜像 + wsl:alpine
gh workflow run alpine-image.yml
```

失败后优先用 Actions 的「Re-run failed jobs」，只重跑失败套件；归档源限流通常重跑即可恢复。

## 发布后核对

```bash
# 每个套件应只有一个多架构标签，没有 <suite>-<arch>
gh api --paginate "/users/yingquelou/packages/container/debian/versions?per_page=100" \
  --jq '.[].metadata.container.tags[]' | sort

# 索引平台
docker buildx imagetools inspect ghcr.io/yingquelou/debian:bookworm
```

镜像内包管理自检：

```bash
docker run --rm --platform linux/amd64 ghcr.io/yingquelou/debian:bookworm \
  sh -c 'apt-get update && apt-get install -y --no-install-recommends hello && hello'
docker run --rm ghcr.io/yingquelou/alpine:3.24.4 sh -c 'apk update && apk add hello'
```

## 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `E: Package 'qemu-user-static' has no installation candidate` | Ubuntu 26.04 把它变成虚拟包 | 用 `qemu-user-binfmt` / `qemu-user`，不要直接装 `qemu-user-static` |
| `unknown flag: --authfile` | `--authfile` 是 skopeo 全局参数 | 写成 `skopeo --authfile … copy …` |
| `denied: permission_denied: write_package` | 包级 Actions access 没有 Write，或仓库默认权限是只读 | 见上面「GitHub 侧权限」，两层都要配 |
| warty/hoary i386 `Inconsistency detected by ld.so … _dl_sysinfo_dso` | 2004–2005 年的 glibc 与新内核不兼容 | 已用 Debian `qemu-i386-static` 注册 binfmt，慢但可用 |
| 归档套件失败 | `archive.debian.org` / 旧 Ubuntu 归档限流或 Release 过期 | 重跑对应套件 job |
| `latest`/`lts` 没动 | 目标官方版本本次没有构建 | 日志会给出 WARN；构建对应套件后会前进 |

## 冻结标签

以下标签保留但不再更新，供既有引用继续拉取；`latest` / `lts` 不再指向它们：

- `debian:forky`：此前 `debian:latest` 指向的 testing 内容；脚本只构建 stable/oldstable 与归档套件。
- `ubuntu:stonking`：此前 `ubuntu:latest` 指向的 26.10；官方 `meta-release` 未列入该版本。
- `alpine:3.24.2`、`alpine:3.24.2-x86_64`、`alpine:3.24.2-x86`：历史补丁版本；`3.24.2-x86`
  的平台标记是旧的 `linux/x86`，保持原样。
- `ubuntu:<suite>-amd64` / `-i386`（88 个）与 `debian:lenny-i386`：旧的逐架构标签，已停止更新，
  内容会停留在旧构建，不要用于新部署。

不删除这些标签：GHCR 只能按版本删除且不可恢复，误删会直接断掉现有引用。
