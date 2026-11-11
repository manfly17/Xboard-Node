
#!/usr/bin/env bash
# Xboard-Node 安装与管理脚本
# 安装后使用：xboardnode
# 适用：Debian 11/12、Ubuntu
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
MANAGER_BIN="/usr/local/bin/xboardnode"
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
    green "以后输入 xboardnode 即可打开管理菜单。"
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

    # 备份旧文件
    backup_file "$PROJECT_DIR/compose.yml"
    backup_file "$PROJECT_DIR/config/config.yml"
    backup_file "$PROJECT_DIR/sing_origin.json"

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
    local answer dns_ip

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

    read -r -p "请输入 DNS IP [1.1.1.1]: " dns_ip
    dns_ip="${dns_ip:-1.1.1.1}"
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
directory = os.path.dirname(path)
fd, temp_path = tempfile.mkstemp(prefix="sing_origin.", suffix=".tmp", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temp_path, 0o644)
    os.replace(temp_path, path)
except Exception:
    try:
        os.unlink(temp_path)
    except OSError:
        pass
    raise
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

    backup_file "$PROJECT_DIR/config/config.yml"

    echo
    blue "========== Xboard-Node 配置生成 =========="

    echo "请选择内核："
    echo "1. Sing-box（推荐，支持 HY2、TUIC、AnyTLS 等）"
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


def requires_local_cert(config):
    """判断协议是否需要普通 TLS 证书。未知情况一律停止。"""
    protocol = str(config.get("protocol", "")).lower()
    tls = config.get("tls")

    print(f"检测到协议：{protocol}")

    if protocol == "vless":
        if tls == 2:
            print("检测结果：VLESS Reality，不需要普通 TLS 证书。")
            return False
        if tls == 1:
            print("检测结果：VLESS 普通 TLS，需要证书配置。")
            return True
        if tls == 0:
            print("检测结果：VLESS 未启用 TLS，不需要证书。")
            return False
        raise ValueError("VLESS 的 tls 值无法识别，停止自动判断")

    if protocol == "vmess":
        if tls == 1:
            print("检测结果：VMess TLS，需要证书配置。")
            return True
        if tls == 0:
            print("检测结果：VMess 未启用 TLS，不需要证书。")
            return False
        raise ValueError("VMess 的 tls 值无法识别，停止自动判断")

    if protocol == "trojan":
        if tls == 1:
            print("检测结果：Trojan 普通 TLS，需要证书配置。")
            return True
        if tls == 0:
            print("检测结果：Trojan 未启用 TLS，不需要证书。")
            return False
        if tls == 2:
            print("检测结果：Trojan Reality，不需要普通 TLS 证书。")
            return False
        raise ValueError("Trojan 的 tls 值无法识别，停止自动判断")

    if protocol in ("hysteria", "hysteria2"):
        if config.get("version") not in (1, 2):
            raise ValueError("Hysteria 版本缺失或无法识别")
        if not isinstance(config.get("tls_settings"), dict):
            raise ValueError("Hysteria 未返回有效 tls_settings")
        print("检测结果：Hysteria TLS，需要证书配置。")
        return True

    if protocol in ("tuic", "anytls"):
        if not isinstance(config.get("tls_settings"), dict):
            raise ValueError(f"{protocol} 未返回有效 tls_settings")
        print(f"检测结果：{protocol} 使用 TLS，需要证书配置。")
        return True

    if protocol in ("shadowsocks", "mieru"):
        print(f"检测结果：{protocol} 不需要普通 TLS 证书。")
        return False

    raise ValueError(
        f"协议 {protocol} 暂未设置自动判断规则，请勿自动跳过证书配置"
    )


def make_cert(node_id):
    print(f"\n--- 节点 ID {node_id} 的证书设置 ---")
    print("0. 不在本地配置证书")
    print("1. HTTP-01 自动申请")
    print("2. DNS-01 自动申请（Cloudflare / AliDNS）")
    print("3. 自签名证书")
    print("4. 使用已有证书文件")

    mode = ask("请选择证书方式 [0]: ", "0")

    if mode == "0":
        return None

    if mode == "1":
        domain = ask("证书域名：")
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
        domain = ask("证书域名：")
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
        domain = ask("证书域名：")
        if not domain:
            raise ValueError("自签名证书必须填写域名")
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
    panel_url = ask("面板地址：")
    if not panel_url or not panel_url.startswith(("http://", "https://")):
        raise ValueError("面板地址必须以 http:// 或 https:// 开头")

    panel_token = ask("请输入面板 Token：")
    if not panel_token:
        raise ValueError("Token 不能为空")

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
        need_cert = requires_local_cert(node_config)

        if need_cert:
            cert = make_cert(node_id)
        else:
            print(f"节点 {node_id} 自动跳过普通 TLS 证书设置。")
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

    # JSON 是 YAML 语法的合法子集
    with output.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")

    output.chmod(0o600)

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

# -------------------- Docker 管理功能 --------------------

start_node() {
    check_project || return 1
    require_docker || return 1

    if [[ ! -f "$PROJECT_DIR/config/config.yml" ]]; then
        red "尚未生成 config/config.yml，请先选择菜单 7。"
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
    read -r -p "确认继续完整卸载？请输入 YES： " confirm
    [[ "$confirm" == "YES" ]] || {
        yellow "已取消卸载。"
        return 0
    }

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
    read -r -p "是否删除整个项目目录 $PROJECT_DIR？请输入 DELETE 确认，否则保留： " delete_confirm
    if [[ "$delete_confirm" == "DELETE" ]]; then
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
        yellow "项目目录已保留：$PROJECT_DIR"
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
    blue "=============================================="
    blue "             Xboard-Node 管理面板"
    blue "=============================================="
    echo
    echo "项目目录：$PROJECT_DIR"

    if [[ -f "$PROJECT_DIR/config/config.yml" ]]; then
        green "配置状态：已生成"
    else
        yellow "配置状态：尚未生成"
    fi

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
        green "运行状态：运行中"
    else
        yellow "运行状态：未运行"
    fi

    echo
    echo "  1. 安装 / 初始化项目"
    echo "  2. 启动节点"
    echo "  3. 停止节点"
    echo "  4. 重启节点"
    echo "  5. 查看运行状态"
    echo "  6. 查看实时日志"
    echo "  7. 重新生成配置"
    echo "  8. 编辑配置文件"
    echo "  9. 查看配置文件"
    echo " 10. 备份配置文件"
    echo " 11. 更新 Docker 镜像"
    echo " 12. 重新创建容器"
    echo " 13. 检查 Compose 挂载"
    echo " 14. 卸载 Xboard-Node"
    echo "  0. 退出"
    echo
}

main_menu() {
    require_root
    load_manager_config

    while true; do
        show_menu
        read -r -p "请输入操作编号 [0-14]： " choice

        case "$choice" in
            1)
                if install_project; then
                    if [[ ! -f "$PROJECT_DIR/config/config.yml" ]]; then
                        generate_config || red "配置生成未完成。"
                    else
                        yellow "检测到已有 config.yml，为避免覆盖，保留原配置。"
                        read -r -p "是否重新生成配置？[y/N]: " regen
                        if [[ "$regen" =~ ^[Yy]$ ]]; then generate_config || red "配置生成失败。"; fi
                    fi
                else
                    red "项目初始化失败，请检查上方提示。"
                fi
                pause
                ;;
            2) start_node || red "启动失败。"; pause ;;
            3) stop_node || red "停止失败。"; pause ;;
            4) restart_node || red "重启失败。"; pause ;;
            5) status_node || red "状态查询失败。"; pause ;;
            6) logs_node || red "日志查看结束或失败。"; pause ;;
            7) regenerate_config || red "重新生成配置失败。"; pause ;;
            8) edit_config || red "编辑或校验配置失败。"; pause ;;
            9) show_config || red "查看配置失败。"; pause ;;
            10) backup_all || red "备份失败。"; pause ;;
            11) update_image || red "更新镜像失败。"; pause ;;
            12) recreate_node || red "重新创建容器失败。"; pause ;;
            13) check_compose_mounts || red "挂载检查失败。"; pause ;;
            14)
                uninstall_menu
                if [[ ! -f "$MANAGER_CONFIG" ]]; then
                    exit 0
                fi
                pause
                ;;
            0) exit 0 ;;
            *) red "无效选项。"; pause ;;
        esac
    done
}

# -------------------- 入口 --------------------

require_root

case "${1:-menu}" in
    install)
        install_project || exit 1

        if [[ ! -f "$PROJECT_DIR/config/config.yml" ]]; then
            generate_config || exit 1
        else
            yellow "检测到已有配置，默认不覆盖。"
            read -r -p "是否重新生成配置？[y/N]: " regen
            if [[ "$regen" =~ ^[Yy]$ ]]; then generate_config || exit 1; fi
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
