#!/bin/bash
# 把 rootfs 打包产物发布为 GHCR（GitHub Packages 容器类型）镜像。
#
# 每个套件只发布一个多架构标签，架构只作为索引里的 platform 条目存在：
#   <registry>/<owner>/<distro>:<suite>   多架构镜像索引（本次构建到的全部架构）
#   <registry>/<owner>/<distro>:latest    merge/all 里 --latest distro:suite 时指向该套件索引
#   <registry>/<owner>/<distro>:lts       merge/all 里 --lts distro:suite 时指向该套件索引
# 不再生成 <suite>-<arch> 逐架构标签。
#
# 实现方式：同一套件的 tarball 先合成一个 OCI layout（scripts/oci-rootfs-layout.py，
# 层就是原始 rootfs tarball），再用 skopeo copy --all 推送。注册表里只会出现一个指向
# 多架构索引的标签，不会留下 GHCR 无法单独删除的逐架构标签；镜像 CMD 与原先
# docker import 的结果一致：debian/ubuntu 用 bash，alpine 用 sh。
#
# 用法（在 WSL/Linux 下，需要已 docker login ghcr.io，并安装 skopeo + python3）：
#   scripts/publish-rootfs.sh push --dir debian
#   scripts/publish-rootfs.sh push debian/debian-trixie-amd64-rootfs.tar.gz \
#                                debian/debian-trixie-i386-rootfs.tar.gz
#   scripts/publish-rootfs.sh merge --latest debian:trixie --lts debian:bookworm
#   scripts/publish-rootfs.sh all --dir ubuntu --latest ubuntu:resolute --lts ubuntu:resolute
#
# 环境变量：REGISTRY（默认 ghcr.io）、IMAGE_OWNER（默认 yingquelou）、
#           IMAGE_SOURCE（source 标签，默认本仓库地址）、OCI_LAYOUT_HELPER（OCI 布局
#           辅助脚本路径）、SKOPEO（默认 skopeo）、DRY_RUN=1 只打印命令。

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REGISTRY="${REGISTRY:-ghcr.io}"
OWNER="${IMAGE_OWNER:-yingquelou}"
SOURCE_URL="${IMAGE_SOURCE:-https://github.com/yingquelou/docker-images}"
OCI_HELPER="${OCI_LAYOUT_HELPER:-$SCRIPT_DIR/oci-rootfs-layout.py}"
SKOPEO="${SKOPEO:-skopeo}"
DRY_RUN="${DRY_RUN:-0}"

# docker login 写的是 docker 的 config.json；skopeo 认这个路径就直接复用，避免再登录一次
if [ -z "${REGISTRY_AUTH_FILE:-}" ] && [ -f "${DOCKER_CONFIG:-$HOME/.docker}/config.json" ]; then
    REGISTRY_AUTH_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    export REGISTRY_AUTH_FILE
fi

log()  { printf '[publish] %s\n' "$*"; }
warn() { printf '[publish] WARN: %s\n' "$*" >&2; }
die()  { printf '[publish] ERROR: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        "$@"
    fi
}

# 注册表偶发 5xx/超时时退避重试；指数退避，失败次数有上限，避免无限等待
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

require_tools() {
    [ -f "$OCI_HELPER" ] || die "找不到 $OCI_HELPER"
    if [ "$DRY_RUN" = "1" ]; then
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || die "找不到 python3"
    command -v "$SKOPEO" >/dev/null 2>&1 || die "找不到 skopeo（推送多架构索引需要）"
}

usage() {
    cat <<'EOF'
用法：
  publish-rootfs.sh push  [--dir DIR] [--distro D] [--suite S] [--arch A] TARBALL...
  publish-rootfs.sh merge [--latest D:SUITE]... [--lts D:SUITE]...
  publish-rootfs.sh all   --dir DIR [--latest D:SUITE]... [--lts D:SUITE]...

push   把同一套件的 tarball 合成多架构索引并推送到 <distro>:<suite>（不推逐架构标签）
merge  把 <distro>:<suite> 的索引复制为 <distro>:latest / <distro>:lts
all    push --dir 后再 merge（本地一键发布）
EOF
}

# 由文件名推断 distro/suite/arch：<distro>-<suite>-<arch>-rootfs.tar[.gz]
# debian-ancient.py 的 deb-<suite>-<arch>-rootfs.tar.gz 归到 debian。
parse_tarball_name() {
    local base=${1##*/}
    case "$base" in
        *.tar.gz) base=${base%.tar.gz} ;;
        *.tar)    base=${base%.tar} ;;
        *) return 1 ;;
    esac
    [[ $base =~ ^(debian|deb|ubuntu)-([a-z0-9][a-z0-9.]*)-([a-z0-9_]+)-rootfs$ ]] || return 1
    local distro=${BASH_REMATCH[1]}
    if [ "$distro" = "deb" ]; then
        distro=debian
    fi
    printf '%s %s %s\n' "$distro" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# 同一套件的架构集合用换行分隔的 "arch=path" 保存，检查是否已有某架构
group_has_arch() {
    local list=$1 arch=$2 item
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        if [ "${item%%=*}" = "$arch" ]; then
            return 0
        fi
    done <<<"$list"
    return 1
}

push_group() {
    local distro=$1 suite=$2 layout=$3
    shift 3
    local -a arch_args=()
    local spec
    for spec in "$@"; do
        arch_args+=("--arch" "$spec")
    done

    if [ "$DRY_RUN" = "1" ]; then
        printf '+ python3 %s --out %s --ref %s --distro %s --source %s %s\n' \
            "$OCI_HELPER" "$layout" "$suite" "$distro" "$SOURCE_URL" "$*"
        printf '+ %s copy --all oci:%s:%s docker://%s/%s/%s:%s\n' \
            "$SKOPEO" "$layout" "$suite" "$REGISTRY" "$OWNER" "$distro" "$suite"
        return 0
    fi

    rm -rf "$layout"
    mkdir -p "$layout"
    python3 "$OCI_HELPER" \
        --out "$layout" \
        --ref "$suite" \
        --distro "$distro" \
        --source "$SOURCE_URL" \
        "${arch_args[@]}"

    log "推送 $distro:$suite ← $(( ${#arch_args[@]} / 2 )) 个架构（单条多架构清单）"
    run_skopeo copy --all "oci:$layout:$suite" "docker://$REGISTRY/$OWNER/$distro:$suite"
}

cmd_push() {
    local dir="" o_distro="" o_suite="" o_arch=""
    local files=()

    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)    dir=${2:?}; shift 2 ;;
            --distro) o_distro=${2:?}; shift 2 ;;
            --suite)  o_suite=${2:?}; shift 2 ;;
            --arch)   o_arch=${2:?}; shift 2 ;;
            --)       shift; files+=("$@"); break ;;
            -*)       die "未知参数：$1" ;;
            *)        files+=("$1"); shift ;;
        esac
    done

    if [ -n "$dir" ]; then
        [ -d "$dir" ] || die "目录不存在：$dir"
        while IFS= read -r -d '' f; do files+=("$f"); done < <(
            find "$dir" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tar' \) -print0 | sort -z
        )
    fi
    [ "${#files[@]}" -gt 0 ] || die "没有可发布的文件（--dir ${dir:-<未指定>}）"

    require_tools

    local -A groups=()
    local -a keys=()
    local f parsed distro suite arch key entry
    for f in "${files[@]}"; do
        if ! parsed=$(parse_tarball_name "$f"); then
            warn "跳过无法识别的文件名：$f"
            continue
        fi
        read -r distro suite arch <<<"$parsed"
        if [ -n "$o_distro" ]; then distro=$o_distro; fi
        if [ -n "$o_suite" ]; then suite=$o_suite; fi
        if [ -n "$o_arch" ]; then arch=$o_arch; fi

        key="$distro|$suite"
        entry="$arch=$f"
        if [ -z "${groups[$key]:-}" ]; then
            keys+=("$key")
            groups[$key]=$entry
        elif group_has_arch "${groups[$key]}" "$arch"; then
            warn "同一套件的 $arch 架构出现多次，忽略：$f"
        else
            groups[$key]+=$'\n'$entry
        fi
    done

    if [ "${#keys[@]}" -eq 0 ]; then
        # 归档里没有该架构时构建脚本会明确跳过（不计失败），所以这里不算错误
        warn "没有产物被发布（该套件/架构可能已被构建脚本跳过）"
        return 0
    fi

    local workdir
    workdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" EXIT

    local -a specs
    for key in "${keys[@]}"; do
        distro=${key%%|*}
        suite=${key#*|}
        specs=()
        while IFS= read -r entry; do
            if [ -n "$entry" ]; then
                specs+=("$entry")
            fi
        done <<<"${groups[$key]}"
        push_group "$distro" "$suite" "$workdir/$distro-$suite" "${specs[@]}"
    done
}

# 把已发布的 <distro>:<suite> 索引复制成 <distro>:<alias>，digest 保持不变
promote() {
    local distro=$1 suite=$2 alias=$3
    local src="docker://$REGISTRY/$OWNER/$distro:$suite"
    local dst="docker://$REGISTRY/$OWNER/$distro:$alias"

    if [ "$DRY_RUN" != "1" ] && ! skopeo_cmd inspect --raw "$src" >/dev/null 2>&1; then
        warn "目标 $distro:$suite 不存在（本次未构建或未推送），不更新 $distro:$alias"
        return 0
    fi
    log "更新 $distro:$alias ← $distro:$suite"
    run_skopeo copy --all "$src" "$dst"
}

cmd_merge() {
    local latest_targets=" "
    local lts_targets=" "

    while [ $# -gt 0 ]; do
        case "$1" in
            --latest) latest_targets+="${2:?} "; shift 2 ;;
            --lts)    lts_targets+="${2:?} "; shift 2 ;;
            -*)       die "未知参数：$1" ;;
            *)        die "merge 不接受位置参数：$1" ;;
        esac
    done

    require_tools

    # 官方解析出的目标套件可能本次没有构建（例如尚未加入构建脚本的版本）：明确提示而不是静默
    local t distro suite
    for t in $latest_targets; do
        distro=${t%%:*}
        suite=${t#*:}
        promote "$distro" "$suite" latest
    done
    for t in $lts_targets; do
        distro=${t%%:*}
        suite=${t#*:}
        promote "$distro" "$suite" lts
    done
}

cmd_all() {
    local dir=""
    local merge_args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --dir)    dir=${2:?}; shift 2 ;;
            --latest) merge_args+=(--latest "${2:?}"); shift 2 ;;
            --lts)    merge_args+=(--lts "${2:?}"); shift 2 ;;
            -*)       die "未知参数：$1" ;;
            *)        die "all 不接受位置参数：$1" ;;
        esac
    done
    [ -n "$dir" ] || die "all 需要 --dir"

    cmd_push --dir "$dir"
    cmd_merge "${merge_args[@]}"
}

case "${1:-}" in
    push)  shift; cmd_push "$@" ;;
    merge) shift; cmd_merge "$@" ;;
    all)   shift; cmd_all "$@" ;;
    -h|--help|"") usage ;;
    *)     usage >&2; die "未知子命令：$1" ;;
esac
