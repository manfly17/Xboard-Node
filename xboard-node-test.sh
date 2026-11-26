
#!/usr/bin/env bash
# Xboard-Node 安装与管理脚本
# 安装后使用：xbnode
# 适用：Debian、Ubuntu
# 依赖：Docker Engine、Docker Compose V2、Python3

set -Eeuo pipefail
umask 077

# DNS 函数通过变量返回开关状态，避免命令替换吞掉交互提示。
CUSTOM_DNS_ENABLED="no"

REPO_URL="https://github.com/cedar2025/xboard-node.git"
REPO_BRANCH="compose"
IMAGE="ghcr.io/cedar2025/xboard-node:latest"
SERVICE="xboard-node"
CONTAINER="xboard-node"

DEFAULT_DIR="/root/xboard-node"
MANAGER_BIN="/usr/local/bin/xbnode"
MANAGER_CONFIG="/etc/xboard-node-manager.conf"

PROJECT_DIR="$DEFAULT_DIR"
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}")"

# -------------------- 基础函数 --------------------

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
blue()   { printf '\033[36m%s\033[0m\n' "$*"; }

pause() {
    echo
    read -r -p "按回车键继续..." _
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        red "请使用 root 用户运行。"
        exit 1
    fi
}

require_docker() {
    command -v docker >/dev/null 2>&1 || {
        red "未检测到 Docker。"
        return 1
    }

    docker compose version >/dev/null 2>&1 || {
        red "未检测到 Docker Compose V2。"
        return 1
    }
}

require_python() {
    command -v python3 >/dev/null 2>&1 || {
        red "未检测到 Python3，请先安装：apt-get install -y python3"
        return 1
    }
}

# -------------------- 统一依赖检查 --------------------

check_dependencies() {
    local missing=()

    for cmd in curl git python3 docker; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]})); then
        red "缺少依赖：${missing[*]}"
        echo "请先自行安装缺失的依赖后，再运行本脚本。"
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        red "Docker Compose V2 不可用。"
        echo "请先运行依赖安装脚本或检查 Docker 环境。"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        red "Docker 服务未运行或当前用户无权限访问。"
        echo "可以检查：systemctl status docker"
        return 1
    fi

    green "依赖检查通过。"
    return 0
}

load_manager_config() {
    if [[ -f "$MANAGER_CONFIG" ]]; then
        # shellcheck disable=SC1090
        source "$MANAGER_CONFIG"
    fi
}

save_manager_config() {
    local tmp="${MANAGER_CONFIG}.tmp.$$"
    mkdir -p "$(dirname "$MANAGER_CONFIG")"
    printf 'PROJECT_DIR=%q\n' "$PROJECT_DIR" > "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$MANAGER_CONFIG"
}

compose() {
    (
        cd "$PROJECT_DIR"
        docker compose -f compose.yml "$@"
    )
}

check_project() {
    [[ -d "$PROJECT_DIR" ]] || {
        red "项目目录不存在：$PROJECT_DIR"
        return 1
    }

    [[ -f "$PROJECT_DIR/compose.yml" ]] || {
        red "没有找到 compose.yml。"
        return 1
    }

    [[ -d "$PROJECT_DIR/config" ]] || {
        red "没有找到 config 目录。"
        return 1
    }
}

CONFIG_BACKUP_DONE="no"

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local backup_dir="$PROJECT_DIR/backup" filename stamp destination
    mkdir -p "$backup_dir"
    filename="$(basename "$file")"
    stamp="$(date +%Y%m%d-%H%M%S-%N)"
    destination="$backup_dir/${filename}.${stamp}.bak"
    cp -a -- "$file" "$destination" || return 1
    chmod 600 "$destination" || return 1
    green "已备份：$destination"
}

# -------------------- 全局命令安装 --------------------

install_manager_command() {
    if [[ "$SELF_PATH" != "$MANAGER_BIN" ]]; then
        [[ -f "$SELF_PATH" ]] || {
            red "无法定位当前脚本文件：$SELF_PATH"
            return 1
        }
        install -m 755 "$SELF_PATH" "$MANAGER_BIN"
    fi

    save_manager_config

    green "全局管理命令安装成功。"
    green "以后输入 xbnode 即可打开管理菜单。"
}

# -------------------- 生成 Compose 文件 --------------------

write_compose_file() {
    local use_custom_dns="${1:-no}"
    local tmp="$PROJECT_DIR/compose.yml.tmp.$$"
    {
        cat <<'YAML'
services:
  xboard-node:
    image: ghcr.io/cedar2025/xboard-node:latest
    container_name: xboard-node
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./config:/etc/xboard-node
YAML
        if [[ "$use_custom_dns" == "yes" ]]; then
            printf '%s\n' '      - ./sing_origin.json:/etc/xboard-node/sing_origin.json:ro'
        fi
        cat <<'YAML'
    command: ["-c", "/etc/xboard-node/config.yml"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YAML
    } > "$tmp"
    chmod 644 "$tmp"
    mv -f -- "$tmp" "$PROJECT_DIR/compose.yml"
    if [[ "$use_custom_dns" == "yes" ]]; then
        green "compose.yml 已生成（自定义 DNS：启用）。"
    else
        green "compose.yml 已生成（自定义 DNS：未启用）。"
    fi
}

# -------------------- 安装项目 --------------------

install_project() {
    require_docker || return 1
    require_python || return 1

    if ! command -v git >/dev/null 2>&1; then
        yellow "正在安装 Git..."
        apt-get update
        apt-get install -y git
    fi

    PROJECT_DIR="$DEFAULT_DIR"
    echo
    blue "项目固定安装目录：$PROJECT_DIR"

    if [[ -d "$PROJECT_DIR/.git" ]]; then
        yellow "检测到已有 Git 项目，保留现有仓库，不自动拉取更新。"

    elif [[ -d "$PROJECT_DIR" && -z "$(ls -A "$PROJECT_DIR" 2>/dev/null)" ]]; then
        git clone -b "$REPO_BRANCH" --depth 1 "$REPO_URL" "$PROJECT_DIR"

    elif [[ -e "$PROJECT_DIR" ]]; then
        red "目录已经存在且不是空目录，也不是 Git 项目。"
        red "为避免覆盖已有文件，请更换目录或先自行处理。"
        return 1

    else
        mkdir -p "$(dirname "$PROJECT_DIR")"
        git clone -b "$REPO_BRANCH" --depth 1 "$REPO_URL" "$PROJECT_DIR"
    fi

    [[ -f "$PROJECT_DIR/config/config.yml.example" || \
       -f "$PROJECT_DIR/config/config.yml" ]] || {
        red "未找到官方配置模板，请检查项目目录。"
        return 1
    }

    mkdir -p "$PROJECT_DIR/config" "$PROJECT_DIR/backup"

    # 初始化阶段统一备份；记录 config.yml 是否已在本次操作中备份
    CONFIG_BACKUP_DONE="no"
    backup_file "$PROJECT_DIR/compose.yml" || return 1

    if [[ -f "$PROJECT_DIR/config/config.yml" ]]; then
        backup_file "$PROJECT_DIR/config/config.yml" || return 1
        CONFIG_BACKUP_DONE="yes"
    fi

    backup_file "$PROJECT_DIR/sing_origin.json" || return 1

    # 初始化阶段先生成默认 Compose；是否挂载自定义 DNS，稍后由用户选择决定。
    write_compose_file "no"

    (
        cd "$PROJECT_DIR"
        docker compose config -q
    ) || {
        red "Compose 配置检查失败，未更新全局管理命令。"
        return 1
    }

    save_manager_config
    install_manager_command

    green "项目初始化完成。"
    echo "项目目录：$PROJECT_DIR"
}

# -------------------- Sing-box DNS 配置 --------------------

generate_sing_origin() {
    local file="$PROJECT_DIR/sing_origin.json"
    local answer dns_ip current_dns="1.1.1.1"

    # 读取已有配置中的 unlock-dns IP
    if [[ -s "$file" ]]; then
        current_dns="$(python3 - "$file" <<'PYDNS_CUR' 2>/dev/null || true
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)

    servers = data.get("dns", {}).get("servers", [])
    ip = next(
        (
            item.get("address")
            for item in servers
            if isinstance(item, dict)
            and item.get("tag") == "unlock-dns"
            and item.get("address")
        ),
        None
    )
    print(ip or "1.1.1.1")
except Exception:
    print("1.1.1.1")
PYDNS_CUR
)"
        current_dns="${current_dns:-1.1.1.1}"
    fi

    echo
    blue "========== Sing-box 自定义 DNS =========="
    echo "是否创建或修改项目根目录下的 sing_origin.json？"
    echo "默认创建；输入 n 跳过。"
    read -r -p "是否创建/修改 [Y/n]: " answer
    if [[ "$answer" =~ ^[Nn]([Oo])?$ ]]; then
        CUSTOM_DNS_ENABLED="no"
        yellow "已跳过自定义 DNS：不创建、不挂载 sing_origin.json，也不向 config.yml 添加 custom_config。"
        return 0
    fi

    read -r -p "请输入 DNS IP [${current_dns}]: " dns_ip
    dns_ip="${dns_ip:-$current_dns}"
    backup_file "$file" || return 1
    if ! python3 - "$dns_ip" "$file" <<'PYDNS_5821'
import sys, json, ipaddress, os, tempfile
ip, path = sys.argv[1], sys.argv[2]
try:
    ipaddress.ip_address(ip)
except ValueError:
    print("DNS 地址不是有效 IP。", file=sys.stderr)
    sys.exit(1)
data = {"dns": {"servers": [{"tag": "unlock-dns", "address": ip}], "strategy": "ipv4_only"}}
# 直接更新原文件，保留 inode，确保 Docker 单文件绑定挂载同步。
mode = "r+" if os.path.exists(path) else "w"
with open(path, mode, encoding="utf-8") as f:
    f.seek(0)
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
    f.truncate()
    f.flush()
    os.fsync(f.fileno())
os.chmod(path, 0o644)
PYDNS_5821
    then
        red "DNS 文件生成失败，原文件未被替换。"
        return 1
    fi
    chmod 644 "$file"
    CUSTOM_DNS_ENABLED="yes"
    green "DNS 文件已更新：$file"
}

# -------------------- 证书配置生成 --------------------

generate_config() {
    check_project || return 1
    require_python || return 1

    if [[ "${CONFIG_BACKUP_DONE:-no}" == "yes" ]]; then
        CONFIG_BACKUP_DONE="no"
        yellow "本次初始化已备份 config.yml，跳过重复备份。"
    else
        backup_file "$PROJECT_DIR/config/config.yml" || return 1
    fi

    echo
    blue "========== Xboard-Node 配置生成 =========="

    echo "请选择内核："
    echo "1. Sing-box"
    echo "2. Xray"

    local kernel_choice kernel custom_dns
    read -r -p "请选择 [1]: " kernel_choice
    kernel_choice="${kernel_choice:-1}"

    case "$kernel_choice" in
        1) kernel="singbox" ;;
        2) kernel="xray" ;;
        *) red "无效选择。"; return 1 ;;
    esac

    custom_dns="no"

    if [[ "$kernel" == "singbox" ]]; then
        generate_sing_origin || return 1
        custom_dns="$CUSTOM_DNS_ENABLED"
    fi

    echo
    blue "========== 面板及节点配置 =========="
    echo "接下来输入面板地址、Token、节点 ID 和证书配置。"
    echo

    if ! python3 - "$PROJECT_DIR" "$kernel" "$custom_dns" <<'PY'
import os, sys, json, shutil, pathlib
import urllib.parse, urllib.request, urllib.error

# Python 脚本由 heredoc 提供，交互输入改为从终端读取
try:
    sys.stdin = open("/dev/tty", "r")
except OSError:
    print("无法访问终端，无法进行交互配置。", file=sys.stderr)
    sys.exit(1)

project = pathlib.Path(sys.argv[1])
kernel = sys.argv[2]
custom_dns = sys.argv[3] == "yes"

config_dir = project / "config"
cert_dir = config_dir / "certs"
cert_dir.mkdir(parents=True, exist_ok=True)

def ask(prompt, default=None):
    value = input(prompt).strip()
    return value if value else default


def get_node_config(panel_url, token, node_id):
    """从 Xboard 获取节点真实配置，不在错误时猜测。"""
    url = panel_url.rstrip("/") + "/api/v2/server/config"
    params = urllib.parse.urlencode({
        "node_id": str(node_id),
        "token": token
    })
    request = urllib.request.Request(
        url + "?" + params,
        headers={"Accept": "application/json"}
    )

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise ValueError(f"节点 {node_id} API 请求失败，HTTP {e.code}")
    except urllib.error.URLError as e:
        raise ValueError(f"节点 {node_id} API 网络连接失败：{e.reason}")
    except Exception as e:
        raise ValueError(f"节点 {node_id} API 返回数据异常：{e}")

    if not isinstance(result, dict):
        raise ValueError(f"节点 {node_id} API 返回格式错误")

    if result.get("status") == "fail":
        raise ValueError(
            f"节点 {node_id} 查询失败：{result.get('message', '未知错误')}"
        )

    protocol = str(result.get("protocol", "")).lower()
    if not protocol:
        raise ValueError(f"节点 {node_id} 未返回 protocol 字段")

    return result


def _as_int(value):
    try:
        if isinstance(value, bool):
            return int(value)
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _first_dict(config, *keys):
    for key in keys:
        value = config.get(key)
        if isinstance(value, dict):
            return value
    return {}


def _get_sni(config):
    """按 Xboard API 实际字段读取服务端 SNI；Host 仅作为后备。"""
    candidates = []

    if _as_int(config.get("tls")) == 2:
        # Xboard 会把 VLESS/Trojan 的 reality_settings 映射到 tls_settings。
        keys = (
            "reality_settings", "realitySettings", "reality",
            "tls_settings", "tlsSettings", "tls",
        )
    else:
        keys = (
            "tls_settings", "tlsSettings", "tls",
            "reality_settings", "realitySettings", "reality",
        )

    for key in keys:
        value = config.get(key)
        if isinstance(value, dict):
            candidates.extend([
                value.get("server_name"),
                value.get("serverName"),
                value.get("server_name_indication"),
                value.get("sni"),
            ])

    candidates.extend([
        config.get("server_name"),
        config.get("serverName"),
        config.get("sni"),
    ])

    for value in candidates:
        if isinstance(value, str) and value.strip():
            return value.strip()

    # Shadowsocks + V2Ray Plugin 的 TLS 域名来自 plugin_opts.host，
    # 优先于通用 host，避免把节点连接地址误当作插件证书域名。
    plugin = str(config.get("plugin") or "").strip().lower()
    plugin_opts = config.get("plugin_opts")
    if plugin in ("v2ray-plugin", "v2ray_plugin", "v2rayplugin"):
        if isinstance(plugin_opts, dict):
            plugin_host = plugin_opts.get("host")
        elif isinstance(plugin_opts, str):
            plugin_host = ""
            for item in plugin_opts.split(";"):
                if "=" in item:
                    key, value = item.split("=", 1)
                    if key.strip().lower() == "host":
                        plugin_host = value.strip().strip("\"'")
                        break
        else:
            plugin_host = ""
        if isinstance(plugin_host, str) and plugin_host.strip():
            return plugin_host.strip()

    # 其他 TLS 入站按原有逻辑回退到 Xboard Host。
    host = config.get("host")
    return host.strip() if isinstance(host, str) and host.strip() else ""


def _config_dicts(config):
    """获取所有可能承载 TLS/REALITY 参数的配置字典。"""
    result = []
    for key in (
        "tls_settings", "tlsSettings", "tls",
        "reality_settings", "realitySettings", "reality",
    ):
        value = config.get(key)
        if isinstance(value, dict) and value not in result:
            result.append(value)
    return result


# 与 Xboard-Node 1.13 的 Kernel.Protocols() 对照。
# 注意：Xray 虽有 SOCKS/HTTP 构建函数，但没有在 Protocols() 注册；
# Sing-box 虽注册 hysteria2 字符串，但 buildInbound 实际只处理 protocol=hysteria。
KERNEL_PROTOCOLS = {
    "singbox": {
        "vmess", "vless", "trojan", "shadowsocks", "hysteria",
        "tuic", "naive", "socks", "http", "anytls", "mieru",
    },
    "xray": {
        "vmess", "vless", "trojan", "shadowsocks", "hysteria",
    },
}

# Xboard-Node 1.13 internal/cert/dnsproviders 的注册名称及兼容别名。
PANEL_DNS_PROVIDERS = {
    "alidns", "aliyun", "azure", "bunny", "cloudflare", "cf", "desec",
    "digitalocean", "do", "duckdns", "gandi", "godaddy",
    "googleclouddns", "gcp", "gcloud", "hetzner", "huaweicloud", "huawei",
    "linode", "namecheap", "namesilo", "netlify", "ovh", "porkbun",
    "route53", "aws", "tencentcloud", "tencent", "vultr",
}


def _domain_covers_sni(cert_domain, sni):
    """检查单域名或一级通配符域名是否覆盖节点 SNI。"""
    domain = str(cert_domain or "").strip().lower().rstrip(".")
    server_name = str(sni or "").strip().lower().rstrip(".")
    if not domain or not server_name:
        return not server_name

    if domain == server_name:
        return True

    if domain.startswith("*."):
        suffix = domain[1:]  # .example.com
        if server_name.endswith(suffix):
            prefix = server_name[:-len(suffix)]
            return bool(prefix) and "." not in prefix

    return False


def _active_panel_cert(config, sni=""):
    """
    检查 Xboard 是否下发了后端 1.13 可识别且字段完整的 cert_config。
    面板证书优先于本地证书；若面板配置无效，必须停止，不能假装本地证书会覆盖它。
    """
    if "cert_config" not in config or config.get("cert_config") is None:
        return False, ""

    cert = config.get("cert_config")
    if not isinstance(cert, dict):
        raise ValueError("Xboard 返回的 cert_config 不是 JSON 对象，无法安全判断")

    mode = str(cert.get("cert_mode") or cert.get("mode") or "").strip().lower()
    if mode in ("", "none"):
        return False, ""

    domain = str(cert.get("domain") or "").strip()

    if mode == "self":
        if not domain:
            raise ValueError("面板 cert_config 使用 self，但没有填写 domain；后端会默认生成 localhost 证书")
        if sni and not _domain_covers_sni(domain, sni):
            raise ValueError(
                f"面板自签证书域名 {domain} 不覆盖节点 SNI {sni}，请先修正 Xboard 节点证书配置"
            )
        return True, mode

    if mode == "http":
        if not domain:
            raise ValueError("面板 cert_config 使用 http，但缺少 domain")
        if sni and not _domain_covers_sni(domain, sni):
            raise ValueError(
                f"面板 HTTP-01 证书域名 {domain} 不覆盖节点 SNI {sni}，请先修正 Xboard 节点证书配置"
            )
        return True, mode

    if mode == "dns":
        provider = str(cert.get("dns_provider") or "").strip().lower()
        if not domain or not provider:
            raise ValueError("面板 cert_config 使用 dns，但缺少 domain 或 dns_provider")
        if provider not in PANEL_DNS_PROVIDERS:
            raise ValueError(
                f"面板 cert_config 的 DNS 服务商 {provider!r} 不在 Xboard-Node 1.13 支持列表中"
            )
        if sni and not _domain_covers_sni(domain, sni):
            raise ValueError(
                f"面板 DNS-01 证书域名 {domain} 不覆盖节点 SNI {sni}，请先修正 Xboard 节点证书配置"
            )
        return True, mode

    if mode == "file":
        if not str(cert.get("cert_file") or "").strip() or not str(cert.get("key_file") or "").strip():
            raise ValueError("面板 cert_config 使用 file，但 cert_file/key_file 不完整")
        return True, mode

    if mode == "content":
        if not str(cert.get("cert_content") or "").strip() or not str(cert.get("key_content") or "").strip():
            raise ValueError("面板 cert_config 使用 content，但 cert_content/key_content 不完整")
        return True, mode

    raise ValueError(
        f"面板 cert_config 的模式 {mode!r} 不被 Xboard-Node 1.13 识别；"
        "支持 none/http/dns/self/file/content。请先修正面板配置"
    )


def _ss_plugin_certificate_info(config):
    """解析 Xboard UniProxy 的 Shadowsocks plugin/plugin_opts 字段。"""
    marker = object()
    plugin = config.get("plugin", marker)
    opts = config.get("plugin_opts", "")
    if plugin is marker:
        return "UNKNOWN", "Shadowsocks API 未返回 plugin 字段，无法确认是否启用插件", ""
    plugin = str(plugin or "").strip().lower()
    if not plugin or plugin in {"none", "null", "off"}:
        return "NO_CERT", "Shadowsocks 原生模式（无插件）不需要普通 TLS 证书", ""

    if isinstance(opts, dict):
        options = {str(k).strip().lower(): str(v).strip() for k, v in opts.items()}
    elif isinstance(opts, str):
        options = {}
        for item in opts.split(";"):
            item = item.strip()
            if not item:
                continue
            if "=" in item:
                key, value = item.split("=", 1)
                options[key.strip().lower()] = value.strip().strip("\"'")
            else:
                options[item.lower()] = "true"
    elif opts in (None, ""):
        options = {}
    else:
        return "UNKNOWN", f"Shadowsocks 插件参数格式无法识别：{type(opts).__name__}", ""

    aliases = {
        "v2ray_plugin": "v2ray-plugin", "v2rayplugin": "v2ray-plugin",
        "obfs-local": "simple-obfs", "obfs_local": "simple-obfs",
        "simple_obfs": "simple-obfs", "shadowtls": "shadow-tls",
    }
    plugin = aliases.get(plugin, plugin)

    if plugin == "v2ray-plugin":
        tls_enabled = "tls" in options and str(options.get("tls", "true")).strip().lower() in ("", "true", "1", "yes", "on")
        host = options.get("host", "").strip()
        if not tls_enabled:
            return "NO_CERT", "Shadowsocks + V2Ray Plugin 未启用 TLS", host
        mode = options.get("mode", "websocket").strip().lower()
        if mode not in ("websocket", "ws", "quic"):
            return "UNKNOWN", f"V2Ray Plugin TLS 模式无法确认：{mode!r}", host
        detail = f"Shadowsocks + V2Ray Plugin（mode={mode}）启用了 TLS，需要普通 TLS 证书"
        detail += f"；插件 Host={host}" if host else "；插件未提供 Host，后续需要填写证书域名"
        return "NEED_CERT", detail, host

    if plugin == "simple-obfs":
        return "NO_CERT", "Shadowsocks + simple-obfs 属于混淆插件，obfs=tls 不代表需要本地 TLS 证书", ""

    if plugin == "shadow-tls":
        return "UNKNOWN", "检测到 ShadowTLS 插件；其证书/上游 TLS 处理依赖具体版本和服务端实现，当前证书模块不能安全推断", options.get("host", "")

    return "UNKNOWN", f"未知 Shadowsocks 插件 {plugin!r}，拒绝猜测证书需求", options.get("host", "")


def decide_certificate(config, kernel):
    """
    按 Xboard-Node 1.13 实际协议注册表、入站构建逻辑和 TLS 校验规则决策。

    NEED_CERT：需要普通 TLS 证书。
    NO_CERT：不需要本地普通 TLS 证书。
    UNKNOWN：字段不足、内核不支持或无法安全判断。
    """
    if not isinstance(config, dict):
        return "UNKNOWN", "节点 API 配置不是 JSON 对象"

    kernel = str(kernel or "").strip().lower()
    if kernel not in KERNEL_PROTOCOLS:
        return "UNKNOWN", f"未知内核：{kernel!r}"

    protocol = str(config.get("protocol") or "").strip().lower()
    if not protocol:
        return "UNKNOWN", "API 缺少 protocol 字段"

    if protocol not in KERNEL_PROTOCOLS[kernel]:
        supported = ", ".join(sorted(KERNEL_PROTOCOLS[kernel]))
        return (
            "UNKNOWN",
            f"{kernel} 内核不支持协议 {protocol!r}；"
            f"该内核在 Xboard-Node 1.13 中注册的协议为：{supported}"
        )

    tls_raw = config.get("tls")
    tls_num = _as_int(tls_raw)
    sni = _get_sni(config)

    reality_sources = _config_dicts(config)

    # VLESS / Trojan REALITY：只需要私钥和 server_name 或 dest；
    # 后端 1.13 的 validateRealityRequirements 并不强制 short_id。
    if protocol in {"vless", "trojan"} and tls_num == 2:
        private_key = ""
        reality_server_name = ""
        reality_dest = ""

        for source in reality_sources:
            private_key = private_key or str(
                source.get("private_key") or source.get("privateKey") or ""
            ).strip()
            reality_server_name = reality_server_name or str(
                source.get("server_name") or source.get("serverName") or ""
            ).strip()
            reality_dest = reality_dest or str(source.get("dest") or "").strip()

        if not private_key:
            return "UNKNOWN", f"{protocol.upper()} REALITY 缺少 tls_settings.private_key"
        if not reality_server_name and not reality_dest:
            return (
                "UNKNOWN",
                f"{protocol.upper()} REALITY 缺少 tls_settings.server_name 和 dest",
            )

        return "NO_CERT", f"{protocol.upper()} + REALITY，不需要本地普通 TLS 证书"

    if protocol == "vmess" and tls_num == 2:
        return "UNKNOWN", "VMess 不支持当前 REALITY 证书判断方式，请核实面板配置"

    # Hysteria：协议本身使用 TLS。Xray 仅支持 v2，Sing-box 支持 v1/v2。
    if protocol == "hysteria":
        version = _as_int(config.get("version"))
        if version not in (1, 2):
            return "UNKNOWN", "Hysteria version 缺失或不是 1/2"
        if kernel == "xray" and version != 2:
            return "UNKNOWN", "Xray 内核仅实现 Hysteria v2，不支持 v1"
        detail = f"Hysteria v{version} 使用 TLS，需要证书"
        if sni:
            detail += f"；SNI={sni}"
        else:
            detail += "；面板未提供 SNI，后续需要手动填写证书域名"
        return "NEED_CERT", detail

    # TUIC / AnyTLS：后端 1.13 的入站构建均要求证书材料。
    if protocol in {"tuic", "anytls"}:
        detail = f"{protocol.upper()} 入站需要 TLS 证书"
        if sni:
            detail += f"；SNI={sni}"
        else:
            detail += "；面板未提供 SNI，后续需要手动填写证书域名"
        return "NEED_CERT", detail

    # Trojan：后端明确规定 TLS != 2 时必须有证书；没有显式 TLS 时也不能按 NO_CERT 处理。
    if protocol == "trojan":
        detail = "Trojan 非 REALITY 模式需要 TLS 证书"
        if sni:
            detail += f"；SNI={sni}"
        else:
            detail += "；面板未提供 SNI，后续需要手动填写证书域名"
        return "NEED_CERT", detail

    # VMess / VLESS：TLS 开关由面板 tls 字段决定。
    if protocol in {"vmess", "vless"}:
        if tls_num == 1:
            detail = f"{protocol.upper()} + TLS，需要证书"
            if sni:
                detail += f"；SNI={sni}"
            else:
                detail += "；面板未提供 SNI，后续需要手动填写证书域名"
            return "NEED_CERT", detail
        if tls_num == 0:
            return "NO_CERT", f"{protocol.upper()} 未启用 TLS"
        return "UNKNOWN", f"{protocol.upper()} 的 tls 值无法识别：{tls_raw!r}"

    # Naive 入站由后端按 tls=1 才挂载 TLS 配置。
    if protocol == "naive":
        if tls_num == 1:
            detail = "Naive 已启用 TLS，需要证书"
            if sni:
                detail += f"；SNI={sni}"
            else:
                detail += "；面板未提供 SNI，后续需要手动填写证书域名"
            return "NEED_CERT", detail
        if tls_num == 0:
            return "NO_CERT", "Naive 的面板 TLS 开关为关闭；按后端构建逻辑不挂载 TLS"
        return "UNKNOWN", f"Naive 的 tls 值无法识别：{tls_raw!r}"

    # SOCKS / HTTP：Sing-box 入站支持可选 TLS；Xray 在协议注册表中不支持这两个协议。
    if protocol in {"socks", "http"}:
        if tls_num == 0:
            return "NO_CERT", f"{protocol.upper()} 未启用 TLS"
        if tls_num == 1:
            detail = f"{protocol.upper()} + TLS，需要证书"
            if sni:
                detail += f"；SNI={sni}"
            else:
                detail += "；面板未提供 SNI，后续需要手动填写证书域名"
            return "NEED_CERT", detail
        return "UNKNOWN", f"{protocol.upper()} 的 tls 值无法识别：{tls_raw!r}"

    if protocol == "shadowsocks":
        return _ss_plugin_certificate_info(config)[:2]

    if protocol == "mieru":
        return "NO_CERT", "MIERU 原生传输不需要本地普通 TLS 证书"

    return "UNKNOWN", f"协议 {protocol} 尚无明确的证书判断规则"



def requires_local_cert(config, kernel):
    result, detail = decide_certificate(config, kernel)
    print(f"证书决策：{result}；{detail}")

    if result == "UNKNOWN":
        raise ValueError("无法安全判断证书需求：" + detail)

    sni = _get_sni(config)
    if result == "NO_CERT":
        return False, sni

    # 面板 cert_config 优先于本地 cert 配置，必须确认字段完整且域名匹配。
    panel_cert, panel_mode = _active_panel_cert(config, sni)
    if panel_cert:
        print(
            f"节点已包含字段完整的面板 cert_config（模式：{panel_mode}），"
            "后端将优先使用面板证书，跳过本地证书申请。"
        )
        if panel_mode in {"file", "content"} and sni:
            print(
                f"注意：面板 {panel_mode} 模式的证书内容/SAN 无法仅凭节点 API 字段完全核验；"
                f"请确认实际证书覆盖 SNI：{sni}"
            )
        return False, sni

    return True, sni



def _ask_cert_domain(prompt, default_domain=""):
    while True:
        domain = ask(prompt, default_domain or None)
        if not domain:
            raise ValueError("证书域名不能为空")
        if default_domain and not _domain_covers_sni(domain, default_domain):
            print(
                f"域名不匹配：证书域名 {domain} 无法覆盖节点 SNI {default_domain}。"
                "请填写与节点 SNI 一致的域名，或能覆盖该 SNI 的一级通配符域名。"
            )
            continue
        return domain

def make_cert(node_id, default_domain=""):
    # 优先复用该节点已有且匹配 SNI 的证书；无效/过期/不匹配时再进入申请流程。
    existing_dir = cert_dir / str(node_id)
    existing_cert = existing_dir / "fullchain.pem"
    existing_key = existing_dir / "privkey.pem"
    if existing_cert.is_file() and existing_key.is_file() and shutil.which("openssl"):
        import subprocess
        valid = subprocess.run(
            ["openssl", "x509", "-in", str(existing_cert), "-noout"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode == 0
        if valid:
            valid = subprocess.run(
                ["openssl", "pkey", "-in", str(existing_key), "-noout"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            ).returncode == 0
        if valid:
            cert_pub = subprocess.check_output(["openssl", "x509", "-in", str(existing_cert), "-pubkey", "-noout"])
            key_pub = subprocess.check_output(["openssl", "pkey", "-in", str(existing_key), "-pubout"])
            valid = cert_pub.strip() == key_pub.strip()
        if valid:
            valid = subprocess.run(
                ["openssl", "x509", "-in", str(existing_cert), "-checkend", "86400"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            ).returncode == 0
        if valid and default_domain:
            valid = subprocess.run(
                ["openssl", "x509", "-in", str(existing_cert), "-noout", "-checkhost", default_domain],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            ).returncode == 0
        if valid:
            print(f"检测到节点 {node_id} 已有有效证书，且与 SNI {default_domain or '(未指定)'} 匹配，自动复用。")
            return {
                "cert_mode": "file",
                "cert_file": f"/etc/xboard-node/certs/{node_id}/fullchain.pem",
                "key_file": f"/etc/xboard-node/certs/{node_id}/privkey.pem"
            }
        print("检测到已有证书，但证书/私钥、有效期或 SNI 校验未通过，需要重新配置。")

    print(f"\n--- 节点 ID {node_id} 的证书设置 ---")
    print("1. HTTP-01 自动申请")
    print("2. DNS-01 自动申请（Cloudflare / AliDNS）")
    print("3. 自签名证书")
    print("4. 使用已有证书文件")

    while True:
        mode = ask("请选择证书方式 [1]: ", "1")
        if mode in {"1", "2", "3", "4"}:
            break
        print("输入无效，请输入 1、2、3 或 4。")

    if mode == "1":
        domain = _ask_cert_domain(f"证书域名 [{default_domain or '必填'}]: ", default_domain)
        email = ask("证书通知邮箱（可留空）：", "")
        if not domain:
            raise ValueError("HTTP-01 必须填写域名")

        port = ask("HTTP 验证端口 [80]: ", "80")
        if not port.isdigit() or not (1 <= int(port) <= 65535):
            raise ValueError("HTTP 验证端口无效")

        cert = {
            "cert_mode": "http",
            "auto_tls": True,
            "domain": domain,
            "http_port": int(port)
        }
        if email:
            cert["email"] = email
        return cert

    if mode == "2":
        domain = _ask_cert_domain(f"证书域名 [{default_domain or '必填'}]: ", default_domain)
        email = ask("证书通知邮箱（可留空）：", "")

        print("DNS 服务商：1. Cloudflare  2. AliDNS")
        provider = ask("请选择 [1]: ", "1")

        if provider == "1":
            provider_name = "cloudflare"
            env = {
                "CLOUDFLARE_DNS_API_TOKEN": ask("Cloudflare API Token：")
            }
        elif provider == "2":
            provider_name = "alidns"
            env = {
                "ALICLOUD_ACCESS_KEY_ID": ask("AliDNS AccessKey ID："),
                "ALICLOUD_ACCESS_KEY_SECRET": ask("AliDNS AccessKey Secret：")
            }
        else:
            raise ValueError("不支持的 DNS 服务商")

        if not domain or any(not v for v in env.values()):
            raise ValueError("DNS-01 的域名和 API 凭据不能为空")

        cert = {
            "cert_mode": "dns",
            "auto_tls": True,
            "domain": domain,
            "dns_provider": provider_name,
            "dns_env": env
        }
        if email:
            cert["email"] = email
        return cert

    if mode == "3":
        domain = _ask_cert_domain(f"证书域名 [{default_domain or '必填'}]: ", default_domain)
        return {
            "cert_mode": "self",
            "domain": domain
        }

    if mode == "4":
        source_cert = ask("宿主机证书文件完整路径：")
        source_key = ask("宿主机私钥文件完整路径：")

        if not source_cert or not source_key:
            raise ValueError("证书和私钥路径不能为空")

        cert_src = pathlib.Path(source_cert)
        key_src = pathlib.Path(source_key)

        if not cert_src.is_file() or not key_src.is_file():
            raise ValueError("证书或私钥文件不存在")
        import subprocess
        if shutil.which("openssl"):
            cert_pub = subprocess.check_output(["openssl", "x509", "-in", str(cert_src), "-pubkey", "-noout"], stderr=subprocess.STDOUT)
            key_pub = subprocess.check_output(["openssl", "pkey", "-in", str(key_src), "-pubout"], stderr=subprocess.STDOUT)
            if cert_pub.strip() != key_pub.strip():
                raise ValueError("证书与私钥不匹配")
            if default_domain:
                check = subprocess.run(["openssl", "x509", "-in", str(cert_src), "-noout", "-checkhost", default_domain], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                if check.returncode != 0:
                    raise ValueError(f"证书 SAN/CN 不覆盖节点 SNI：{default_domain}")

        target = cert_dir / str(node_id)
        target.mkdir(parents=True, exist_ok=True)

        cert_target = target / "fullchain.pem"
        key_target = target / "privkey.pem"

        shutil.copy2(cert_src, cert_target)
        shutil.copy2(key_src, key_target)
        cert_target.chmod(0o644)
        key_target.chmod(0o600)

        return {
            "cert_mode": "file",
            "cert_file": f"/etc/xboard-node/certs/{node_id}/fullchain.pem",
            "key_file": f"/etc/xboard-node/certs/{node_id}/privkey.pem"
        }

    raise ValueError("无效的证书方式")

try:
    old_config = {}
    old_path = config_dir / "config.yml"
    if old_path.is_file():
        try:
            old_config = json.loads(old_path.read_text(encoding="utf-8"))
        except Exception:
            old_config = {}
    # 每次重新生成配置时，面板地址和 Token 均由用户重新输入。
    panel_url = ask("请输入面板地址：")
    if not panel_url or not panel_url.startswith(("http://", "https://")):
        raise ValueError("面板地址必须以 http:// 或 https:// 开头")

    panel_token = ask("请输入面板 Token：")
    if not panel_token:
        raise ValueError("Token 不能为空")

    # 节点数量默认 1，不再读取旧配置中的节点数量。
    count_text = ask("请输入节点数量 [1]: ", "1")
    if not count_text.isdigit() or not (1 <= int(count_text) <= 30):
        raise ValueError("节点数量必须为 1–30")
    count = int(count_text)

    node_ids = []
    nodes = []

    for i in range(count):
        while True:
            node_text = ask(f"请输入第 {i+1} 个节点 ID：")
            if not node_text.isdigit() or int(node_text) <= 0:
                print("节点 ID 必须为正整数。")
                continue

            node_id = int(node_text)
            if node_id in node_ids:
                print("节点 ID 不能重复。")
                continue
            break

        node_ids.append(node_id)

        node = {"node_id": node_id}
        print(f"\n正在从 Xboard 查询节点 {node_id} 配置……")
        node_config = get_node_config(panel_url, panel_token, node_id)
        need_cert, default_sni = requires_local_cert(node_config, kernel)

        if need_cert:
            cert = make_cert(node_id, default_sni)
        else:
            print(f"节点 {node_id} 已确认不需要本地普通 TLS 证书，跳过 ACME。")
            cert = None
        if cert:
            node["cert"] = cert
        nodes.append(node)

    data = {
        "panel": {
            "url": panel_url.rstrip("/"),
            "token": panel_token
        },
        "kernel": {
            "type": kernel,
            "config_dir": "/etc/xboard-node",
            "log_level": "warn"
        }
    }

    if custom_dns and kernel == "singbox":
        data["kernel"]["custom_config"] = "/etc/xboard-node/sing_origin.json"

    if count == 1:
        data["panel"]["node_id"] = node_ids[0]
        if nodes[0].get("cert"):
            data["cert"] = nodes[0]["cert"]
    else:
        data["nodes"] = nodes

    output = config_dir / "config.yml"

    # JSON 是 YAML 语法的合法子集；先写临时文件，完整成功后原子替换。
    import tempfile
    fd, tmp_name = tempfile.mkstemp(prefix="config.yml.", suffix=".tmp", dir=str(config_dir))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, output)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise

    print("\n配置生成成功：", output)
    print("节点 ID：", ", ".join(map(str, node_ids)))

except Exception as e:
    print(f"\n配置生成失败：{e}", file=sys.stderr)
    sys.exit(1)
PY
    then
        red "配置生成失败。"
        return 1
    fi

    chmod 600 "$PROJECT_DIR/config/config.yml"

    # Compose 是否挂载 sing_origin.json 与 config.yml 中 custom_config 保持一致。
    write_compose_file "$custom_dns"

    python3 -m json.tool "$PROJECT_DIR/config/config.yml" >/dev/null || {
        red "配置文件格式检查失败。"
        return 1
    }

    (
        cd "$PROJECT_DIR"
        docker compose config -q
    ) || {
        red "Compose 配置检查失败。"
        return 1
    }

    green "配置生成完成。"
    echo "配置文件：$PROJECT_DIR/config/config.yml"
}

# -------------------- 备份功能 --------------------

backup_all() {
    check_project || return 1

    local stamp archive
    stamp="$(date +%Y%m%d-%H%M%S-%N)"
    archive="$PROJECT_DIR/backup/xboard-node-backup-${stamp}.tar.gz"

    mkdir -p "$PROJECT_DIR/backup"

    local -a backup_items=(compose.yml config)
    [[ -f "$PROJECT_DIR/sing_origin.json" ]] && backup_items+=(sing_origin.json)
    tar -czf "$archive" -C "$PROJECT_DIR" "${backup_items[@]}"

    chmod 600 "$archive"

    green "备份完成："
    echo "$archive"
    echo
    echo "备份内容："
    echo "  compose.yml"
    echo "  config/（包括配置文件、证书及其他配置）"
    [[ -f "$PROJECT_DIR/sing_origin.json" ]] && echo "  sing_origin.json"
}

# -------------------- DNS 管理 --------------------

manage_custom_dns() {
    check_project || return 1
    require_python || return 1

    [[ -f "$PROJECT_DIR/config/config.yml" ]] || {
        red "请先完成配置生成。"
        return 1
    }

    local kernel
    kernel="$(python3 - "$PROJECT_DIR/config/config.yml" <<'PYK'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding="utf-8"))
    print(str(d.get("kernel",{}).get("type","")).lower())
except Exception:
    print("")
PYK
)"

    [[ "$kernel" == "singbox" ]] || {
        yellow "当前配置不是 Sing-box 内核，自定义 DNS 功能仅适用于 Sing-box。"
        return 1
    }

    generate_sing_origin || return 1

    python3 - "$PROJECT_DIR/config/config.yml" "$CUSTOM_DNS_ENABLED" <<'PYK'
import json,sys,os,tempfile

p,enabled=sys.argv[1],sys.argv[2]
d=json.load(open(p,encoding="utf-8"))
k=d.setdefault("kernel",{})

if enabled=="yes":
    k["custom_config"]="/etc/xboard-node/sing_origin.json"
else:
    k.pop("custom_config",None)

fd,tmp=tempfile.mkstemp(prefix=".config.yml.",dir=os.path.dirname(p))
try:
    with os.fdopen(fd,"w",encoding="utf-8") as f:
        json.dump(d,f,ensure_ascii=False,indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp,0o600)
    os.replace(tmp,p)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PYK

    write_compose_file "$CUSTOM_DNS_ENABLED"

    compose config -q || {
        red "Compose 校验失败；请检查配置及 DNS 挂载。"
        return 1
    }

    green "自定义 DNS 配置已同步。"

    local expected_dns_source actual_dns_mount container_exists

    expected_dns_source="$(realpath -m "$PROJECT_DIR/sing_origin.json")"
    actual_dns_mount=""
    container_exists="no"

    if docker inspect "$CONTAINER" >/dev/null 2>&1; then
        container_exists="yes"
        actual_dns_mount="$(docker inspect --format \
            '{{range .Mounts}}{{if eq .Destination "/etc/xboard-node/sing_origin.json"}}{{.Type}}|{{.Source}}{{end}}{{end}}' \
            "$CONTAINER" 2>/dev/null || true)"
    fi

    echo
    echo "========== Docker DNS 挂载状态 =========="
    echo "容器是否存在：$container_exists"
    echo "当前 DNS 挂载：${actual_dns_mount:-无}"
    echo "目标 DNS 文件：$expected_dns_source"
    echo

    if [[ "$CUSTOM_DNS_ENABLED" == "yes" ]]; then

        [[ -s "$PROJECT_DIR/sing_origin.json" ]] || {
            red "DNS 文件不存在或为空，停止操作。"
            return 1
        }

        if [[ "$actual_dns_mount" == "bind|$expected_dns_source" ]]; then
            blue "检测到容器已经挂载正确的 DNS 文件。"
            blue "执行普通重启……"

            compose restart "$SERVICE" || {
                red "DNS 文件已更新，但容器普通重启失败。"
                return 1
            }
        else
            yellow "容器 DNS 挂载与目标配置不一致。"
            yellow "执行强制重建，使 DNS 文件挂载生效……"

            compose up -d --force-recreate "$SERVICE" || {
                red "DNS 配置已更新，但容器强制重建失败。"
                return 1
            }
        fi

        sleep 2

        if ! docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then
            red "容器未正常运行，请检查：docker logs $CONTAINER"
            return 1
        fi

        actual_dns_mount="$(docker inspect --format \
            '{{range .Mounts}}{{if eq .Destination "/etc/xboard-node/sing_origin.json"}}{{.Type}}|{{.Source}}{{end}}{{end}}' \
            "$CONTAINER" 2>/dev/null || true)"

        if [[ "$actual_dns_mount" != "bind|$expected_dns_source" ]]; then
            red "容器 DNS 挂载验证失败。"
            red "实际挂载：${actual_dns_mount:-无}"
            return 1
        fi

        if ! docker exec "$CONTAINER" cat /etc/xboard-node/sing_origin.json | cmp -s "$PROJECT_DIR/sing_origin.json" -; then
            red "容器内 DNS 文件与宿主机不一致。"
            return 1
        fi

        green "DNS 配置更新成功！"
        green "容器运行正常，挂载正确，文件内容一致。"

        echo
        echo "当前 DNS 配置："
        cat "$PROJECT_DIR/sing_origin.json"

    else

        if [[ -n "$actual_dns_mount" ]]; then
            yellow "检测到容器仍挂载旧 DNS 文件。"
            yellow "执行强制重建，移除旧挂载……"

            compose up -d --force-recreate "$SERVICE" || {
                red "关闭 DNS 后容器重建失败。"
                return 1
            }

        elif [[ "$container_exists" == "yes" ]]; then
            blue "容器已经没有 DNS 文件挂载。"
            blue "执行普通重启……"

            compose restart "$SERVICE" || {
                red "容器普通重启失败。"
                return 1
            }

        else
            yellow "容器尚不存在，按关闭 DNS 的配置创建容器……"

            compose up -d "$SERVICE" || {
                red "容器创建失败。"
                return 1
            }
        fi

        sleep 2

        if ! docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then
            red "容器未正常运行，请检查：docker logs $CONTAINER"
            return 1
        fi

        actual_dns_mount="$(docker inspect --format \
            '{{range .Mounts}}{{if eq .Destination "/etc/xboard-node/sing_origin.json"}}{{.Type}}|{{.Source}}{{end}}{{end}}' \
            "$CONTAINER" 2>/dev/null || true)"

        if [[ -n "$actual_dns_mount" ]]; then
            red "DNS 已关闭，但容器仍存在 DNS 文件挂载！"
            red "实际挂载：$actual_dns_mount"
            return 1
        fi

        green "自定义 DNS 已关闭。"
        green "容器运行正常，旧 DNS 文件挂载已移除。"
    fi

    return 0
}

# -------------------- 高级功能 --------------------

show_version() {
    echo "脚本版本：Xboard-Node manager 20261117-certfix1"
    if command -v docker >/dev/null 2>&1; then
        local image_id
        image_id="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
        echo "当前容器镜像：${image_id:-未运行/未创建}"
        docker image inspect "$IMAGE" --format '本地镜像 ID：{{.Id}}' 2>/dev/null || true
    fi
}

restore_backup() {
    check_project || return 1
    local backup_dir="$PROJECT_DIR/backup"
    [[ -d "$backup_dir" ]] || { yellow "没有备份目录。"; return 1; }
    mapfile -t archives < <(find "$backup_dir" -maxdepth 1 -type f -name 'xboard-node-backup-*.tar.gz' -printf '%f\n' | sort -r)
    ((${#archives[@]})) || { yellow "没有找到完整备份包。"; return 1; }
    echo "可用备份："
    local i=1
    for f in "${archives[@]}"; do printf ' %2d. %s\n' "$i" "$f"; ((i+=1)); done
    read -r -p "选择备份编号 [0取消]： " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice>=1 && choice<=${#archives[@]})) || return 0
    local archive="$backup_dir/${archives[$((choice-1))]}"
    tar -tzf "$archive" >/dev/null || { red "备份包校验失败。"; return 1; }
    read -r -p "恢复将覆盖当前 compose/config/DNS 文件，输入 RESTORE 确认： " confirm
    [[ "$confirm" == "RESTORE" ]] || return 0
    backup_all || return 1
    local tmp
    tmp="$(mktemp -d "$PROJECT_DIR/.restore.XXXXXX")"
    if ! tar -xzf "$archive" -C "$tmp"; then rm -rf "$tmp"; red "解压失败。"; return 1; fi
    [[ -f "$tmp/compose.yml" && -d "$tmp/config" ]] || {
        rm -rf "$tmp"; red "备份内容缺少 compose.yml 或 config/。"; return 1;
    }
    cp -a "$tmp/compose.yml" "$PROJECT_DIR/compose.yml"
    rm -rf "$PROJECT_DIR/config"
    cp -a "$tmp/config" "$PROJECT_DIR/config"
    if [[ -f "$tmp/sing_origin.json" ]]; then cp -a "$tmp/sing_origin.json" "$PROJECT_DIR/sing_origin.json"; else rm -f "$PROJECT_DIR/sing_origin.json"; fi
    rm -rf "$tmp"
    compose config -q || { red "恢复文件已写入，但 Compose 校验失败，请检查配置。"; return 1; }
    green "备份恢复完成。"
    read -r -p "是否立即重建容器？[y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] && compose up -d --force-recreate "$SERVICE"
}

certificate_status_check() {
    check_project || return 1
    local cfg="$PROJECT_DIR/config/config.yml"
    [[ -f "$cfg" ]] || { yellow "尚未生成配置。"; return 1; }
    python3 - "$cfg" "$PROJECT_DIR/config/certs" <<'PYCERT'
import json,sys,pathlib,subprocess
cfg=json.load(open(sys.argv[1],encoding="utf-8"))
root=pathlib.Path(sys.argv[2])
print("内核：",cfg.get("kernel",{}).get("type","未知"))
panel=cfg.get("panel",{})
nodes=cfg.get("nodes") or [{"node_id":panel.get("node_id"),"cert":cfg.get("cert")}]
for n in nodes:
    nid=n.get("node_id","未知")
    cert=n.get("cert")
    print(f"\n节点 {nid}:")
    if not cert:
        print("  配置中没有本地证书条目（需结合面板协议判断是否正常）")
        continue
    mode=cert.get("cert_mode","")
    print("  证书模式：",mode)
    if mode=="file":
        cf=cert.get("cert_file","").replace("/etc/xboard-node/certs/",str(root)+"/")
        kf=cert.get("key_file","").replace("/etc/xboard-node/certs/",str(root)+"/")
        cp,kp=pathlib.Path(cf),pathlib.Path(kf)
        print("  证书文件：",cp, "存在" if cp.is_file() else "缺失")
        print("  私钥文件：",kp, "存在" if kp.is_file() else "缺失")
        if cp.is_file() and kp.is_file() and subprocess.run(["openssl","x509","-in",str(cp),"-noout"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
            print("  证书格式：有效")
        else: print("  证书格式：无法验证")
    elif mode in ("http","dns"):
        print("  自动 TLS 域名：",cert.get("domain","未配置"))
        print("  自动申请模式：",mode)
    else:
        print("  证书域名：",cert.get("domain","未配置"))
PYCERT
    echo
    yellow "说明：此项检查本地配置和证书文件；要重新判定面板当前协议，请重新生成配置并从 Xboard 拉取最新节点数据。"
}

advanced_menu() {
    while true; do
        echo
        blue "================ Xboard-Node 高级功能 ================"
        echo "1. 版本与升级管理"
        echo "2. 备份与恢复管理"
        echo "3. 协议 / TLS / 证书检查"
        echo "0. 返回主菜单"
        echo
        read -r -p "请选择 [0-3]： " choice
        case "$choice" in
            1) show_version; update_image ;;
            2)
                echo "1. 创建完整备份"
                echo "2. 从备份恢复"
                echo "0. 返回"
                read -r -p "请选择 [0-2]： " sub
                case "$sub" in 1) backup_all ;; 2) restore_backup ;; 0) ;; *) red "无效选择。" ;; esac
                ;;
            3) certificate_status_check ;;
            0) return 0 ;;
            *) red "无效选择。" ;;
        esac
        pause
    done
}

# -------------------- Docker 管理功能 --------------------

start_node() {
    check_project || return 1
    require_docker || return 1

    if [[ ! -f "$PROJECT_DIR/config/config.yml" ]]; then
        red "尚未生成 config/config.yml，请先选择菜单 1 完成安装和配置。"
        return 1
    fi

    compose up -d
}

stop_node() {
    check_project || return 1
    require_docker || return 1
    compose stop
}

restart_node() {
    check_project || return 1
    require_docker || return 1
    compose restart
}

status_node() {
    check_project || return 1
    require_docker || return 1

    echo
    compose ps

    echo
    docker ps -a --filter "name=^/${CONTAINER}$"
}

logs_node() {
    check_project || return 1
    require_docker || return 1

    echo "按 Ctrl+C 退出日志。"
    compose logs -f --tail=200 "$SERVICE"
}

update_image() {
    check_project || return 1
    require_docker || return 1

    echo
    yellow "即将拉取最新镜像：$IMAGE"
    read -r -p "确认更新？[y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    backup_all || return 1

    compose pull "$SERVICE" &&
    compose up -d --force-recreate "$SERVICE"
}

recreate_node() {
    check_project || return 1
    require_docker || return 1
    [[ -f "$PROJECT_DIR/config/config.yml" ]] || {
        red "未找到 config/config.yml，请先生成配置。"
        return 1
    }

    echo
    yellow "重新创建容器不会删除宿主机的 config、证书和 DNS 文件。"
    read -r -p "确认重新创建容器？[y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    compose config -q || return 1
    compose up -d --force-recreate "$SERVICE"
}

edit_config() {
    check_project || return 1
    [[ -f "$PROJECT_DIR/config/config.yml" ]] || {
        red "配置文件不存在，请先生成配置。"
        return 1
    }
    backup_file "$PROJECT_DIR/config/config.yml" || return 1

    local editor="${EDITOR:-nano}"
    command -v "$editor" >/dev/null 2>&1 || editor="vi"

    "$editor" "$PROJECT_DIR/config/config.yml"
    chmod 600 "$PROJECT_DIR/config/config.yml"
    if ! python3 -m json.tool "$PROJECT_DIR/config/config.yml" >/dev/null; then
        red "配置文件格式检查失败。原文件备份已保留，请修复配置格式。"
        return 1
    fi
    green "配置文件格式检查通过。"
}

show_config() {
    check_project || return 1
    [[ -f "$PROJECT_DIR/config/config.yml" ]] || {
        red "配置文件不存在。"
        return 1
    }

    yellow "配置文件包含面板 Token 和可能的 DNS API 凭据。"
    read -r -p "确认查看明文配置？[y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    cat "$PROJECT_DIR/config/config.yml"

    if [[ -f "$PROJECT_DIR/sing_origin.json" ]]; then
        echo
        echo "========== sing_origin.json =========="
        cat "$PROJECT_DIR/sing_origin.json"
    fi
}

regenerate_config() {
    generate_config || return 1

    echo
    read -r -p "配置已重新生成，是否立即重建容器使配置生效？[y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        compose up -d --force-recreate "$SERVICE"
    fi
}

check_compose_mounts() {
    check_project || return 1

    if ! grep -Fq './config:/etc/xboard-node' "$PROJECT_DIR/compose.yml"; then
        red "缺少 config 目录挂载。"
        return 1
    fi

    local has_dns_mount="no" has_custom_config="no"
    grep -Fq './sing_origin.json:/etc/xboard-node/sing_origin.json:ro' "$PROJECT_DIR/compose.yml" && has_dns_mount="yes"
    grep -Fq '"custom_config": "/etc/xboard-node/sing_origin.json"' "$PROJECT_DIR/config/config.yml" && has_custom_config="yes"

    if [[ "$has_dns_mount" != "$has_custom_config" ]]; then
        red "检测到 DNS 文件挂载与 config.yml 的 custom_config 不一致。"
        return 1
    fi
    if [[ "$has_dns_mount" == "yes" && ! -f "$PROJECT_DIR/sing_origin.json" ]]; then
        red "Compose 已挂载 sing_origin.json，但宿主机文件不存在。"
        return 1
    fi

    compose config -q || return 1
    green "Compose 配置及挂载检查通过。"
    if [[ "$has_dns_mount" == "yes" ]]; then
        echo "自定义 DNS：已启用"
    else
        echo "自定义 DNS：未启用"
    fi
    echo
    grep -n -A5 'volumes:' "$PROJECT_DIR/compose.yml"
}

# -------------------- 卸载功能 --------------------

remove_container_only() {
    echo
    yellow "此操作只删除 Docker 容器，不删除配置和项目文件。"
    read -r -p "确认停止并移除容器？[y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    if [[ -f "$PROJECT_DIR/compose.yml" ]]; then
        compose down
    else
        docker rm -f "$CONTAINER" 2>/dev/null || true
    fi

    green "容器已移除，项目文件和管理命令保留。"
}

full_uninstall() {
    echo
    red "========== 完整卸载 =========="
    echo "将执行：先备份项目配置到项目目录之外，再移除容器和管理命令。"
    echo "不会删除 Docker 数据卷，也不会自动删除镜像。"
    echo
    local archive="" parent_dir
    parent_dir="$(dirname "$PROJECT_DIR")"
    if [[ -d "$PROJECT_DIR" ]]; then
        mkdir -p "$parent_dir"
        archive="$parent_dir/xboard-node-backup-$(date +%Y%m%d-%H%M%S-%N).tar.gz"
        local -a backup_items=(compose.yml config)
        [[ -f "$PROJECT_DIR/sing_origin.json" ]] && backup_items+=(sing_origin.json)
        if ! tar -czf "$archive" -C "$PROJECT_DIR" "${backup_items[@]}"; then
            rm -f -- "$archive"
            red "备份失败，已中止卸载；项目和容器均未处理。"
            return 1
        fi
        if ! tar -tzf "$archive" >/dev/null; then
            rm -f -- "$archive"
            red "备份包校验失败，已中止卸载。"
            return 1
        fi
        chmod 600 "$archive"
        green "配置备份已保存并校验：$archive"
    else
        yellow "项目目录不存在，将尝试移除同名容器。"
    fi

    require_docker || return 1
    if [[ -f "$PROJECT_DIR/compose.yml" ]]; then
        if ! compose down; then
            red "容器移除失败，已保留管理命令和项目目录。"
            return 1
        fi
    else
        docker rm -f "$CONTAINER" 2>/dev/null || true
    fi

    echo
    read -r -p "是否删除整个项目目录 $PROJECT_DIR？[y/N，默认保留]： " delete_confirm
    if [[ "$delete_confirm" =~ ^[Yy]$ ]]; then
        case "$PROJECT_DIR" in
            /root/xboard-node|/opt/xboard-node|/home/*/xboard-node)
                if [[ -d "$PROJECT_DIR" && ! -L "$PROJECT_DIR" ]]; then
                    rm -rf -- "$PROJECT_DIR"
                    green "项目目录已删除。"
                else
                    yellow "项目目录不存在或是符号链接，未执行目录删除。"
                fi
                ;;
            *) red "项目目录不在允许自动删除的路径范围内，已保留：$PROJECT_DIR" ;;
        esac
    else
        yellow "未输入 Y，项目目录保留：$PROJECT_DIR"
    fi

    rm -f -- "$MANAGER_BIN" "$MANAGER_CONFIG"
    green "全局管理命令已卸载。"
    echo "Docker 容器已移除。"
    [[ -n "$archive" ]] && echo "备份文件：$archive"
    echo
    yellow "注意：Docker 镜像没有自动删除。"
    echo "如需释放镜像空间，可自行执行：docker image rm $IMAGE"
}

uninstall_menu() {
    echo
    blue "========== 卸载选项 =========="
    echo "1. 仅停止并移除容器（保留所有文件和管理命令）"
    echo "2. 完整卸载（先备份，再移除容器和管理命令）"
    echo "0. 返回"
    echo

    read -r -p "请选择 [0-2]： " choice

    case "$choice" in
        1) remove_container_only ;;
        2) full_uninstall ;;
        0) return 0 ;;
        *) red "无效选择。" ;;
    esac
}

# -------------------- 管理菜单 --------------------

show_menu() {
    clear 2>/dev/null || true
    echo
    blue "=================================================="
    blue "             Xboard-Node 节点管理面板2.0"
    blue "=================================================="
    echo "项目目录：$PROJECT_DIR"
    echo "配置文件：$PROJECT_DIR/config/config.yml"
    echo "备份目录：$PROJECT_DIR/backup"
    if [[ -f "$PROJECT_DIR/config/config.yml" ]]; then green "安装状态：已配置"; else yellow "安装状态：未配置"; fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
        green "服务状态：运行中"
    else
        yellow "服务状态：未运行"
    fi
    echo
    echo " 1. 安装 Xboard-Node"
    echo " 2. 启动节点"
    echo " 3. 停止节点"
    echo " 4. 重启节点"
    echo " 5. 查看运行状态"
    echo " 6. 查看实时日志"
    echo " 7. 查看 config.yml"
    echo " 8. 编辑 config.yml"
    echo " 9. 自定义 DNS 解锁 IP"
    echo "10. 高级功能"
    echo "11. 卸载 Xboard-Node"
    echo " 0. 退出"
    echo
}

main_menu() {
    require_root
    load_manager_config
    while true; do
        show_menu
        read -r -p "请输入操作编号 [0-11]： " choice
        case "$choice" in
            1)
                if install_project; then
                    if [[ ! -f "$PROJECT_DIR/config/config.yml" ]]; then
                        generate_config || red "配置生成未完成。"
                    else
                        yellow "检测到已有 config.yml，为避免覆盖，保留原配置。"
                        read -r -p "是否重新生成配置？[Y/n]: " regen
                        if [[ ! "$regen" =~ ^[Nn]$ ]]; then
                            generate_config || red "配置生成未完成。"
                        else
                            CONFIG_BACKUP_DONE="no"
                            yellow "已保留原配置，本次备份状态已清除。"
                        fi
                    fi
                else red "项目初始化失败，请检查上方提示。"; fi
                pause ;;
            2) start_node || red "启动失败。"; pause ;;
            3) stop_node || red "停止失败。"; pause ;;
            4) restart_node || red "重启失败。"; pause ;;
            5) status_node || red "状态查询失败。"; pause ;;
            6) logs_node || red "日志查看结束或失败。"; pause ;;
            7) show_config || red "查看配置失败。"; pause ;;
            8) edit_config || red "编辑或校验配置失败。"; pause ;;
            9) manage_custom_dns || red "自定义 DNS 操作失败。"; pause ;;
            10) advanced_menu ;;
            11)
                uninstall_menu
                [[ ! -f "$MANAGER_CONFIG" ]] && exit 0
                pause ;;
            0) exit 0 ;;
            *) red "无效选项。"; pause ;;
        esac
    done
}

# -------------------- 入口 --------------------

require_root

check_dependencies || exit 1

case "${1:-menu}" in
    install)
        install_project || exit 1

        if [[ ! -f "$PROJECT_DIR/config/config.yml" ]]; then
            generate_config || exit 1
        else
            yellow "检测到已有配置，默认不覆盖。"
            read -r -p "是否重新生成配置？[Y/n]: " regen
            if [[ ! "$regen" =~ ^[Nn]$ ]]; then
                generate_config || exit 1
            else
                CONFIG_BACKUP_DONE="no"
                yellow "已保留原配置，本次备份状态已清除。"
            fi
        fi

        echo
        read -r -p "是否立即启动 Xboard-Node？[y/N]: " start_confirm

        if [[ "$start_confirm" =~ ^[Yy]$ ]]; then
            start_node
        fi
        ;;

    menu)
        main_menu
        ;;

    *)
        echo "用法："
        echo "  bash xboard-node.sh          打开管理菜单"
        echo "  bash xboard-node.sh install  安装 / 初始化项目"
        exit 1
        ;;
esac
