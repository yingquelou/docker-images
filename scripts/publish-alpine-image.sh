#!/bin/bash
# 构建 Alpine 基础镜像并推送到 GHCR（GitHub Packages 容器类型）。
#
# 直接下载官方 alpine-minirootfs，把同一版本的全部官方架构合成为一个多架构镜像索引发布。
# 版本与架构都从官方发布源动态解析：
#   * 版本：默认取 https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/ 下最新的
#     alpine-minirootfs-<X.Y.Z>（可用 --version 固定，固定旧版本时不会移动 latest）。
#   * 架构：枚举 https://dl-cdn.alpinelinux.org/alpine/v<X.Y>/releases/ 下的架构目录，
#     并用 HEAD 逐项确认该版本确实存在 minirootfs 才纳入（cloud 等非架构目录自动排除）。
#
# 标签（每个版本只发布一个多架构清单，不生成 <version>-<arch> 逐架构标签）：
#   <registry>/<owner>/alpine:<version>       含官方全部架构的多架构索引
#   <registry>/<owner>/alpine:<major.minor>   该系列最新补丁的稳定别名（如 3.24）
#   <registry>/<owner>/alpine:latest          仅当本次构建的就是官方最新稳定版时更新
# Alpine 没有 Ubuntu / Debian 式的 LTS 发布序列，因此不发布 :lts。
#
# 实现方式：tarball 合成 OCI layout（scripts/oci-rootfs-layout.py，层就是原始
# minirootfs tarball），再用 skopeo copy --all 推送，注册表里只出现一个指向多架构
# 索引的标签；CMD 与原先 docker import 的结果一致（sh）。
#
# 用法（在 WSL/Linux 下，需要已 docker login ghcr.io，并安装 skopeo + python3）：
#   scripts/publish-alpine-image.sh                       # 最新稳定版、全部官方架构
#   scripts/publish-alpine-image.sh --version 3.24.4      # 固定版本（架构仍需官方存在）
#   scripts/publish-alpine-image.sh --arches "x86_64 x86"
#
# 环境变量：ALPINE_VERSION（默认空=自动取最新）、ALPINE_ARCHES（默认空=自动枚举）、
#           ALPINE_CACHE_DIR（下载缓存目录）、REGISTRY、IMAGE_OWNER、DRY_RUN=1。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${IMAGE_OWNER:-yingquelou}"
SOURCE_URL="${IMAGE_SOURCE:-https://github.com/yingquelou/docker-images}"
VERSION="${ALPINE_VERSION:-}"
ARCHES="${ALPINE_ARCHES:-}"
UPDATE_LATEST="${ALPINE_LATEST:-1}"
CACHE_DIR="${ALPINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/alpine-rootfs}"
OCI_HELPER="${OCI_LAYOUT_HELPER:-$SCRIPT_DIR/oci-rootfs-layout.py}"
SKOPEO="${SKOPEO:-skopeo}"
DRY_RUN="${DRY_RUN:-0}"

CDN="https://dl-cdn.alpinelinux.org/alpine"

# docker login 写的是 docker 的 config.json；skopeo 认这个路径就直接复用
if [ -z "${REGISTRY_AUTH_FILE:-}" ] && [ -f "${DOCKER_CONFIG:-$HOME/.docker}/config.json" ]; then
    REGISTRY_AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    export REGISTRY_AUTH_FILE
fi

log()  { printf '[alpine] %s\n' "$*"; }
warn() { printf '[alpine] WARN: %s\n' "$*" >&2; }
die()  { printf '[alpine] ERROR: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

# 注册表偶发 5xx/超时时退避重试；指数退避，失败次数有上限
retry() {
    local attempts=$1 delay=$2
    shift 2
    local n=1
    while true; do
        if "$@"; then
            return 0
        fi
        if [ "$n" -ge "$attempts" ]; then
            return 1
        fi
        warn "第 $n 次失败，${delay}s 后重试：$*"
        sleep "$delay"
        n=$((n + 1))
        delay=$((delay * 2))
    done
}

# skopeo 新版已移除全局 --authfile，改为只靠 REGISTRY_AUTH_FILE 环境变量传递凭据
skopeo_cmd() {
    "$SKOPEO" "$@"
}

run_skopeo() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s %s\n' "$SKOPEO" "$*"
    else
        retry 3 2 skopeo_cmd "$@"
    fi
}

usage() {
    cat <<'EOF'
用法：publish-alpine-image.sh [--version X.Y.Z] [--arches "arch ..."] [--latest|--no-latest]
版本与架构留空时从官方发布源自动解析。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=${2:?}; shift 2 ;;
        --arches)  ARCHES=${2:?}; shift 2 ;;
        --latest)  UPDATE_LATEST=1; shift ;;
        --no-latest) UPDATE_LATEST=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
done

command -v curl >/dev/null 2>&1 || die "找不到 curl"
[ -f "$OCI_HELPER" ] || die "找不到 $OCI_HELPER"
if [ "$DRY_RUN" != "1" ]; then
    command -v python3 >/dev/null 2>&1 || die "找不到 python3"
    command -v "$SKOPEO" >/dev/null 2>&1 || die "找不到 skopeo（推送多架构索引需要）"
fi

# 官方最新稳定版：latest-stable 下 x86_64 的 minirootfs 版本号最大值
resolve_latest_version() {
    curl -fsSL "$CDN/latest-stable/releases/x86_64/" \
        | grep -oE 'alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-x86_64\.tar\.gz' \
        | sed -E 's/^alpine-minirootfs-([0-9.]+)-x86_64\.tar\.gz$/\1/' \
        | sort -V | tail -n 1
}

# 官方架构清单：releases/ 下的目录名（排除 .. 与 cloud），再逐个 HEAD 校验该版本的文件
resolve_arches() {
    local series=$1 version=$2
    local a
    curl -fsSL "$CDN/v${series}/releases/" \
        | grep -oE 'href="[^"/]+/"' \
        | sed -E 's/href="(.*)\/"/\1/' \
        | grep -vE '^(\.\.|cloud)$' \
        | sort -u \
        | while IFS= read -r a; do
            if curl -fsI "$CDN/v${series}/releases/$a/alpine-minirootfs-${version}-${a}.tar.gz" >/dev/null 2>&1; then
                printf '%s\n' "$a"
            fi
        done
}

# 某条稳定线上的最新补丁版本（例如 v3.24 的 3.24.4），用于维护 <major.minor> 别名
resolve_series_version() {
    local series=$1
    curl -fsSL "$CDN/v${series}/releases/x86_64/" \
        | grep -oE 'alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-x86_64\.tar\.gz' \
        | sed -E 's/^alpine-minirootfs-([0-9.]+)-x86_64\.tar\.gz$/\1/' \
        | sort -V | tail -n 1
}

latest_version=$(resolve_latest_version || true)
if [ -z "$VERSION" ]; then
    [ -n "$latest_version" ] || die "无法从 $CDN/latest-stable 解析最新稳定版"
    VERSION=$latest_version
elif [ -z "$latest_version" ]; then
    warn "无法解析官方最新稳定版，本次不会移动 alpine:latest"
fi
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号必须是 X.Y.Z：$VERSION"

series=${VERSION%.*}
if [ -z "$ARCHES" ]; then
    ARCHES=$(resolve_arches "$series" "$VERSION" || true)
    [ -n "$ARCHES" ] || die "v$series 下没有找到 $VERSION 的任何官方架构"
fi

log "版本 $VERSION（官方最新稳定版：$latest_version）"
log "架构：$(printf '%s' "$ARCHES" | tr '\n' ' ')"

mkdir -p "$CACHE_DIR"

workdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$workdir'" EXIT

arch_args=()
arch_count=0
for arch in $ARCHES; do
    url="$CDN/v${series}/releases/${arch}/alpine-minirootfs-${VERSION}-${arch}.tar.gz"
    tarball="$CACHE_DIR/alpine-minirootfs-${VERSION}-${arch}.tar.gz"

    if [ -s "$tarball" ]; then
        log "使用缓存 $tarball"
    else
        log "下载 $url"
        run curl -fL --retry 3 --retry-delay 2 -o "$tarball.part" "$url"
        if [ "$DRY_RUN" != "1" ]; then
            mv -f "$tarball.part" "$tarball"
        fi
    fi
    arch_args+=(--arch "${arch}=${tarball}")
    arch_count=$((arch_count + 1))
done

layout="$workdir/alpine-$VERSION"
log "合成 alpine:$VERSION ← ${arch_count} 个架构（单条多架构清单）"
if [ "$DRY_RUN" = "1" ]; then
    printf '+ python3 %s --out %s --ref %s --distro alpine --source %s %s\n' \
        "$OCI_HELPER" "$layout" "$VERSION" "$SOURCE_URL" "${arch_args[*]}"
    printf '+ %s copy --all oci:%s:%s docker://%s/%s/alpine:%s\n' \
        "$SKOPEO" "$layout" "$VERSION" "$REGISTRY" "$OWNER" "$VERSION"
else
    mkdir -p "$layout"
    python3 "$OCI_HELPER" \
        --out "$layout" \
        --ref "$VERSION" \
        --distro alpine \
        --source "$SOURCE_URL" \
        "${arch_args[@]}"
    skopeo_cmd copy --all "oci:$layout:$VERSION" "docker://$REGISTRY/$OWNER/alpine:$VERSION"
fi

# <major.minor> 稳定别名：只在该系列最新补丁时前进，避免旧补丁构建把别名回退
series_version=$(resolve_series_version "$series" || true)
if [ -z "$series_version" ]; then
    warn "无法解析 v$series 的最新补丁版本，不更新 alpine:$series"
elif [ "$VERSION" = "$series_version" ]; then
    log "更新 alpine:$series（v$series 最新补丁 $series_version）"
    run_skopeo copy --all \
        "docker://$REGISTRY/$OWNER/alpine:$VERSION" \
        "docker://$REGISTRY/$OWNER/alpine:$series"
else
    warn "本次构建的 $VERSION 不是 v$series 的最新补丁（$series_version），不移动 alpine:$series"
fi

if [ "$UPDATE_LATEST" = "1" ]; then
    if [ -z "$latest_version" ]; then
        warn "无法解析官方最新稳定版，不移动 alpine:latest"
    elif [ "$VERSION" = "$latest_version" ]; then
        log "更新 alpine:latest"
        run_skopeo copy --all \
            "docker://$REGISTRY/$OWNER/alpine:$VERSION" \
            "docker://$REGISTRY/$OWNER/alpine:latest"
    else
        warn "本次构建的 $VERSION 不是官方最新稳定版（$latest_version），不移动 alpine:latest"
    fi
fi
