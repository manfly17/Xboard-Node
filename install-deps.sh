
#!/usr/bin/env bash
#
# install-deps.sh
#
# 仅负责系统依赖安装与检查
#
# 支持系统：
#   Debian 11 / 12 / 13
#   Ubuntu 20.04 / 22.04 / 24.04 / 26.04
#
# 支持架构：
#   amd64 / arm64 / armhf / ppc64el / s390x
#
# 基础依赖：
#   ca-certificates
#   curl
#   git
#   python3
#
# Docker：
#   Docker CE
#   Docker Compose V2
#
# 安全原则：
#   1. 已安装依赖不重复安装
#   2. 不主动升级已有软件包
#   3. 不执行 apt upgrade
#   4. 安装前模拟 APT 安装计划
#   5. 发现升级已有软件包时停止
#   6. 发现删除软件包时停止
#   7. 不主动替换已有 Docker
#   8. 不删除容器、镜像、卷及数据
#   9. 不修改系统发行版及软件源
#
# ============================================================

set -Eeuo pipefail

# ============================================================
# 1. 输出及错误处理
# ============================================================

if [[ -t 1 ]]; then
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    BLUE='\033[34m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    RESET=''
fi

info() {
    echo -e "${BLUE}[信息]${RESET} $*"
}

ok() {
    echo -e "${GREEN}[成功]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[提醒]${RESET} $*"
}

err() {
    echo -e "${RED}[错误]${RESET} $*" >&2
}

die() {
    err "$*"
    exit 1
}

trap 'err "脚本执行失败，行号：${LINENO}，命令：${BASH_COMMAND}"' ERR

# ============================================================
# 2. 基础函数
# ============================================================

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

pkg_installed() {
    local package="$1"
    local status

    status="$(
        dpkg-query -W \
            -f='${db:Status-Status}' \
            "$package" 2>/dev/null || true
    )"

    [[ "$status" == "installed" ]]
}

is_systemd() {
    [[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" == "systemd" ]]
}

apt_update() {
    info "更新 APT 软件包索引……"

    if ! apt-get update; then
        die "APT 软件包索引更新失败，请检查软件源及网络。"
    fi

    ok "APT 软件包索引更新完成。"
}

# ============================================================
# 3. APT 安装计划安全检查
# ============================================================

check_apt_plan() {

    local simulation

    if (($# == 0)); then
        return 0
    fi

    info "检查软件包安装计划……"

    if ! simulation="$(
        apt-get -s \
            --no-upgrade \
            --no-install-recommends \
            install "$@"
    )"; then

        err "APT 无法生成安装计划。"
        [[ -n "$simulation" ]] && echo "$simulation"
        return 1
    fi

    # 禁止删除现有软件包
    if grep -Eq '^Remv ' <<< "$simulation"; then

        err "安装计划涉及删除现有软件包，已取消。"

        grep -E '^Remv ' <<< "$simulation"

        return 1
    fi

    # 检查已有软件包是否会升级
    if grep -Eq '^Inst [^ ]+ \[[^]]+\]' <<< "$simulation"; then

        err "安装计划涉及升级现有软件包，已取消。"

        grep -E '^Inst [^ ]+ \[[^]]+\]' <<< "$simulation"

        return 1
    fi

    echo "$simulation"

    ok "APT 安装计划检查通过。"

    return 0
}

# ============================================================
# 4. 安全安装软件包
# ============================================================

apt_install_safe() {

    local packages=("$@")

    ((${#packages[@]} > 0)) || return 0

    # 安装前模拟
    check_apt_plan "${packages[@]}" || {
        die "安装计划未通过安全检查，已停止安装。"
    }

    info "开始安装以下软件包："

    printf '  - %s\n' "${packages[@]}"

    apt-get \
        --no-upgrade \
        --no-install-recommends \
        install -y "${packages[@]}"

    ok "软件包安装完成。"
}

# ============================================================
# 5. Root 权限检查
# ============================================================

if [[ "$EUID" -ne 0 ]]; then
    die "请使用 root 用户运行此脚本。"
fi

# ============================================================
# 6. 操作系统检测
# ============================================================

if [[ ! -f /etc/os-release ]]; then
    die "无法识别当前操作系统。"
fi

# shellcheck disable=SC1091
source /etc/os-release

OS_ID="${ID:-}"
OS_VERSION="${VERSION_ID:-}"
OS_CODENAME="${VERSION_CODENAME:-}"
OS_PRETTY="${PRETTY_NAME:-Unknown}"

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"

info "检测系统：${OS_PRETTY}"
info "系统架构：${ARCH}"

case "$OS_ID" in

    debian)

        case "$OS_VERSION" in
            11|12|13)
                ;;
            *)
                die "暂不支持 Debian ${OS_VERSION}。"
                ;;
        esac

        ;;

    ubuntu)

        case "$OS_VERSION" in
            20.04|22.04|24.04|26.04)
                ;;
            *)
                die "暂不支持 Ubuntu ${OS_VERSION}。"
                ;;
        esac

        ;;

    *)
        die "暂不支持当前操作系统：${OS_ID}"
        ;;

esac

if [[ -z "$OS_CODENAME" ]]; then
    OS_CODENAME="${UBUNTU_CODENAME:-}"
fi

if [[ -z "$OS_CODENAME" ]]; then
    die "无法获取系统发行版代号。"
fi

case "$ARCH" in
    amd64|arm64|armhf|ppc64el|s390x)
        ;;
    *)
        die "暂不支持当前 CPU 架构：${ARCH}"
        ;;
esac

if ! command_exists apt-get || ! command_exists dpkg-query; then
    die "当前系统缺少 APT 或 dpkg。"
fi

if [[ "$OS_ID" == "debian" && "$OS_VERSION" == "11" ]]; then
    warn "Debian 11 已结束 LTS 支持，部分软件源可能无法正常提供软件包。"
fi

# ============================================================
# 7. 检测基础依赖
# ============================================================

info "检查基础依赖……"

MISSING_PACKAGES=()

# ca-certificates
if pkg_installed ca-certificates; then

    ok "ca-certificates 已安装，跳过。"

else

    MISSING_PACKAGES+=(ca-certificates)

fi

# curl
if pkg_installed curl && command_exists curl; then

    ok "curl 已安装，跳过。"

elif pkg_installed curl; then

    die "curl 软件包已安装，但命令不存在，请先修复软件包。"

else

    MISSING_PACKAGES+=(curl)

fi

# git
if pkg_installed git && command_exists git; then

    ok "git 已安装，跳过。"

elif pkg_installed git; then

    die "git 软件包已安装，但命令不存在，请先修复软件包。"

else

    MISSING_PACKAGES+=(git)

fi

# python3
if pkg_installed python3 && command_exists python3; then

    ok "python3 已安装，跳过。"

elif pkg_installed python3; then

    die "python3 软件包已安装，但命令不存在，请先修复软件包。"

else

    MISSING_PACKAGES+=(python3)

fi

# ============================================================
# 8. 安装缺失的基础依赖
# ============================================================

if ((${#MISSING_PACKAGES[@]} > 0)); then

    info "发现以下缺失的基础依赖："

    printf '  - %s\n' "${MISSING_PACKAGES[@]}"

    apt_update

    apt_install_safe "${MISSING_PACKAGES[@]}"

else

    ok "基础依赖已全部安装，无需重复安装。"

fi

# ============================================================
# 9. 验证基础依赖
# ============================================================

info "验证基础依赖……"

for command_name in curl git python3; do

    if ! command_exists "$command_name"; then
        die "基础依赖验证失败：${command_name} 命令不存在。"
    fi

done

for package in ca-certificates curl git python3; do

    if ! pkg_installed "$package"; then
        die "基础依赖验证失败：${package} 未正确安装。"
    fi

done

ok "基础依赖验证通过。"

# ============================================================
# 10. Docker 官方仓库配置
# ============================================================

DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_SOURCE="/etc/apt/sources.list.d/docker-xboard-node.list"

configure_docker_repository() {

    info "检查 Docker 官方软件源……"

    install -d -m 0755 /etc/apt/keyrings

    # 下载 Docker 官方 ASCII 格式公钥
    # 不需要安装 gnupg，也不需要执行 gpg --dearmor

    if [[ ! -s "$DOCKER_KEYRING" ]]; then

        info "下载 Docker 官方 GPG 公钥……"

        local temp_key

        temp_key="$(mktemp)"

        if ! curl -fsSL \
            "https://download.docker.com/linux/${OS_ID}/gpg" \
            -o "$temp_key"; then

            rm -f "$temp_key"

            die "无法下载 Docker 官方 GPG 公钥。"

        fi

        if ! grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$temp_key"; then

            rm -f "$temp_key"

            die "Docker GPG 公钥格式异常。"

        fi

        install -m 0644 "$temp_key" "$DOCKER_KEYRING"

        rm -f "$temp_key"

        ok "Docker GPG 公钥配置完成。"

    else

        ok "Docker GPG 公钥已存在，跳过。"

    fi

    # 检查是否已经配置 Docker 官方仓库
    if grep -Rqs \
        "download.docker.com/linux/${OS_ID}" \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d/ 2>/dev/null; then

        ok "检测到 Docker 官方软件源，跳过重复添加。"

    else

        info "添加 Docker 官方软件源……"

        cat > "$DOCKER_SOURCE" <<EOF
deb [arch=${ARCH} signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable
EOF

        chmod 0644 "$DOCKER_SOURCE"

        ok "Docker 官方软件源添加完成。"

    fi
}

# ============================================================
# 11. Docker 服务检查
# ============================================================

start_and_check_docker() {

    if ! command_exists docker; then
        die "Docker 命令不存在。"
    fi

    info "检查 Docker 服务状态……"

    if docker info >/dev/null 2>&1; then

        ok "Docker 服务正常运行。"

        return 0

    fi

    if ! is_systemd; then

        die "当前环境不是 systemd，且 Docker 服务未运行，无法自动启动。"

    fi

    if ! systemctl list-unit-files docker.service \
        --no-legend 2>/dev/null | grep -q docker.service; then

        die "Docker 服务单元不存在。"

    fi

    info "尝试启动 Docker 服务……"

    systemctl enable docker

    systemctl start docker

    if ! docker info >/dev/null 2>&1; then

        die "Docker 服务启动失败，请检查 systemctl status docker。"

    fi

    ok "Docker 服务启动成功。"
}

# ============================================================
# 12. 检查 Docker
# ============================================================

if command_exists docker; then

    info "检测到已有 Docker，保留当前 Docker 环境。"

    start_and_check_docker

else

    info "未检测到 Docker，准备安装 Docker CE。"

    if ! is_systemd; then
        die "当前环境未使用 systemd，无法安全安装 Docker 服务。"
    fi

    # 检查可能冲突的软件包
    CONFLICT_PACKAGES=()

    for package in \
        docker.io \
        docker-doc \
        docker-compose \
        docker-compose-v2 \
        podman-docker \
        containerd \
        runc; do

        if pkg_installed "$package"; then
            CONFLICT_PACKAGES+=("$package")
        fi

    done

    if ((${#CONFLICT_PACKAGES[@]} > 0)); then

        err "检测到可能与 Docker CE 冲突的软件包："

        printf '  - %s\n' "${CONFLICT_PACKAGES[@]}"

        die "为避免影响现有容器环境，已停止 Docker 安装。"

    fi

    configure_docker_repository

    apt_update

    DOCKER_PACKAGES=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )

    info "准备安装 Docker CE 和 Compose V2。"

    apt_install_safe "${DOCKER_PACKAGES[@]}"

    systemctl enable docker

    systemctl start docker

    start_and_check_docker

fi

# ============================================================
# 13. Docker Compose V2 检查
# ============================================================

if docker compose version >/dev/null 2>&1; then

    ok "Docker Compose V2 已安装，跳过。"

else

    warn "未检测到 Docker Compose V2。"

    if pkg_installed docker-ce-cli; then

        info "检测到 Docker CE CLI，准备补装 Compose V2。"

        configure_docker_repository

        apt_update

        apt_install_safe docker-compose-plugin

    else

        info "当前 Docker 并非通过 Docker CE CLI 软件包安装。"

        if ! is_systemd; then
            die "当前环境无法安全补装 Compose V2。"
        fi

        apt_update

        COMPOSE_CANDIDATE="$(
            apt-cache policy docker-compose-v2 2>/dev/null |
            awk '/Candidate:/ {print $2; exit}'
        )"

        if [[ -n "$COMPOSE_CANDIDATE" &&
              "$COMPOSE_CANDIDATE" != "(none)" ]]; then

            info "检测到发行版提供的 Compose V2。"

            apt_install_safe docker-compose-v2

        else

            die "没有找到可安全安装的 Compose V2 软件包，已停止。"

        fi

    fi

fi

# ============================================================
# 14. 最终验证
# ============================================================

info "执行最终依赖检查……"

for command_name in \
    curl \
    git \
    python3 \
    docker; do

    if ! command_exists "$command_name"; then
        die "最终检查失败：缺少命令 ${command_name}。"
    fi

done

for package in \
    ca-certificates \
    curl \
    git \
    python3; do

    if ! pkg_installed "$package"; then
        die "最终检查失败：软件包 ${package} 未安装。"
    fi

done

if ! docker info >/dev/null 2>&1; then
    die "最终检查失败：Docker 服务不可用。"
fi

if ! docker compose version >/dev/null 2>&1; then
    die "最终检查失败：Docker Compose V2 不可用。"
fi

# ============================================================
# 15. 输出结果
# ============================================================

echo
echo "============================================"
ok "系统依赖安装及检查全部通过！"
echo "============================================"
echo
echo "系统信息：${OS_PRETTY}"
echo "CPU 架构：${ARCH}"
echo
echo "基础依赖："
echo "  ca-certificates : OK"
echo "  curl            : OK"
echo "  git             : OK"
echo "  python3         : OK"
echo
echo "Docker 环境："
docker --version
docker compose version
echo
echo "Docker 服务："
ok "运行正常"
echo
echo "============================================"
echo "本脚本仅负责系统依赖安装与检查。"
echo "============================================"
echo
