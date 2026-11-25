
#!/usr/bin/env bash
#
# Linux VPS 系统清理工具
# Version: 1.0.0
#
# Supported OS:
# Debian 11 / 12 / 13
# Ubuntu 20.04 / 22.04 / 24.04 / 26.04
#
# Supported architectures:
# amd64 / arm64 / armhf / ppc64el / s390x
#
# Docker:
# Independent cleanup, analysis and volume inspection
#

set -Eeuo pipefail

VERSION="1.0.0"
SCRIPT_NAME="Linux VPS 系统清理工具"

# ==================================================
# 颜色
# ==================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BLUE='\033[34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; }
info() { echo -e "${CYAN}[*]${NC} $*"; }

pause() {
    echo
    read -r -p "按回车键返回..." _
}

confirm() {
    local answer
    read -r -p "${1:-确认执行？}[Y/n]: " answer
    case "${answer,,}" in
        n|no) return 1 ;;
        *) return 0 ;;
    esac
}

format_size() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"
    else
        echo "${1}B"
    fi
}

# ==================================================
# 基础环境检查
# ==================================================

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "请使用 root 权限运行脚本。"
        exit 1
    fi
}

check_system() {
    if [[ ! -r /etc/os-release ]]; then
        err "无法读取系统信息。"
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian)
            case "${VERSION_ID:-}" in
                11|12|13) ;;
                *)
                    err "不支持的 Debian 版本：${VERSION_ID:-unknown}"
                    exit 1
                    ;;
            esac
            ;;
        ubuntu)
            case "${VERSION_ID:-}" in
                20.04|22.04|24.04|26.04) ;;
                *)
                    err "不支持的 Ubuntu 版本：${VERSION_ID:-unknown}"
                    exit 1
                    ;;
            esac
            ;;
        *)
            err "不支持的系统：${ID:-unknown}"
            exit 1
            ;;
    esac

    OS_NAME="${PRETTY_NAME:-$ID}"
}

check_arch() {
    local arch

    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    case "$arch" in
        amd64|arm64|armhf|ppc64el|s390x)
            ARCH="$arch"
            ;;
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armhf"
            ;;
        ppc64le)
            ARCH="ppc64el"
            ;;
        *)
            err "不支持的 CPU 架构：$arch"
            exit 1
            ;;
    esac
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        err "没有检测到 Docker。"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        err "Docker 命令存在，但 Docker 服务不可用。"
        warn "请检查 Docker 服务是否正常运行。"
        return 1
    fi

    return 0
}

# ==================================================
# 系统磁盘信息
# ==================================================

disk_usage() {
    df -h / | awk '
    NR==2 {
        printf "根分区：已用 %s / 总计 %s，使用率 %s\n", $3, $2, $5
    }'
}

get_disk_used() {
    df -B1 / | awk 'NR==2 {print $3}'
}

get_journal_size() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --disk-usage 2>/dev/null || true
    else
        echo "journalctl 不可用"
    fi
}

show_disk_summary() {
    echo
    echo "========== 磁盘空间 =========="
    df -hT
    echo
}

# ==================================================
# 系统垃圾清理
# ==================================================

clean_apt() {
    echo
    info "清理 APT 软件包缓存..."

    export DEBIAN_FRONTEND=noninteractive

    if apt-get clean; then
        log "APT 下载缓存清理完成。"
    else
        warn "APT clean 执行失败。"
    fi

    if apt-get autoclean; then
        log "APT 过期软件包缓存清理完成。"
    else
        warn "APT autoclean 执行失败。"
    fi

    echo
    info "清理不再需要的软件依赖..."

    if apt-get -y autoremove; then
        log "无用依赖清理完成。"
    else
        warn "部分无用依赖清理失败。"
    fi
}

clean_journal() {
    local days="$1"
    local size="$2"

    echo
    info "清理 systemd 历史日志..."
    echo "保留最近 ${days} 天，日志总量限制 ${size}"

    if command -v journalctl >/dev/null 2>&1; then
        if journalctl --vacuum-time="${days}d" \
                      --vacuum-size="${size}"; then
            log "系统历史日志清理完成。"
        else
            warn "日志清理部分失败。"
        fi
    else
        warn "未检测到 journalctl，跳过。"
    fi
}

clean_temp() {
    echo
    info "清理系统过期临时文件..."

    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        if systemd-tmpfiles --clean; then
            log "系统临时文件清理完成。"
        else
            warn "部分临时文件清理失败。"
        fi
    else
        warn "systemd-tmpfiles 不存在，跳过。"
    fi
}

clean_crash() {
    echo
    info "清理系统崩溃转储文件..."

    if [[ -d /var/crash ]]; then
        if find /var/crash -mindepth 1 -maxdepth 1 \
            -exec rm -rf -- {} +; then
            log "崩溃转储文件清理完成。"
        else
            warn "部分崩溃转储文件清理失败。"
        fi
    else
        log "没有发现崩溃转储目录。"
    fi
}

system_cleanup() {
    local mode="$1"
    local days size before after

    if [[ "$mode" == "safe" ]]; then
        days=7
        size="200M"

        echo
        echo "========== 安全清理系统垃圾 =========="
        echo
        echo "清理内容："
        echo "  - APT 软件包缓存"
        echo "  - 不再需要的软件依赖"
        echo "  - 7 天以前的系统历史日志"
        echo "  - 过期系统临时文件"
        echo "  - 系统崩溃转储文件"
        echo
        echo "保留："
        echo "  - 当前运行内核"
        echo "  - Docker 容器、镜像及数据卷"
        echo "  - 用户文件及业务配置"
        echo "  - Xboard、AriNode 等项目文件"
    else
        days=3
        size="100M"

        echo
        echo "========== 深度清理系统垃圾 =========="
        echo
        echo "清理内容："
        echo "  - APT 软件包缓存及过期缓存"
        echo "  - 不再需要的软件依赖"
        echo "  - 3 天以前的系统历史日志"
        echo "  - 过期系统临时文件"
        echo "  - 系统崩溃转储文件"
        echo
        echo "日志限制：100M"
        echo
        echo "不会清理 Docker 数据及业务程序。"
    fi

    echo

    if ! confirm "确认开始清理？"; then
        warn "已取消。"
        return
    fi

    before="$(get_disk_used)"

    echo
    log "开始执行系统清理..."

    clean_apt
    clean_journal "$days" "$size"
    clean_temp
    clean_crash

    after="$(get_disk_used)"

    echo
    echo "========== 清理结果 =========="

    if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then
        if (( before > after )); then
            log "本次释放空间：$(format_size "$((before-after))")"
        else
            warn "磁盘占用没有明显减少。"
        fi
    fi

    disk_usage
    log "系统清理任务完成。"
}

# ==================================================
# Docker 基础显示
# ==================================================

docker_header() {
    echo
    echo "========== Docker 垃圾清理 =========="
    docker version --format 'Docker 版本：{{.Server.Version}}' 2>/dev/null || true
    echo
}

docker_container_list() {
    echo
    info "已停止的容器："
    docker ps -a --filter status=exited \
        --format 'table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' \
        2>/dev/null || true
}

docker_dangling_images() {
    echo
    info "悬空镜像："
    docker image ls --filter dangling=true \
        --format 'table {{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}' \
        2>/dev/null || true
}

docker_all_images() {
    echo
    info "当前全部镜像："
    docker image ls \
        --format 'table {{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}' \
        2>/dev/null || true
}

docker_network_list() {
    echo
    info "未使用网络（Docker 报告的 dangling 网络）："
    docker network ls --filter dangling=true \
        --format 'table {{.ID}}\t{{.Name}}\t{{.Driver}}' \
        2>/dev/null || true
}

# ==================================================
# Docker 单项清理
# ==================================================

docker_clean_stopped() {
    docker_container_list

    echo
    warn "删除已停止的容器会同时删除容器自身未挂载的数据。"

    if ! confirm "确认删除以上已停止容器？"; then
        warn "已取消。"
        return
    fi

    docker container prune -f || warn "容器清理失败。"
    log "已停止容器清理任务完成。"
}

docker_clean_dangling_images() {
    docker_dangling_images

    if ! confirm "确认清理悬空镜像？"; then
        warn "已取消。"
        return
    fi

    docker image prune -f || warn "悬空镜像清理失败。"
    log "悬空镜像清理任务完成。"
}

docker_clean_unused_images() {
    docker_all_images

    echo
    warn "将删除所有没有任何容器引用的镜像，包括带标签的镜像。"
    warn "以后创建容器时，可能需要重新下载这些镜像。"

    if ! confirm "确认清理未使用镜像？"; then
        warn "已取消。"
        return
    fi

    docker image prune -a -f || warn "未使用镜像清理失败。"
    log "未使用镜像清理任务完成。"
}

docker_clean_build_cache() {
    echo
    info "当前 Docker 构建缓存："
    docker builder du 2>/dev/null || true

    if ! confirm "确认清理全部未使用构建缓存？"; then
        warn "已取消。"
        return
    fi

    docker builder prune -a -f || warn "构建缓存清理失败。"
    log "构建缓存清理任务完成。"
}

docker_clean_network() {
    docker_network_list

    echo
    warn "仅删除没有容器连接的网络。"

    if ! confirm "确认清理未使用网络？"; then
        warn "已取消。"
        return
    fi

    docker network prune -f || warn "网络清理失败。"
    log "未使用网络清理任务完成。"
}

# ==================================================
# Docker 未使用数据卷检查
# ==================================================

docker_check_volumes() {
    local volumes volume mountpoint size found=0

    echo
    echo "========== 未使用 Docker 数据卷检查 =========="

    volumes="$(docker volume ls -qf dangling=true 2>/dev/null || true)"

    if [[ -z "$volumes" ]]; then
        log "没有发现未使用的数据卷。"
        return
    fi

    echo
    warn "以下数据卷当前没有容器引用："
    echo

    while IFS= read -r volume; do
        [[ -z "$volume" ]] && continue

        mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$volume" 2>/dev/null || true)"
        size="未知"

        if [[ -n "$mountpoint" && -d "$mountpoint" ]]; then
            size="$(du -sh "$mountpoint" 2>/dev/null | awk '{print $1}' || echo "未知")"
        fi

        printf "卷名称：%s\n" "$volume"
        printf "占用空间：%s\n" "$size"
        printf "存储路径：%s\n" "${mountpoint:-未知}"
        echo "----------------------------------------------"

        found=1
    done <<< "$volumes"

    if (( found == 1 )); then
        echo
        warn "以上数据卷只进行了检查，没有删除任何数据。"
        warn "未被引用不代表没有价值，可能保存着数据库或历史业务数据。"
    fi
}

# ==================================================
# Docker 综合清理预览
# ==================================================

docker_comprehensive_preview() {
    local running_ids image_id image_tag
    local -A used_ids=()

    echo
    echo "========== Docker 综合清理预览 =========="

    echo
    info "1. 待删除的已停止容器："
    docker ps -a --filter status=exited \
        --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true

    echo
    info "2. 待清理的悬空镜像："
    docker image ls -f dangling=true \
        --format 'table {{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}' || true

    echo
    info "3. 待清理的未使用镜像："

    # 综合清理会先删除停止容器。
    # 因此这里只保留运行中容器正在使用的镜像。
    running_ids="$(docker ps -q 2>/dev/null || true)"

    if [[ -n "$running_ids" ]]; then
        while IFS= read -r image_id; do
            [[ -n "$image_id" ]] && used_ids["$image_id"]=1
        done < <(
            docker inspect --format '{{.Image}}' $running_ids 2>/dev/null || true
        )
    fi

    local unused_found=0

    while IFS=$'\t' read -r image_id image_tag; do
        [[ -z "$image_id" ]] && continue

        if [[ -z "${used_ids[$image_id]+x}" ]]; then
            printf "镜像：%-45s 标签：%s\n" "$image_id" "$image_tag"
            unused_found=1
        fi
    done < <(
        docker image ls --no-trunc \
            --format '{{.ID}}{{"\t"}}{{.Repository}}:{{.Tag}}' 2>/dev/null
    )

    if (( unused_found == 0 )); then
        echo "没有发现未使用镜像。"
    fi

    echo
    info "4. 构建缓存："
    docker builder du 2>/dev/null || true

    echo
    info "5. 未使用网络："
    docker network ls --filter dangling=true \
        --format 'table {{.ID}}\t{{.Name}}\t{{.Driver}}' || true

    echo
    info "6. 数据卷："
    echo "所有数据卷均保留，不执行删除。"
}

# ==================================================
# Docker 综合清理
# ==================================================

docker_comprehensive_cleanup() {
    echo
    echo "=================================================="
    echo "           Docker 综合清理（深度模式）"
    echo "=================================================="

    docker_comprehensive_preview

    echo
    warn "本次综合清理将执行以下操作："
    echo "  1. 删除已停止的容器"
    echo "  2. 清理悬空镜像"
    echo "  3. 删除所有没有容器引用的镜像"
    echo "  4. 清理全部未使用构建缓存"
    echo "  5. 删除未使用网络"

    echo
    echo "以下内容绝不会删除："
    echo "  - 正在运行的容器"
    echo "  - 正在被运行中容器引用的镜像"
    echo "  - 所有 Docker 数据卷"
    echo "  - 宿主机业务目录和项目文件"

    echo
    warn "注意：未使用镜像删除后，未来可能需要重新下载。"
    warn "停止容器内部未挂载的数据也会随容器删除。"

    echo

    if ! confirm "确认执行 Docker 综合深度清理？"; then
        warn "已取消。"
        return
    fi

    echo
    log "开始 Docker 综合清理..."

    echo
    info "步骤 1/5：清理已停止容器"
    docker container prune -f || warn "停止容器清理失败。"

    echo
    info "步骤 2/5：清理悬空镜像"
    docker image prune -f || warn "悬空镜像清理失败。"

    echo
    info "步骤 3/5：清理未使用镜像"
    docker image prune -a -f || warn "未使用镜像清理失败。"

    echo
    info "步骤 4/5：清理构建缓存"
    docker builder prune -a -f || warn "构建缓存清理失败。"

    echo
    info "步骤 5/5：清理未使用网络"
    docker network prune -f || warn "未使用网络清理失败。"

    echo
    log "Docker 综合清理执行完毕。"
    echo
    info "清理后的 Docker 空间情况："
    docker system df
}

# ==================================================
# Docker 清理子菜单
# ==================================================

docker_menu() {
    while true; do
        clear 2>/dev/null || true

        echo -e "${CYAN}"
        echo "=================================================="
        echo "                 Docker 垃圾清理"
        echo "=================================================="
        echo -e "${NC}"

        echo "1. 清理已停止的容器"
        echo "   删除已经停止的容器，不影响运行中的容器。"
        echo
        echo "2. 清理悬空镜像"
        echo "   删除没有标签且没有容器使用的镜像。"
        echo
        echo "3. 清理未使用镜像"
        echo "   删除所有没有容器引用的镜像，包括带标签的镜像。"
        echo
        echo "4. 清理构建缓存"
        echo "   删除 Docker 构建过程中产生的未使用缓存。"
        echo
        echo "5. 清理未使用网络"
        echo "   删除没有任何容器连接的 Docker 网络。"
        echo
        echo "6. 检查未使用的数据卷"
        echo "   显示未被容器引用的数据卷及占用空间，只检查不删除。"
        echo
        echo "7. Docker 综合清理（深度模式）"
        echo "   综合执行 1、2、3、4、5，保留所有数据卷。"
        echo
        echo "8. 返回主菜单"
        echo
        echo "--------------------------------------------------"

        read -r -p "请选择操作 [1-8]: " choice

        case "$choice" in
            1)
                if check_docker; then docker_clean_stopped; fi
                pause
                ;;
            2)
                if check_docker; then docker_clean_dangling_images; fi
                pause
                ;;
            3)
                if check_docker; then docker_clean_unused_images; fi
                pause
                ;;
            4)
                if check_docker; then docker_clean_build_cache; fi
                pause
                ;;
            5)
                if check_docker; then docker_clean_network; fi
                pause
                ;;
            6)
                if check_docker; then docker_check_volumes; fi
                pause
                ;;
            7)
                if check_docker; then docker_comprehensive_cleanup; fi
                pause
                ;;
            8)
                return
                ;;
            *)
                warn "无效选项。"
                sleep 1
                ;;
        esac
    done
}

# ==================================================
# Docker 占用空间分析
# ==================================================

docker_space_analysis() {
    if ! check_docker; then
        return
    fi

    echo
    echo "=================================================="
    echo "              Docker 占用空间分析"
    echo "=================================================="

    echo
    info "Docker 总体空间占用："
    docker system df

    echo
    info "Docker 详细空间占用："
    docker system df -v

    echo
    info "容器占用情况："
    docker ps -a --size \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Size}}'

    echo
    info "镜像占用情况："
    docker image ls \
        --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'

    echo
    info "数据卷列表："
    docker volume ls

    echo
    info "构建缓存占用："
    docker builder du 2>/dev/null || true

    echo
    log "Docker 空间分析完成。"
    warn "本功能只读取信息，不执行删除操作。"
}

# ==================================================
# 系统信息
# ==================================================

show_system_info() {
    clear 2>/dev/null || true

    echo
    echo "=================================================="
    echo "                系统及磁盘信息"
    echo "=================================================="

    echo
    echo "系统版本：$OS_NAME"
    echo "系统架构：$ARCH"
    echo "内核版本：$(uname -r)"
    echo "主机名称：$(hostname)"
    echo "运行时间：$(uptime -p 2>/dev/null || uptime)"

    echo
    echo "========== CPU 信息 =========="
    if command -v nproc >/dev/null 2>&1; then
        echo "CPU 核心数：$(nproc)"
    fi
    if command -v lscpu >/dev/null 2>&1; then
        lscpu | grep -E 'Model name|Architecture|CPU\(s\)|型号名称' | head -8 || true
    fi

    echo
    echo "========== 内存信息 =========="
    free -h

    echo
    echo "========== 磁盘分区 =========="
    df -hT

    echo
    echo "========== APT 缓存 =========="
    du -sh /var/cache/apt/archives 2>/dev/null || true

    echo
    echo "========== 临时目录 =========="
    du -sh /tmp /var/tmp 2>/dev/null || true

    echo
    echo "========== 系统日志 =========="
    get_journal_size

    echo
    echo "========== Docker 状态 =========="
    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            docker version --format 'Docker 版本：{{.Server.Version}}' 2>/dev/null || true
            docker system df
        else
            warn "Docker 已安装，但服务未正常运行。"
        fi
    else
        echo "未安装 Docker。"
    fi

    echo
    echo "=================================================="
}

# ==================================================
# 主菜单
# ==================================================

main_menu() {
    while true; do
        clear 2>/dev/null || true

        echo -e "${CYAN}"
        echo "=================================================="
        echo "              $SCRIPT_NAME"
        echo "=================================================="
        echo -e "${NC}"

        echo "系统：$OS_NAME"
        echo "架构：$ARCH"
        echo "内核：$(uname -r)"
        disk_usage

        echo
        echo "---------------------- 主菜单 ----------------------"
        echo
        echo "1. 安全清理系统垃圾"
        echo "   清理 APT 缓存、无用依赖、过期日志、临时文件及崩溃文件。"
        echo
        echo "2. 深度清理系统垃圾"
        echo "   深度清理系统缓存、历史日志及过期临时文件，释放更多空间。"
        echo
        echo "3. Docker 垃圾清理"
        echo "   清理停止的容器、无用镜像、构建缓存及未使用网络。"
        echo
        echo "4. Docker 占用空间分析"
        echo "   分析 Docker 镜像、容器、数据卷及构建缓存的空间占用。"
        echo
        echo "5. 查看系统及磁盘信息"
        echo "   查看系统版本、CPU、内存、磁盘、APT 缓存及日志占用。"
        echo
        echo "6. 退出"
        echo
        echo "----------------------------------------------------"
        echo

        read -r -p "请选择操作 [1-6]: " choice

        case "$choice" in
            1)
                system_cleanup safe
                pause
                ;;
            2)
                system_cleanup deep
                pause
                ;;
            3)
                docker_menu
                ;;
            4)
                docker_space_analysis
                pause
                ;;
            5)
                show_system_info
                pause
                ;;
            6)
                log "感谢使用，再见！"
                exit 0
                ;;
            *)
                warn "无效选项，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

# ==================================================
# 主程序
# ==================================================

main() {
    check_root
    check_system
    check_arch
    main_menu
}

main "$@"
