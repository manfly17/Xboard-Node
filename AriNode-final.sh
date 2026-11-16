#!/usr/bin/env bash
# AriNode 安装与管理脚本（优化版）
# Script revision: 2026-11-16
# 安装后管理命令：ari-node
# 适用：Debian / Ubuntu（systemd，Linux amd64 / arm64）
# AriNode 本身采用官方原生二进制 + systemd，不依赖 Docker。

set -Eeuo pipefail
umask 077

REPO="Foxtea267/AriNode"
RELEASE_DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download"
RELEASE_URL="https://github.com/${REPO}/releases/latest"
SERVICE="arinode.service"
CONFIG="/etc/arinode/config.json"
CONFIG_DIR="/etc/arinode"
BIN_DIR="/usr/local/bin"
ARINODE_BIN="${BIN_DIR}/arinode"
ANCTL_BIN="${BIN_DIR}/anctl"
MANAGER_BIN="${BIN_DIR}/ari-node"
LEGACY_MANAGER_BIN="${BIN_DIR}/airnode"
MANAGER_CONFIG="/etc/arinode-manager.conf"
BACKUP_DIR="/root/arinode-backups"
DNS_CONFIG="${CONFIG_DIR}/sing_origin.json"
DNS_META="${CONFIG_DIR}/.arinode-dns-manager.json"
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || realpath "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"

# -------------------- 基础函数 --------------------
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
blue()   { printf '\033[36m%s\033[0m\n' "$*"; }
pause()  { echo; read -e -r -p "按回车键继续..." _ || true; }

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        red "请使用 root 用户运行：sudo bash AriNode.sh"
        return 1
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        red "缺少命令：$1"
        return 1
    }
}

check_platform() {
    [[ $(uname -s) == Linux ]] || { red "AriNode 管理脚本仅支持 Linux。"; return 1; }
    command -v systemctl >/dev/null 2>&1 || { red "未检测到 systemd/systemctl。"; return 1; }
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *) red "暂不支持当前架构：$(uname -m)"; return 1 ;;
    esac
}

load_manager_config() {
    if [[ -f "$MANAGER_CONFIG" ]]; then
        # 兼容旧版管理器配置，但备份目录固定在 /root 下。
        # shellcheck disable=SC1090
        source "$MANAGER_CONFIG"
    fi
    BACKUP_DIR="/root/arinode-backups"
DNS_CONFIG="${CONFIG_DIR}/sing_origin.json"
DNS_META="${CONFIG_DIR}/.arinode-dns-manager.json"
}

save_manager_config() {
    local tmp="${MANAGER_CONFIG}.tmp.$$"
    printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR" > "$tmp"
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$MANAGER_CONFIG"
}

is_installed() {
    [[ -x "$ARINODE_BIN" && -x "$ANCTL_BIN" && -f "/etc/systemd/system/${SERVICE}" ]]
}

require_arinode() {
    if [[ ! -x "$ANCTL_BIN" ]]; then
        red "尚未安装 AriNode，请先选择菜单 1。"
        return 1
    fi
}

confirm_yes() {
    local prompt="$1" answer
    read -e -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# -------------------- 管理命令安装 --------------------
install_manager_command() {
    local source_path="$SELF_PATH"
    if [[ "$source_path" == "$MANAGER_BIN" ]]; then
        chmod 755 "$MANAGER_BIN"
    elif [[ -f "$source_path" && ! -L "$source_path" ]]; then
        install -D -m 755 "$source_path" "$MANAGER_BIN"
    else
        red "无法从当前执行方式复制管理脚本。请先将 AriNode.sh 保存到本地，再执行：bash AriNode.sh"
        return 1
    fi
    save_manager_config
    # 仅清理旧版本脚本创建的 airnode 别名，避免误删其他同名程序。
    if [[ -f "$LEGACY_MANAGER_BIN" ]] && grep -q 'AriNode 安装与管理脚本' "$LEGACY_MANAGER_BIN"; then
        rm -f -- "$LEGACY_MANAGER_BIN"
    fi
    green "管理命令安装成功，以后输入 ari-node 即可打开自定义菜单；官方 arinode 命令保持不变。"
}

# -------------------- Xboard 协议 / TLS / 证书配置 --------------------
# 依据 Xboard 普通节点 UniProxy v1 返回的实际 TLS/REALITY 字段识别证书需求；
# 仅处理 AriNode 支持的服务端入站协议，不把 Xboard 订阅/其他入站类型误认为 AriNode 支持。
configure_tls_certificates() {
    local config_file="$1" panel_url="${2:-}" mode="${3:-initial}"
    ARINODE_PANEL_TOKEN="${ARINODE_PANEL_TOKEN:-}" python3 - "$config_file" "$panel_url" "$mode" <<'PY_TLS_SETUP'
import copy, getpass, ipaddress, json, os, pathlib, re, shutil, socket, ssl, subprocess, sys, tempfile, urllib.error, urllib.parse, urllib.request

config_path = pathlib.Path(sys.argv[1])
panel_url = (sys.argv[2] or '').rstrip('/')
run_mode = sys.argv[3]
env_token = os.environ.get('ARINODE_PANEL_TOKEN', '')
cert_root = pathlib.Path('/etc/arinode/certs')


def ask(prompt, default=None):
    # Python 程序通过 Bash heredoc 传入，STDIN 已被 Python 源码占用。
    # 所有交互输入必须从真实终端 /dev/tty 读取。
    try:
        with open('/dev/tty', 'r', encoding='utf-8', buffering=1) as tty:
            sys.stdout.write(prompt)
            sys.stdout.flush()
            value = tty.readline()
    except OSError as exc:
        raise RuntimeError(f'无法打开终端读取输入：{exc}')

    if value == '':
        raise RuntimeError('终端输入已结束，无法读取用户选择')

    value = value.strip()
    return value if value else default


def truthy(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    return str(value or '').strip().lower() in ('1', 'true', 'yes', 'on')


def unwrap(obj):
    if isinstance(obj, dict) and isinstance(obj.get('data'), dict):
        return obj['data']
    return obj


def fetch_node_config(base, token, node_id, node_type):
    # 普通服务器 Token 必须使用 UniProxy v1，并携带 node_type；机器模式 v2 不在本脚本支持范围。
    query = urllib.parse.urlencode({'token': token, 'node_id': str(node_id), 'node_type': node_type})
    url = base.rstrip('/') + '/api/v1/server/UniProxy/config?' + query
    req = urllib.request.Request(url, headers={'Accept': 'application/json', 'User-Agent': 'AriNode-Manager/2.1'})
    try:
        with urllib.request.urlopen(req, timeout=25) as response:
            raw = response.read(4 * 1024 * 1024 + 1)
        if len(raw) > 4 * 1024 * 1024:
            raise RuntimeError('Xboard 节点配置响应超过 4 MiB')
        obj = json.loads(raw.decode('utf-8'))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'Xboard UniProxy API 返回 HTTP {e.code}')
    except urllib.error.URLError as e:
        raise RuntimeError(f'无法连接 Xboard UniProxy API：{e.reason}')
    except Exception as e:
        raise RuntimeError(f'读取 Xboard 节点配置失败：{e}')
    data = unwrap(obj)
    if not isinstance(data, dict):
        raise RuntimeError('Xboard UniProxy API 返回内容不是 JSON 对象')
    if str(data.get('status', '')).lower() == 'fail':
        raise RuntimeError('Xboard 拒绝读取节点配置：' + str(data.get('message', '未知原因')))
    # 至少应包含一个协议参数；空对象不作为“无 TLS”处理。
    known = {'tls', 'tls_settings', 'tlsSettings', 'reality_settings', 'realitySettings', 'protocol_settings', 'protocolSettings', 'version', 'server_name', 'cert_config', 'network', 'cipher', 'transport', 'up_mbps', 'down_mbps', 'host', 'server_port', 'routes', 'base_config', 'congestion_control', 'zero_rtt_handshake', 'padding_scheme'}
    if not any(k in data for k in known):
        raise RuntimeError('Xboard 返回的节点配置缺少 TLS/协议字段，拒绝猜测')
    return data


def panel_binding(cfg, node):
    base = node.get('ApiHost') or node.get('APIHost') or panel_url
    token = node.get('ApiKey') or node.get('APIKey') or env_token
    node_env = node.get('ApiKeyEnv') or node.get('TokenEnv')
    if not node.get('ApiKey') and not node.get('APIKey') and node_env:
        token = os.environ.get(node_env, token)
    if node.get('Panel'):
        for panel in cfg.get('Panels', []):
            if panel.get('Name') == node['Panel']:
                base = panel.get('ApiHost') or panel.get('URL') or base
                token = panel.get('ApiKey') or panel.get('Token') or token
                env_name = panel.get('ApiKeyEnv') or panel.get('TokenEnv')
                if not panel.get('ApiKey') and not panel.get('Token') and env_name:
                    token = os.environ.get(env_name, token)
                break
    return (base or '').rstrip('/'), token or ''


def tls_info(node, data):
    # Xboard 不同分支/版本可能把协议字段放在顶层，也可能放在 protocol_settings 中。
    settings = data.get('protocol_settings') or data.get('protocolSettings') or data
    if not isinstance(settings, dict):
        settings = data
    protocol = str(node.get('NodeType') or data.get('protocol') or data.get('node_type') or '').strip().lower()
    protocol = {'ss': 'shadowsocks', 'hy2': 'hysteria', 'hysteria2': 'hysteria', 'v2ray': 'vmess'}.get(protocol, protocol)

    tls_value = settings.get('tls', data.get('tls'))
    tls_obj = tls_value if isinstance(tls_value, dict) else {}
    tls_settings = settings.get('tls_settings') or settings.get('tlsSettings') or data.get('tls_settings') or data.get('tlsSettings') or {}
    reality_settings = settings.get('reality_settings') or settings.get('realitySettings') or data.get('reality_settings') or data.get('realitySettings') or {}
    if not isinstance(tls_settings, dict):
        tls_settings = {}
    if not isinstance(reality_settings, dict):
        reality_settings = {}

    raw_mode = tls_value
    if isinstance(tls_value, dict):
        raw_mode = tls_value.get('mode') or tls_value.get('type')
        if raw_mode is None and 'enabled' in tls_value:
            raw_mode = 1 if truthy(tls_value.get('enabled')) else 0
        elif raw_mode is None and tls_value:
            raw_mode = 1
    if raw_mode is None and tls_settings:
        raw_mode = 1
    if isinstance(raw_mode, str):
        raw_mode = raw_mode.strip().lower()
        raw_mode = {'tls': 1, 'on': 1, 'true': 1, 'reality': 2, 'off': 0, 'false': 0, 'none': 0, '': None}.get(raw_mode, raw_mode)
    # Xboard 原生 UniProxy 把 REALITY 的 private_key / short_id 放在 tls_settings，
    # 不一定存在独立 reality_settings；VLESS + tls=2 必须识别为 REALITY，而非普通 TLS。
    reality_keys = ('private_key', 'privateKey', 'short_id', 'shortId', 'public_key', 'publicKey')
    if (reality_settings and any(reality_settings.get(k) for k in reality_keys)) or \
       (protocol == 'vless' and any(tls_settings.get(k) for k in reality_keys)):
        raw_mode = 2

    server_name = str(
        tls_settings.get('server_name') or tls_obj.get('server_name') or
        reality_settings.get('server_name') or data.get('server_name') or ''
    ).strip()
    allow_insecure = truthy(
        tls_settings.get('allow_insecure', tls_obj.get('allow_insecure',
        reality_settings.get('allow_insecure', False)))
    )
    version = settings.get('version', data.get('version'))
    transport = str(settings.get('network') or settings.get('transport') or data.get('network') or data.get('transport') or '').strip().lower()

    if protocol in ('vmess', 'vless'):
        if raw_mode in (1, '1', True):
            need, label = True, protocol.upper() + ' + TLS'
        elif protocol == 'vless' and raw_mode in (2, '2'):
            need, label = False, 'VLESS REALITY'
        elif raw_mode in (0, '0', None, False):
            need, label = False, protocol.upper() + '（未启用普通 TLS）'
        else:
            raise RuntimeError(f'节点 {node.get("NodeID")} 的 {protocol} TLS 字段无法识别：{tls_value!r}')
    elif protocol == 'trojan':
        if raw_mode in (2, '2'):
            need, label = False, 'Trojan REALITY'
        elif raw_mode in (0, '0', False):
            raise RuntimeError(f'节点 {node.get("NodeID")} 的 Trojan 未启用 TLS/REALITY；AriNode Trojan 入站需要 TLS，请先检查 Xboard 节点设置')
        elif raw_mode in (1, '1', True, None):
            need, label = True, 'Trojan + TLS'
        else:
            raise RuntimeError(f'节点 {node.get("NodeID")} 的 Trojan TLS 字段无法识别：{tls_value!r}')
    elif protocol == 'hysteria':
        if version not in (None, '', 0, '0', 1, '1', 2, '2'):
            raise RuntimeError(f'节点 {node.get("NodeID")} 的 Hysteria version 不受支持：{version!r}')
        # AriNode 原生 NodeInfo 仅在 version=2 时转为 hysteria2；缺省/0/1 均按 HY1 处理。
        if version not in (2, '2'):
            up = settings.get('up_mbps') or settings.get('upMbps') or data.get('up_mbps') or data.get('upMbps')
            down = settings.get('down_mbps') or settings.get('downMbps') or data.get('down_mbps') or data.get('downMbps')
            try:
                if float(up) <= 0 or float(down) <= 0:
                    raise ValueError
            except (TypeError, ValueError):
                raise RuntimeError(f'节点 {node.get("NodeID")} 按 AriNode 规则属于 Hysteria 1，但面板未提供正数上下行带宽；请先完善 Xboard 节点带宽配置')
        need = True
        if version in (2, '2'):
            label = 'Hysteria 2（HY2）'
        else:
            label = 'Hysteria 1（HY1）'
    elif protocol == 'tuic':
        if version not in (None, '', 0, '0', 5, '5'):
            raise RuntimeError(f'节点 {node.get("NodeID")} 的 TUIC 版本不受支持（AriNode 仅支持 v5）：{version!r}')
        need, label = True, 'TUIC v5'
    elif protocol == 'anytls':
        need, label = True, 'AnyTLS'
    elif protocol in ('shadowsocks', 'mieru'):
        need, label = False, protocol.upper()
    else:
        raise RuntimeError(f'节点 {node.get("NodeID")} 的协议 {protocol!r} 不在 AriNode 支持列表中')

    cert = settings.get('cert_config') or settings.get('certConfig') or data.get('cert_config') or data.get('certConfig') or {}
    if not isinstance(cert, dict):
        cert = {}
    panel_mode = str(cert.get('cert_mode') or cert.get('mode') or '').strip().lower()
    return protocol, label, need, server_name, allow_insecure, cert, panel_mode, transport


def valid_domain(value, allow_wildcard=False):
    value = (value or '').strip().lower().rstrip('.')
    if '://' in value or '/' in value or ':' in value or ' ' in value:
        return False
    if value.startswith('*.'):
        if not allow_wildcard:
            return False
        value = value[2:]
    try:
        ipaddress.ip_address(value)
        return False
    except ValueError:
        pass
    if len(value) > 253 or '.' not in value:
        return False
    labels = value.split('.')
    return all(1 <= len(x) <= 63 and re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', x) for x in labels)


def validate_pair(cert_path, key_path):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(cert_path), str(key_path))


def panel_cert_status(node_id, cert, mode, allow_insecure):
    if mode in ('self-signed', 'selfsigned'):
        raise RuntimeError(f'节点 {node_id} 的面板 cert_mode={mode} 不符合 AriNode 要求；请在 Xboard 中改为 self')
    if mode not in ('http', 'dns', 'self', 'file', 'content', 'auto'):
        raise RuntimeError(f'节点 {node_id} 的面板 cert_mode={mode!r} 暂不支持；拒绝静默忽略')
    if mode == 'auto':
        if allow_insecure:
            print(f'  Xboard 已选择 auto，且允许不安全证书；保留 AriNode 持久化自签模式。')
            return True
        return False
    domain = cert.get('domain') or cert.get('cert_domain') or cert.get('CertDomain') or ''
    cert_file = cert.get('cert_file') or cert.get('CertFile') or ''
    key_file = cert.get('key_file') or cert.get('KeyFile') or ''
    if mode in ('http', 'dns', 'self') and not domain:
        raise RuntimeError(f'节点 {node_id} 的面板证书模式为 {mode}，但没有填写 domain；请先在 Xboard 面板补全')
    if mode in ('http', 'dns', 'self') and (not cert_file or not key_file):
        raise RuntimeError(f'节点 {node_id} 的面板证书模式为 {mode}，但缺少 cert_file/key_file；请在 Xboard 证书配置中补全证书和私钥保存路径')
    if mode == 'dns':
        provider = cert.get('dns_provider') or cert.get('Provider') or cert.get('provider')
        dns_env = cert.get('dns_env') or cert.get('DNSEnv') or {}
        if not provider or not isinstance(dns_env, dict) or not dns_env:
            raise RuntimeError(f'节点 {node_id} 的面板证书模式为 dns，但缺少 dns_provider 或 dns_env；请在 Xboard 补全 DNS API 凭据')
    if mode == 'file':
        cp = cert_file
        kp = key_file
        if not cp or not kp or not pathlib.Path(cp).is_file() or not pathlib.Path(kp).is_file():
            raise RuntimeError(f'节点 {node_id} 的面板 file 证书路径在本机不存在，请检查面板下发路径')
    if mode == 'content':
        cert_pem = cert.get('cert_content') or cert.get('CertContent')
        key_pem = cert.get('key_content') or cert.get('KeyContent')
        if not cert_pem or not key_pem:
            raise RuntimeError(f'节点 {node_id} 的面板 content 证书缺少证书内容或私钥')
        import tempfile
        with tempfile.TemporaryDirectory(prefix='arinode-panel-cert-check-') as td:
            cp = pathlib.Path(td) / 'cert.pem'
            kp = pathlib.Path(td) / 'key.pem'
            cp.write_text(cert_pem, encoding='utf-8')
            kp.write_text(key_pem, encoding='utf-8')
            try:
                validate_pair(cp, kp)
            except Exception as exc:
                raise RuntimeError(f'节点 {node_id} 的面板 content 证书/私钥无法配对：{exc}')
    print(f'  面板已配置证书模式：{mode}' + (f'，域名：{domain}' if domain else ''))
    return True


def configure_one(node, data, info, cfg):
    node_id = int(node.get('NodeID') or 0)
    protocol, label, need, server_name, allow_insecure, panel_cert, panel_mode, transport = info
    print(f'\n节点 {node_id}：{label}；传输：{transport or "面板默认"}；TLS 证书：{"需要" if need else "不需要普通证书"}')
    if protocol in ('vmess', 'vless') and transport in ('xhttp', 'splithttp') and str(node.get('Core') or '').lower() in ('sing', 'singbox', 'sing-box', ''):
        print('  提示：当前 AriNode 内置 Sing-box 不支持 XHTTP；该节点将按 AriNode 规则自动使用内置 Xray 处理此传输。')
    if not need:
        print('  跳过证书配置。')
        return False

    if panel_mode:
        if panel_mode == 'none':
            raise RuntimeError(f'节点 {node_id} 的 Xboard 面板明确设置 cert_mode=none，但该协议需要 TLS；请先在面板修改证书模式')
        if panel_cert_status(node_id, panel_cert, panel_mode, allow_insecure):
            print('  证书由 Xboard 面板管理，本脚本不覆盖。')
            return False

    existing = node.get('CertConfig') or {}
    if not isinstance(existing, dict):
        existing = {}
    existing_mode = str(existing.get('CertMode') or existing.get('cert_mode') or '').lower()
    if existing_mode in ('http', 'dns', 'self', 'file', 'content'):
        if run_mode != 'manage' or ask(f'  已有本地证书模式 {existing_mode}，是否重新配置？[y/N]: ', 'n').lower() not in ('y', 'yes'):
            print('  保留现有本地证书配置。')
            return False

    default_domain = server_name
    if default_domain:
        print('  面板 SNI：' + default_domain)
    if not allow_insecure:
        print('  面板未允许跳过证书校验；必须配置受信任证书，否则节点可能无法启动。')
        choices = '1-4'
    else:
        print('  面板允许跳过证书校验；也可选择 0 保留 AriNode auto 自签模式。')
        choices = '0-4'
    print('  证书方式：')
    print('    1. HTTP-01 自动申请（域名需解析到本机；公网 TCP 80 必须可访问且未被其他服务占用）')
    print('    2. DNS-01 自动申请（无需开放 80 端口；需要 DNS Provider API 凭据）')
    print('    3. 自签名证书（客户端必须允许/信任自签）')
    print('    4. 使用已有证书和私钥文件')
    if allow_insecure:
        print('    0. 保留 auto（由 AriNode 按面板 allow_insecure 自动自签）')
    choice = ask(f'  请选择 [{"1" if not allow_insecure else "1"}]：', '1')
    if choice == '0':
        if not allow_insecure:
            raise RuntimeError(f'节点 {node_id} 不允许跳过证书校验，不能使用 auto 自签模式')
        node.pop('CertConfig', None)
        print('  保留 auto 模式。')
        return True
    if choice not in ('1', '2', '3', '4'):
        raise RuntimeError(f'节点 {node_id} 的证书方式选择无效（允许：{choices}）')

    domain = ask(f'  请输入节点 {node_id} 的证书域名' + (f'（回车使用面板 SNI：{default_domain}）：' if default_domain else '：'), default_domain)
    if not valid_domain(domain, allow_wildcard=(choice == '2')):
        raise RuntimeError(f'节点 {node_id} 的证书域名无效：HTTP-01 不支持通配符；DNS-01 可使用 *.example.com')

    cert_cfg = copy.deepcopy(existing)
    cert_cfg['CertDomain'] = domain
    cert_cfg.pop('CertMode', None)
    cert_cfg.pop('CertFile', None)
    cert_cfg.pop('KeyFile', None)
    cert_cfg.pop('Provider', None)
    cert_cfg.pop('DNSEnv', None)

    # AriNode 的 http/dns/self/file 模式都要求 CertFile 和 KeyFile；仅写 CertMode 会启动失败。
    target = cert_root / str(node_id)
    target.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(target, 0o700)
    cert_path = target / 'fullchain.pem'
    key_path = target / 'privkey.pem'
    cert_cfg['CertFile'] = str(cert_path)
    cert_cfg['KeyFile'] = str(key_path)

    if choice == '1':
        port = ask('  HTTP-01 验证端口 [80]：', '80')
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            raise RuntimeError('HTTP-01 端口必须是 1–65535')
        email = ask('  ACME 通知邮箱（可留空）：', '')
        cert_cfg.update({'CertMode': 'http', 'HTTPPort': int(port)})
        if email:
            cert_cfg['Email'] = email
        try:
            socket.getaddrinfo(domain, None)
        except OSError:
            print('  警告：当前无法解析该域名；请确认 DNS A/AAAA 记录指向本 VPS。')
        if shutil.which('ss'):
            result = subprocess.run(['ss', '-ltn'], capture_output=True, text=True)
            if re.search(r'[:.]' + re.escape(port) + r'\s', result.stdout):
                print(f'  警告：本机似乎已有进程监听 TCP {port}；HTTP-01 申请时可能发生端口冲突。')
    elif choice == '2':
        provider = ask('  DNS Provider（例如 cloudflare / alidns）：', '')
        if not provider or not re.fullmatch(r'[A-Za-z0-9_-]+', provider):
            raise RuntimeError('DNS Provider 名称无效')
        email = ask('  ACME 通知邮箱（可留空）：', '')
        dns_env = {}
        print('  输入 DNS Provider 环境变量；每行 KEY=VALUE，VALUE 隐藏，空行结束。')
        while True:
            line = getpass.getpass('  DNS 环境变量：')
            if not line:
                break
            if '=' not in line:
                print('  格式错误，应为 KEY=VALUE')
                continue
            key, value = line.split('=', 1)
            key = key.strip()
            if not key or not value:
                print('  KEY 和 VALUE 均不能为空')
                continue
            dns_env[key] = value
        if not dns_env:
            raise RuntimeError('DNS-01 至少需要一个 DNS API 环境变量')
        cert_cfg.update({'CertMode': 'dns', 'Provider': provider, 'DNSEnv': dns_env})
        if email:
            cert_cfg['Email'] = email
    elif choice == '3':
        if not allow_insecure:
            print('  警告：自签证书不受公共 CA 信任，客户端严格校验时仍会失败。')
        cert_cfg['CertMode'] = 'self'
    elif choice == '4':
        source_cert = pathlib.Path(ask('  已有证书 fullchain.pem 路径：', ''))
        source_key = pathlib.Path(ask('  已有私钥 privkey.pem 路径：', ''))
        if not source_cert.is_file() or not source_key.is_file():
            raise RuntimeError('证书或私钥文件不存在')
        if source_cert.resolve() != cert_path.resolve():
            shutil.copy2(source_cert, cert_path)
        if source_key.resolve() != key_path.resolve():
            shutil.copy2(source_key, key_path)
        os.chmod(cert_path, 0o600)
        os.chmod(key_path, 0o600)
        validate_pair(cert_path, key_path)
        cert_cfg.update({'CertMode': 'file', 'CertFile': str(cert_path), 'KeyFile': str(key_path)})

    node['CertConfig'] = cert_cfg
    print(f'  已为节点 {node_id} 写入本地 CertConfig：{cert_cfg.get("CertMode")} / {domain}')
    return True


def save_config(data):
    if run_mode == 'manage':
        import datetime
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
        backup = config_path.with_name(config_path.name + '.' + stamp + '.bak')
        shutil.copy2(config_path, backup)
        os.chmod(backup, 0o600)
        print('配置备份：' + str(backup))
    fd, temp_name = tempfile.mkstemp(prefix='.arinode-config-', dir=str(config_path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, config_path)
        os.chmod(config_path, 0o600)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def main():
    if not config_path.is_file():
        raise RuntimeError(f'找不到配置文件：{config_path}')
    cfg = json.loads(config_path.read_text(encoding='utf-8'))
    nodes = cfg.get('Nodes') or []
    if not isinstance(nodes, list) or not nodes:
        raise RuntimeError('配置文件中没有 Nodes 节点列表')

    changed = False
    checked = 0
    for node in nodes:
        node_id = int(node.get('NodeID') or 0)
        node_type = str(node.get('NodeType') or '').strip().lower()
        if not node_id or not node_type:
            raise RuntimeError('节点配置缺少 NodeID 或 NodeType')
        base, token = panel_binding(cfg, node)
        if not base or not token:
            raise RuntimeError(f'节点 {node_id} 缺少面板地址或 Token，无法安全识别 TLS')
        print(f'正在查询节点 {node_id} 的 UniProxy 协议/TLS 配置（不显示 Token）……')
        data = fetch_node_config(base, token, node_id, node_type)
        info = tls_info(node, data)
        checked += 1
        changed = configure_one(node, data, info, cfg) or changed

    if changed:
        save_config(cfg)
        print('\nTLS/证书配置已保存。ACME HTTP-01/DNS-01 证书将在 AriNode 启动时申请并由 AriNode 管理续期。')
    else:
        print('\n所有节点的证书配置均已保留或无需普通 TLS 证书。')
    print(f'已检查节点：{checked}')

try:
    main()
except KeyboardInterrupt:
    print('\n用户取消。', file=sys.stderr)
    sys.exit(130)
except Exception as exc:
    print('证书配置失败：' + str(exc), file=sys.stderr)
    sys.exit(1)
PY_TLS_SETUP
}

# -------------------- 安装 / 初始化 --------------------
# 本管理脚本直接下载并校验 AriNode Release 二进制，不调用官方 install.sh，
# 也不调用 anctl bash 官方交互向导。配置由本脚本收集参数，再调用 anctl init 生成。
install_arinode() {
    require_command curl || return 1
    require_command tar || return 1
    require_command sha256sum || return 1
    require_command awk || return 1
    require_command install || return 1
    require_command python3 || return 1
    check_platform || return 1

    local arch asset staging expected actual version_line release_version
    local panel_url panel_token nodes_text node_count node_id node_protocol node_result node_display config_mode="new"
    local config_stage config_target_tmp service_created=0
    local dns_choice="n" dns_ip="1.1.1.1"
    local core_choice="1" core_type=""
    local had_arinode=0 had_anctl=0
    local -a node_items=() init_args=()

    case "$(uname -m)" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) red "暂不支持当前架构：$(uname -m)"; return 1 ;;
    esac
    asset="arinode-linux-${arch}.tar.gz"

    echo
    blue "========== AriNode 自主安装 / 初始化 =========="
    echo "本脚本直接下载官方 Release 二进制并校验 SHA256。"
    echo "不会运行官方 install.sh，也不会进入 anctl bash 官方交互菜单。"
    echo

    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    chmod 700 "$CONFIG_DIR" "$BACKUP_DIR"

    if [[ -L "$CONFIG" ]]; then
        red "检测到 config.json 是符号链接，为避免覆盖外部文件，已停止安装。"
        return 1
    fi
    if [[ -f "$CONFIG" ]]; then
        yellow "检测到已有 config.json，为避免覆盖，默认保留原配置。"
        read -e -r -p "是否重新生成配置？[y/N]: " config_mode
        if [[ "$config_mode" =~ ^[Yy]$ ]]; then
            config_mode="new"
        else
            config_mode="keep"
            yellow "保留现有 config.json；本次只更新/安装 AriNode 程序。"
        fi
    fi

    staging="$(mktemp -d /tmp/arinode-release.XXXXXX)" || return 1
    local previous_return_trap
    previous_return_trap="$(trap -p RETURN || true)"
    trap 'rm -rf -- "$staging"; if [[ -n "$previous_return_trap" ]]; then eval "$previous_return_trap"; else trap - RETURN; fi' RETURN

    blue "正在下载 AriNode ${arch} 正式版及 SHA256 校验文件……"
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
        --proto '=https' --proto-redir '=https' \
        "${RELEASE_DOWNLOAD_URL}/SHA256SUMS" -o "${staging}/SHA256SUMS" || {
        red "SHA256SUMS 下载失败。"; return 1;
    }
    curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
        --proto '=https' --proto-redir '=https' \
        "${RELEASE_DOWNLOAD_URL}/${asset}" -o "${staging}/${asset}" || {
        red "AriNode Release 下载失败。"; return 1;
    }

    expected="$(awk -v name="$asset" '{ file=$2; sub(/^\*/, "", file); if (file == name) { print $1; exit } }' "${staging}/SHA256SUMS")"
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || {
        red "Release 中没有有效的 ${asset} SHA256。"; return 1;
    }
    actual="$(sha256sum "${staging}/${asset}")"
    [[ "${actual%% *}" == "$expected" ]] || {
        red "AriNode Release SHA256 校验失败，未安装任何文件。"; return 1;
    }
    green "SHA256 校验通过。"

    python3 - "${staging}/${asset}" "$staging" <<'PY_ARCHIVE_EXTRACT' || return 1
import pathlib, sys, tarfile, os
archive=pathlib.Path(sys.argv[1]); dest=pathlib.Path(sys.argv[2])
required={'arinode','anctl'}; found={}
try:
    with tarfile.open(archive,'r:gz') as tf:
        for member in tf.getmembers():
            name=pathlib.PurePosixPath(member.name)
            if name.is_absolute() or '..' in name.parts:
                raise ValueError('压缩包含有不安全路径：'+member.name)
            base=name.name
            if base in required:
                if base in found:
                    raise ValueError('压缩包中存在重复的 '+base+' 文件')
                if not member.isfile():
                    raise ValueError(base+' 不是普通文件')
                found[base]=member
        if set(found)!=required:
            raise ValueError('Release 压缩包缺少 arinode 或 anctl 主程序')
        for base,member in found.items():
            src=tf.extractfile(member)
            if src is None: raise ValueError('无法读取 '+base)
            out=dest/base
            with src, out.open('wb') as dst:
                while True:
                    chunk=src.read(1024*1024)
                    if not chunk: break
                    dst.write(chunk)
            os.chmod(out,0o755)
except Exception as e:
    raise SystemExit('Release 压缩包校验/解压失败：'+str(e))
print('已安全提取 arinode 和 anctl；其他 Release 附件不会执行或安装。')
PY_ARCHIVE_EXTRACT
    for binary in arinode anctl; do
        [[ -f "${staging}/${binary}" && ! -L "${staging}/${binary}" ]] || {
            red "Release 中缺少有效的 ${binary} 文件。"; return 1;
        }
        chmod 755 "${staging}/${binary}"
    done
    version_line="$("${staging}/arinode" version 2>/dev/null)" || { red "无法读取新版本 arinode 版本号。"; return 1; }
    [[ "$version_line" =~ ^AriNode[[:space:]]([0-9]{8}-[0-9a-f]{8,12})[[:space:]] ]] || {
        red "Release 版本号格式异常：${version_line}"; return 1;
    }
    release_version="${BASH_REMATCH[1]}"
    [[ "$("${staging}/anctl" version 2>/dev/null)" == "$version_line" ]] || {
        red "arinode 与 anctl 版本不一致，已停止安装。"; return 1;
    }
    green "已验证 AriNode 版本：${release_version}（linux/${arch}）"

    # 如需重新生成配置，全部先写入临时文件；验证成功后才替换正式配置。
    if [[ "$config_mode" == "new" ]]; then
        # 与 xboard-node.sh 一致：重新生成前先备份现有配置；仅在新配置校验成功后替换。
        if [[ -f "$CONFIG" ]]; then
            backup_file "$CONFIG" || { red "旧配置备份失败，已取消重新生成。"; return 1; }
        fi

        echo
        blue "========== 选择运行内核 =========="
        echo "1. Sing-box（推荐，默认）"
        echo "2. Xray（部分协议不支持）"
        read -e -r -p "请选择内核 [1]：" core_choice
        core_choice="${core_choice:-1}"
        case "$core_choice" in
            1) core_type="sing"; green "已选择 Sing-box 内核。" ;;
            2) core_type="xray"; yellow "已选择 Xray 内核；稍后会检查所有节点协议兼容性。" ;;
            *) red "无效内核选择，请输入 1 或 2。"; return 1 ;;
        esac

        if [[ "$core_type" == "sing" ]]; then
            echo
            blue "========== Sing-box 自定义 DNS =========="
            echo "是否创建或修改 ${DNS_CONFIG}？"
            echo "默认创建；输入 n 跳过。"
            read -e -r -p "是否创建/修改 [Y/n]: " dns_choice
            dns_choice="${dns_choice:-y}"
            if [[ "$dns_choice" =~ ^[Nn]([Oo])?$ ]]; then
                dns_choice="n"
                yellow "已跳过自定义 DNS：不创建 sing_origin.json，也不修改 config.json 的 DNS 引用。"
            else
                dns_choice="y"
                read -e -r -p "请输入自定义 DNS 解锁 IP [1.1.1.1]: " dns_ip
                dns_ip="${dns_ip:-1.1.1.1}"
                python3 - "$dns_ip" <<'PY_DNS_IP_CHECK' || return 1
import ipaddress,sys
try: ipaddress.ip_address(sys.argv[1])
except ValueError: raise SystemExit('DNS IP 无效，请输入 IPv4 或 IPv6 地址。')
PY_DNS_IP_CHECK
            fi
        else
            dns_choice="n"
            yellow "Xray 不使用 sing_origin.json；本次自动跳过 Sing-box 自定义 DNS。"
        fi

        echo
        blue "========== Xboard 面板及节点配置 =========="
        read -e -r -p "面板地址：" panel_url
        [[ -n "$panel_url" ]] || { red "面板地址不能为空。"; return 1; }
        [[ "$panel_url" =~ ^https?://[^[:space:]]+$ ]] || {
            red "面板地址格式无效，必须以 http:// 或 https:// 开头。"; return 1;
        }
        panel_url="${panel_url%/}"
        read -e -r -p "请输入面板 Token：" panel_token
        [[ -n "$panel_token" ]] || { red "面板 Token 不能为空，已取消配置生成。"; return 1; }
        read -e -r -p "请输入节点数量 [1]: " node_count
        node_count="${node_count:-1}"
        [[ "$node_count" =~ ^[1-9][0-9]*$ ]] && ((node_count <= 30)) || {
            red "节点数量必须是 1–30 之间的整数。"; return 1;
        }

        local -A seen_node_ids=()
        for ((node_index=1; node_index<=node_count; node_index++)); do
            read -e -r -p "请输入第 ${node_index} 个节点 ID：" node_id
            [[ "$node_id" =~ ^[1-9][0-9]*$ ]] || { red "节点 ID 必须是正整数。"; return 1; }
            [[ -z "${seen_node_ids[$node_id]+x}" ]] || { red "节点 ID ${node_id} 重复，请重新执行配置。"; return 1; }
            seen_node_ids[$node_id]=1

            blue "正在从 Xboard 查询节点 ${node_id} 配置……"
            node_result="$(ARINODE_PANEL_TOKEN="$panel_token" python3 - "$panel_url" "$node_id" <<'PY_NODE_QUERY'
import json,os,sys,urllib.parse,urllib.request,urllib.error
base,node_id=sys.argv[1:]
token=os.environ.get('ARINODE_PANEL_TOKEN','')
# AriNode legacy UniProxy inbound bindings; Xboard-only socks/http/naive are intentionally excluded.
allowed={'vmess','vless','trojan','shadowsocks','hysteria','tuic','anytls','mieru'}
alias={'hysteria2':'hysteria','hy2':'hysteria','ss':'shadowsocks','v2ray':'vmess'}
headers={'Accept':'application/json','User-Agent':'AriNode-Manager/2.1'}

def get_json(path, params):
    url=base.rstrip('/')+path+'?'+urllib.parse.urlencode(params)
    req=urllib.request.Request(url,headers=headers)
    try:
        with urllib.request.urlopen(req,timeout=20) as r:
            raw=r.read(4*1024*1024+1)
        if len(raw)>4*1024*1024:
            raise RuntimeError('面板响应超过 4 MiB')
        obj=json.loads(raw.decode('utf-8'))
        if not isinstance(obj,dict):
            raise RuntimeError('响应不是 JSON 对象')
        if str(obj.get('status','')).lower()=='fail':
            raise RuntimeError(str(obj.get('message','面板拒绝查询')))
        data=obj.get('data') if isinstance(obj.get('data'),dict) else obj
        if isinstance(data,str):
            data=json.loads(data)
        if not isinstance(data,dict):
            raise RuntimeError('data 字段不是 JSON 对象')
        return data
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'HTTP {e.code}')
    except urllib.error.URLError as e:
        raise RuntimeError(f'连接失败：{e.reason}')

# 本脚本只使用普通节点模式：Xboard 全局 server token + UniProxy v1。
# /api/v2/server/config 属于机器模式，不在本脚本的普通节点初始化流程中使用。
# 先覆盖 Xboard 当前所有有效节点类型，再明确区分 AriNode 是否支持该入站协议。
xboard_candidates=('vmess','vless','trojan','shadowsocks','hysteria','tuic','anytls','socks','naive','http','mieru')
arinode_supported={'vmess','vless','trojan','shadowsocks','hysteria','tuic','anytls','mieru'}
errors=[]
for candidate in xboard_candidates:
    try:
        data=get_json('/api/v1/server/UniProxy/config',{
            'node_id':node_id,'node_type':candidate,'token':token
        })
        returned=data.get('protocol') or data.get('node_type') or data.get('type')
        if isinstance(returned,dict):
            returned=returned.get('protocol') or returned.get('type')
        returned=alias.get(str(returned or '').strip().lower(),str(returned or '').strip().lower())
        if returned==candidate:
            if returned not in arinode_supported:
                raise SystemExit(
                    '已识别 Xboard 节点协议：'+returned+'。但 AriNode 当前 UniProxy 服务端不支持该类型作为入站节点；'
                    'Xboard 支持不等于 AriNode 后端支持。请改用 AriNode 支持的 VMess/VLESS/Trojan/SS/Hysteria/TUIC/AnyTLS/Mieru。'
                )
            version=data.get('version')
            tls=data.get('tls')
            if returned=='hysteria':
                display='Hysteria 2（HY2）' if str(version)=='2' else 'Hysteria 1（HY1）'
            elif returned in ('vless','vmess'):
                if str(tls)=='2': display=returned.upper()+' REALITY'
                elif str(tls)=='1': display=returned.upper()+' + TLS'
                else: display=returned.upper()
            elif returned=='trojan':
                display='Trojan REALITY' if str(tls)=='2' else 'Trojan + TLS'
            elif returned=='tuic': display='TUIC v5'
            elif returned=='anytls': display='AnyTLS'
            elif returned=='shadowsocks': display='Shadowsocks'
            elif returned=='mieru': display='Mieru'
            else: display=returned.upper()
            print(returned+'|'+display)
            raise SystemExit(0)
    except SystemExit:
        raise
    except Exception as e:
        errors.append(candidate+': '+str(e))
summary='；'.join(errors[:3])
raise SystemExit('无法自动识别节点协议。仅使用普通节点 UniProxy v1 接口查询；没有根据节点 ID 猜测协议。请检查 server token、节点 ID 和 Xboard API。'+((' 接口错误摘要：'+summary) if summary else ''))
PY_NODE_QUERY
            )" || { red "节点 ${node_id} 查询失败，已停止生成配置。"; return 1; }
            node_protocol="${node_result%%|*}"
            node_display="${node_result#*|}"
            [[ -n "$node_protocol" && -n "$node_display" ]] || { red "节点 ${node_id} 协议查询结果格式异常。"; return 1; }
            node_items+=("${node_protocol}:${node_id}")
            init_args+=(--node "${node_protocol}:${node_id}")
            green "节点 ${node_id}：${node_display}（NodeType：${node_protocol}）"
        done

        if [[ "$core_type" == "xray" ]]; then
            for item in "${node_items[@]}"; do
                item_protocol="${item%%:*}"
                case "$item_protocol" in
                    vmess|vless|trojan|shadowsocks) ;;
                    *)
                        red "Xray 不支持 AriNode 的 ${item_protocol} 节点绑定；请重新安装并选择 Sing-box。"
                        return 1
                        ;;
                esac
            done
        fi

        config_stage="${staging}/config.json"
        blue "正在由 AriNode CLI 生成 config.json（不是运行官方安装脚本）……"
        if ! ARINODE_PANEL_TOKEN="$panel_token" "${staging}/anctl" init \
            --panel "$panel_url" "${init_args[@]}" --output "$config_stage"; then
            red "anctl init 配置生成失败。旧配置未修改，服务未重启。"
            return 1
        fi
        [[ -s "$config_stage" ]] || { red "没有生成 config.json。"; return 1; }
        python3 -m json.tool "$config_stage" >/dev/null || {
            red "生成的 config.json JSON 校验失败。"; return 1;
        }
        # anctl init 默认生成 sing；按用户选择明确写入 Cores.Type 和每个 Nodes[].Core。
        python3 - "$config_stage" "$core_type" <<'PY_CORE_SELECT' || return 1
import json, pathlib, sys, tempfile, os
p=pathlib.Path(sys.argv[1]); core=sys.argv[2]
cfg=json.loads(p.read_text(encoding='utf-8'))
nodes=cfg.get('Nodes')
if not isinstance(nodes,list) or not nodes:
    raise SystemExit('生成配置缺少 Nodes 列表。')
cores=cfg.get('Cores')
base={}
if isinstance(cores,list):
    base=next((dict(x) for x in cores if isinstance(x,dict)),{})
base['Type']=core
cfg['Cores']=[base]
for n in nodes:
    if not isinstance(n,dict):
        raise SystemExit('Nodes 中存在无效节点对象。')
    n['Core']=core
fd,tmp=tempfile.mkstemp(prefix='.config-core-',dir=str(p.parent))
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(cfg,f,ensure_ascii=False,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print('已写入运行内核：'+core+'；节点数：'+str(len(nodes)))
PY_CORE_SELECT
        echo
        blue "========== 自动识别节点 TLS / 配置证书 =========="
        if ! ARINODE_PANEL_TOKEN="$panel_token" configure_tls_certificates "$config_stage" "$panel_url" initial; then
            red "节点 TLS / 证书配置未完成；旧配置保持不变，本次不会启动服务。"
            return 1
        fi
        unset panel_token
        python3 -m json.tool "$config_stage" >/dev/null || {
            red "证书配置后的 config.json JSON 校验失败。"; return 1;
        }
        chmod 600 "$config_stage"
    fi


    # ---------------- 安全安装事务 ----------------
    local unit_file="/etc/systemd/system/${SERVICE}"
    local unit_tmp="${unit_file}.new.$$"
    local arinode_tmp="${ARINODE_BIN}.new.$$"
    local anctl_tmp="${ANCTL_BIN}.new.$$"
    local config_tmp="${CONFIG}.new.$$"
    local had_config=0
    local was_enabled=0
    local was_active=0
    local service_created=0
    local replaced_arinode=0
    local replaced_anctl=0
    local replaced_config=0
    local enabled_by_transaction=0
    local tx_failed=0
    local rollback_errors=0
    local unit_state available_kb required_kb new_bytes old_bytes

    # 拒绝被屏蔽的服务。
    unit_state="$(systemctl is-enabled "$SERVICE" 2>/dev/null || true)"
    if [[ "$unit_state" == "masked" ]] ||
       { [[ -L "$unit_file" ]] &&
         [[ "$(readlink -f "$unit_file" 2>/dev/null || true)" == "/dev/null" ]]; }; then
        red "服务 ${SERVICE} 已被屏蔽，停止安装。"
        return 1
    fi

    systemctl is-enabled --quiet "$SERVICE" 2>/dev/null && was_enabled=1
    systemctl is-active --quiet "$SERVICE" 2>/dev/null && was_active=1
    [[ -f "$CONFIG" ]] && had_config=1

    # 按实际新旧二进制大小检查剩余空间。
    new_bytes=$(( $(stat -c %s "${staging}/arinode") + $(stat -c %s "${staging}/anctl") ))
    old_bytes=0
    [[ -f "$ARINODE_BIN" ]] && old_bytes=$((old_bytes + $(stat -c %s "$ARINODE_BIN")))
    [[ -f "$ANCTL_BIN" ]] && old_bytes=$((old_bytes + $(stat -c %s "$ANCTL_BIN")))
    required_kb=$(( (new_bytes + old_bytes) / 1024 + 32768 ))
    available_kb="$(df -Pk "$BIN_DIR" | awk 'NR==2 {print $4}')"

    if [[ ! "$available_kb" =~ ^[0-9]+$ ]] || (( available_kb < required_kb )); then
        red "磁盘空间不足：可用 ${available_kb:-未知} KB，需要约 ${required_kb} KB。"
        return 1
    fi

    # 备份所有现有文件；备份不完整则禁止替换。
    if [[ -f "$ARINODE_BIN" ]]; then
        if ! cp -p -- "$ARINODE_BIN" "${staging}/previous-arinode" ||
           ! cmp -s -- "$ARINODE_BIN" "${staging}/previous-arinode"; then
            red "旧 arinode 备份失败，停止安装。"
            return 1
        fi
        had_arinode=1
    fi

    if [[ -f "$ANCTL_BIN" ]]; then
        if ! cp -p -- "$ANCTL_BIN" "${staging}/previous-anctl" ||
           ! cmp -s -- "$ANCTL_BIN" "${staging}/previous-anctl"; then
            red "旧 anctl 备份失败，停止安装。"
            return 1
        fi
        had_anctl=1
    fi

    if ((had_config)); then
        if ! cp -a -- "$CONFIG" "${staging}/previous-config.json" ||
           ! cmp -s -- "$CONFIG" "${staging}/previous-config.json"; then
            red "旧 config.json 备份失败，停止安装。"
            return 1
        fi
    fi

    # 在正式路径所在文件系统中准备二进制临时文件。
    if ! install -d -m 755 "$BIN_DIR" ||
       ! install -m 755 "${staging}/arinode" "$arinode_tmp" ||
       [[ ! -s "$arinode_tmp" ]] ||
       ! cmp -s -- "${staging}/arinode" "$arinode_tmp" ||
       ! install -m 755 "${staging}/anctl" "$anctl_tmp" ||
       [[ ! -s "$anctl_tmp" ]] ||
       ! cmp -s -- "${staging}/anctl" "$anctl_tmp"; then
        rm -f -- "$arinode_tmp" "$anctl_tmp"
        red "新二进制准备或校验失败，旧文件未替换。"
        return 1
    fi

    # 统一原子恢复函数。没有旧文件时删除本次新建文件。
    ari_tx_restore() {
        local saved="$1" target="$2" mode="$3"
        local tmp="${target}.rollback.$$"
        if [[ -f "$saved" ]]; then
            if ! install -m "$mode" "$saved" "$tmp" ||
               [[ ! -s "$tmp" ]] ||
               ! cmp -s -- "$saved" "$tmp" ||
               ! mv -f -- "$tmp" "$target"; then
                rm -f -- "$tmp"
                return 1
            fi
        else
            rm -f -- "$target" || return 1
        fi
        return 0
    }

    # 原子替换两个二进制。
    if mv -f -- "$arinode_tmp" "$ARINODE_BIN"; then
        replaced_arinode=1
    else
        tx_failed=1
    fi

    if ((tx_failed == 0)); then
        if mv -f -- "$anctl_tmp" "$ANCTL_BIN"; then
            replaced_anctl=1
        else
            tx_failed=1
        fi
    fi

    # 新服务文件先写临时文件，再验证并原子替换。
    if ((tx_failed == 0)) && [[ ! -e "$unit_file" ]]; then
        if ! cat > "$unit_tmp" <<'UNIT'
[Unit]
Description=AriNode node service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/arinode server --config /etc/arinode/config.json
WorkingDirectory=/etc/arinode
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
        then
            tx_failed=1
        elif [[ ! -s "$unit_tmp" ]] ||
             ! chmod 644 "$unit_tmp" ||
             ! grep -q '^ExecStart=/usr/local/bin/arinode server --config /etc/arinode/config.json$' "$unit_tmp" ||
             ! mv -f -- "$unit_tmp" "$unit_file"; then
            tx_failed=1
        else
            service_created=1
        fi
    fi
    rm -f -- "$unit_tmp"

    # 新配置先写临时文件，校验 JSON 和内容后才替换正式配置。
    if ((tx_failed == 0)) && [[ "$config_mode" == "new" ]]; then
        if ! install -m 600 "$config_stage" "$config_tmp" ||
           [[ ! -s "$config_tmp" ]] ||
           ! python3 -m json.tool "$config_tmp" >/dev/null 2>&1 ||
           ! cmp -s -- "$config_stage" "$config_tmp" ||
           ! mv -f -- "$config_tmp" "$CONFIG"; then
            tx_failed=1
        else
            replaced_config=1
        fi
    fi
    rm -f -- "$config_tmp"

    # 启动服务并验证 active 状态。
    if ((tx_failed == 0)); then
        systemctl daemon-reload || tx_failed=1
        if ((tx_failed == 0)); then
            if systemctl enable "$SERVICE"; then
                if ((was_enabled == 0)); then
                    enabled_by_transaction=1
                fi
            else
                tx_failed=1
            fi
        fi
        if ((tx_failed == 0)); then
            if ((was_active)); then
                systemctl restart "$SERVICE" || tx_failed=1
            else
                systemctl start "$SERVICE" || tx_failed=1
            fi
        fi
        if ((tx_failed == 0)) && ! systemctl is-active --quiet "$SERVICE"; then
            tx_failed=1
        fi
    fi

    # 任何失败都恢复本次已替换的文件。
    if ((tx_failed)); then
        red "安装事务失败，开始回滚。"
        systemctl stop "$SERVICE" 2>/dev/null || true

        if ((replaced_config)); then
            ari_tx_restore "${staging}/previous-config.json" "$CONFIG" 600 || rollback_errors=1
        fi
        if ((replaced_anctl)); then
            ari_tx_restore "${staging}/previous-anctl" "$ANCTL_BIN" 755 || rollback_errors=1
        fi
        if ((replaced_arinode)); then
            ari_tx_restore "${staging}/previous-arinode" "$ARINODE_BIN" 755 || rollback_errors=1
        fi

        if ((enabled_by_transaction)); then
            systemctl disable "$SERVICE" >/dev/null 2>&1 || rollback_errors=1
        fi
        if ((service_created)); then
            rm -f -- "$unit_file" || rollback_errors=1
        fi

        systemctl daemon-reload || rollback_errors=1
        if ((was_active)); then
            systemctl start "$SERVICE" || rollback_errors=1
        fi

        unset -f ari_tx_restore
        rm -f -- "$arinode_tmp" "$anctl_tmp" "$config_tmp" "$unit_tmp"

        if ((rollback_errors)); then
            red "严重：回滚有步骤失败。请保留备份并检查文件及 systemd 状态。"
        else
            red "本次安装已回滚，原有文件已恢复。"
        fi
        red "日志检查：journalctl -u ${SERVICE} -n 100 --no-pager"
        return 1
    fi

    unset -f ari_tx_restore
    green "安装事务及服务健康检查全部通过。"
    # ---------------- 安全安装事务结束 ----------------

    green "AriNode 自主安装 / 初始化成功。"
    echo "管理菜单命令：ari-node"
    echo "官方核心命令：arinode（保持不变）"
    echo "版本：${release_version}"
    echo "二进制：${ARINODE_BIN}"
    echo "管理 CLI：${ANCTL_BIN}"
    echo "运行内核：${core_type:-保留现有配置}"
    echo "配置文件：${CONFIG}"
    echo "systemd：${SERVICE}"
    if [[ -f "$CONFIG" && "$config_mode" == "new" ]]; then
        if [[ "$dns_choice" == "y" ]]; then
            dns_apply "$dns_ip" || yellow "自定义 DNS 未能应用；可稍后从主菜单第 9 项设置。"
        else
            yellow "已按选择跳过自定义 DNS。"
        fi
    fi
}


# -------------------- 万国解锁 / Sing-box 自定义 DNS --------------------
# 设计与 Xboard-Node 的 sing_origin.json 一致，但通过 AriNode 的 Cores[].OriginalPath 加载。
# 不修改 Xray 核心；不覆盖用户原有 OriginalPath 文件。

dns_python() {
    require_command python3 || return 1
}

dns_status() {
    if [[ ! -f "$CONFIG" ]]; then
        yellow "尚未找到 config.json：$CONFIG"
        return 1
    fi
    python3 - "$CONFIG" "$DNS_CONFIG" "$DNS_META" <<'PY_DNS_STATUS'
import json, pathlib, sys
cfgp, dnsp, metap = map(pathlib.Path, sys.argv[1:])
try:
    cfg=json.loads(cfgp.read_text())
except Exception as e:
    print(f"config.json 读取失败：{e}"); sys.exit(1)
cores=cfg.get('Cores') or []
sing=[c for c in cores if isinstance(c,dict) and str(c.get('Type','')).lower() in ('sing','singbox','sing-box','')]
print('Sing-box 核心：' + ('已检测到' if sing else '未检测到'))
if metap.exists() and dnsp.exists():
    try:
        d=json.loads(dnsp.read_text()); dns=d.get('dns',{})
        servers=dns.get('servers',[])
        ip=next((x.get('address') for x in servers if isinstance(x,dict) and x.get('tag')=='unlock-dns'),None)
        referenced=any(isinstance(c,dict) and c.get('OriginalPath')==str(dnsp) for c in cores)
        print('自定义 DNS：' + ('已启用' if referenced else '文件存在，但 config.json 未引用（可能被手动修改）'))
        print('DNS IP：' + str(ip or '配置文件中未找到 unlock-dns'))
        print('配置文件：' + str(dnsp))
    except Exception as e: print('DNS 文件解析失败：'+str(e))
else:
    print('自定义 DNS：未由本管理脚本启用')
PY_DNS_STATUS
}

dns_apply() {
    require_arinode || return 1
    dns_python || return 1
    [[ -f "$CONFIG" ]] || { red "找不到配置文件：$CONFIG"; return 1; }
    local current="1.1.1.1" answer dns_ip="${1:-}"
    if [[ -f "$DNS_CONFIG" ]]; then
        current="$(python3 - "$DNS_CONFIG" <<'PY_DNS_CUR' 2>/dev/null || true
import json,sys
try:
 d=json.load(open(sys.argv[1])); print(next((x.get('address') for x in d.get('dns',{}).get('servers',[]) if isinstance(x,dict) and x.get('tag')=='unlock-dns'),'1.1.1.1'))
except Exception: print('1.1.1.1')
PY_DNS_CUR
)"
    fi
    echo
    blue "========== 自定义 DNS 解锁 IP 设置 =========="
    echo "默认 DNS IP：1.1.1.1（与 Xboard-Node 脚本一致，仅为默认值）"
    if [[ -z "$dns_ip" ]]; then
        read -e -r -p "请输入万国解锁 DNS IP [${current}]: " dns_ip
        dns_ip="${dns_ip:-$current}"
    fi
    backup_all || return 1
    if ! python3 - "$CONFIG" "$DNS_CONFIG" "$DNS_META" "$dns_ip" <<'PY_DNS_APPLY'
import copy, datetime, ipaddress, json, os, pathlib, shutil, sys, tempfile
cfgp, dnsp, metap = map(pathlib.Path, sys.argv[1:4]); ip=sys.argv[4]
try: ipaddress.ip_address(ip)
except ValueError: raise SystemExit('输入的 DNS IP 无效，请输入 IPv4 或 IPv6 地址。')
try: cfg=json.loads(cfgp.read_text(encoding='utf-8'))
except Exception as e: raise SystemExit(f'config.json 解析失败：{e}')
cores=cfg.get('Cores')
if not isinstance(cores,list) or not cores: raise SystemExit('config.json 中没有有效的 Cores 数组。')
sing_idx=[i for i,c in enumerate(cores) if isinstance(c,dict) and str(c.get('Type','sing')).strip().lower() in ('','sing','singbox','sing-box')]
if not sing_idx: raise SystemExit('没有检测到 Sing-box 核心。自定义 DNS 不适用于仅使用 Xray 的配置。')
meta=None
if metap.exists():
    try: meta=json.loads(metap.read_text(encoding='utf-8'))
    except Exception as e: raise SystemExit(f'DNS 管理元数据损坏，已停止以避免覆盖：{e}')
if meta is None:
    prev=[]
    existing_paths=set()
    for i in sing_idx:
        core=cores[i]
        had='OriginalPath' in core
        old=core.get('OriginalPath')
        if old: existing_paths.add(str(old))
        prev.append({'index':i,'had':had,'value':old})
    if len(existing_paths)>1:
        raise SystemExit('检测到多个 Sing-box 核心使用不同 OriginalPath。为避免破坏现有自定义配置，请先统一配置路径。')
    source_path=next(iter(existing_paths),None)
    base={}
    if source_path:
        src=pathlib.Path(source_path)
        if not src.is_absolute(): src=pathlib.Path('/etc/arinode')/src
        if not src.is_file(): raise SystemExit(f'原有 OriginalPath 文件不存在：{source_path}')
        try: base=json.loads(src.read_text(encoding='utf-8'))
        except Exception as e: raise SystemExit(f'原有 Sing-box 配置不是有效 JSON：{e}')
        if not isinstance(base,dict): raise SystemExit('原有 Sing-box 配置根节点必须是 JSON 对象。')
    meta={'version':1,'previous':prev,'managed_path':str(dnsp)}
else:
    if meta.get('managed_path') != str(dnsp): raise SystemExit('DNS 管理元数据路径不匹配，停止修改。')
    if not dnsp.is_file(): raise SystemExit('DNS 管理文件丢失，无法安全更新。')
    try: base=json.loads(dnsp.read_text(encoding='utf-8'))
    except Exception as e: raise SystemExit(f'现有自定义 Sing-box 配置损坏：{e}')
    if not isinstance(base,dict): raise SystemExit('现有自定义 Sing-box 配置根节点不是 JSON 对象。')
# 与 Xboard-Node generate_sing_origin() 的 DNS 结构保持一致，保留原文件其他顶层配置。
base['dns']={'servers':[{'tag':'unlock-dns','address':ip}],'strategy':'ipv4_only'}

def atomic_json(path,obj,mode=0o600):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.'+path.name+'.',suffix='.tmp',dir=str(path.parent))
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            json.dump(obj,f,ensure_ascii=False,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp,mode); os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
# Backup the actual config and managed JSON before replacing either.
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
for path in (cfgp, dnsp):
    if path.exists():
        bak=path.with_name(path.name+'.'+stamp+'.bak'); shutil.copy2(path,bak); os.chmod(bak,0o600); print('备份：'+str(bak))
atomic_json(dnsp,base,0o600)
for i in sing_idx: cores[i]['OriginalPath']=str(dnsp)
atomic_json(cfgp,cfg,0o600)
atomic_json(metap,meta,0o600)
print('DNS 配置已写入：'+str(dnsp)); print('DNS IP：'+ip); print('已关联 Sing-box 核心数量：'+str(len(sing_idx)))
PY_DNS_APPLY
    then
        red "自定义 DNS 配置失败，未执行重启。"
        return 1
    fi
    green "自定义 DNS IP 已更新。"
    if confirm_yes "是否立即重启 AriNode 使 DNS 配置生效？"; then
        "$ANCTL_BIN" restart
    else
        yellow "尚未重启；新的 DNS 配置将在 AriNode 下次重启后加载。"
    fi
}

dns_disable() {
    require_arinode || return 1
    [[ -f "$DNS_META" ]] || { yellow "当前没有由本管理脚本启用的自定义 DNS。"; return 0; }
    confirm_yes "确认停用自定义 DNS，并恢复启用前的 OriginalPath 设置？" || return 0
    backup_all || return 1
    if ! python3 - "$CONFIG" "$DNS_META" <<'PY_DNS_DISABLE'
import datetime, json, os, pathlib, shutil, sys, tempfile
cfgp,metap=map(pathlib.Path,sys.argv[1:])
try: cfg=json.loads(cfgp.read_text(encoding='utf-8')); meta=json.loads(metap.read_text(encoding='utf-8'))
except Exception as e: raise SystemExit('配置/元数据读取失败：'+str(e))
cores=cfg.get('Cores') or []
for item in meta.get('previous',[]):
    i=item.get('index')
    if not isinstance(i,int) or i<0 or i>=len(cores) or not isinstance(cores[i],dict):
        raise SystemExit('Cores 结构已变化，无法可靠恢复原设置；未修改文件。')
    if item.get('had'): cores[i]['OriginalPath']=item.get('value')
    else: cores[i].pop('OriginalPath',None)
stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S'); bak=cfgp.with_name(cfgp.name+'.'+stamp+'.bak'); shutil.copy2(cfgp,bak); os.chmod(bak,0o600)
fd,tmp=tempfile.mkstemp(prefix='.config.',dir=str(cfgp.parent))
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f: json.dump(cfg,f,ensure_ascii=False,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o600); os.replace(tmp,cfgp)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
metap.unlink()
print('已恢复原 OriginalPath；自定义 DNS 文件保留作备份，不再被 AriNode 引用。')
print('config.json 备份：'+str(bak))
PY_DNS_DISABLE
    then red "停用失败，配置未重启。"; return 1; fi
    if confirm_yes "是否立即重启 AriNode？"; then "$ANCTL_BIN" restart; else yellow "请在合适时间重启 AriNode 使停用生效。"; fi
}

dns_install_prompt() {
    [[ -f "$CONFIG" ]] || return 0
    echo
    blue "========== 首次安装：自定义 DNS 解锁 IP =========="
    echo "与 Xboard-Node 一样，默认创建自定义 DNS 配置。"
    echo "默认 IP 为 1.1.1.1；如果万国解锁服务商提供了专用 DNS IP，请在此输入服务商地址。"
    read -e -r -p "是否创建/修改自定义 DNS [Y/n]: " answer
    if [[ "$answer" =~ ^[Nn]([Oo])?$ ]]; then
        yellow "已跳过自定义 DNS；以后可通过主菜单第 9 项设置。"
        return 0
    fi
    dns_apply
}

dns_menu() {
    require_arinode || return 1
    while true; do
        echo
        blue "========== 自定义 DNS 解锁 IP 管理 =========="
        dns_status || true
        echo
        echo "1. 设置 / 修改 DNS 解锁 IP"
        echo "2. 停用自定义 DNS（恢复原配置）"
        echo "0. 返回高级功能"
        read -e -r -p "请选择 [0-2]： " choice
        case "$choice" in
            1) dns_apply || red "DNS 设置失败。"; pause ;;
            2) dns_disable || red "停用 DNS 失败。"; pause ;;
            0) return 0 ;;
            *) red "无效选择。"; pause ;;
        esac
    done
}

# -------------------- 服务管理 --------------------
start_node()    { require_arinode && "$ANCTL_BIN" start; }
stop_node()     { require_arinode && "$ANCTL_BIN" stop; }
restart_node()  { require_arinode && "$ANCTL_BIN" restart; }
status_node() {
    if [[ -x "$ANCTL_BIN" ]]; then
        "$ANCTL_BIN" status || true
    else
        systemctl status "$SERVICE" --no-pager || true
    fi
    echo
    if command -v systemctl >/dev/null 2>&1; then
        printf '开机启动：'
        systemctl is-enabled "$SERVICE" 2>/dev/null || true
        printf '运行状态：'
        systemctl is-active "$SERVICE" 2>/dev/null || true
    fi
}
logs_node() {
    require_arinode || return 1
    echo "按 Ctrl+C 退出实时日志。"
    "$ANCTL_BIN" log
}

# -------------------- 配置管理 --------------------
backup_file() {
    local file="$1" stamp dest
    [[ -f "$file" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    stamp="$(date +%Y%m%d-%H%M%S-%N)"
    dest="${BACKUP_DIR}/$(basename "$file").${stamp}.bak"
    cp -a -- "$file" "$dest"
    chmod 600 "$dest"
    green "已备份：$dest"
}

backup_all() {
    local stamp archive
    [[ -d "$CONFIG_DIR" ]] || { red "配置目录不存在：$CONFIG_DIR"; return 1; }
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    stamp="$(date +%Y%m%d-%H%M%S-%N)"
    archive="${BACKUP_DIR}/arinode-backup-${stamp}.tar.gz"
    local -a items=()
    [[ -d "$CONFIG_DIR" ]] && items+=(etc/arinode)
    ((${#items[@]})) || { red "没有可备份的 AriNode 配置或证书。"; return 1; }
    tar -czf "$archive" -C / "${items[@]}"
    tar -tzf "$archive" >/dev/null || { rm -f "$archive"; red "备份包校验失败。"; return 1; }
    chmod 600 "$archive"
    green "备份完成并通过校验："
    echo "$archive"
    echo "备份内容：/etc/arinode/ 下的 config.json、节点配置、证书、面板缓存及其他 AriNode 配置文件。"
    echo "备份位置：/root/arinode-backups/"
}

edit_config() {
    require_arinode || return 1
    [[ -f "$CONFIG" ]] || { red "配置文件不存在：$CONFIG"; return 1; }
    require_command python3 || return 1
    local editor="${EDITOR:-nano}" tmp="${CONFIG}.edit.$$"
    command -v "$editor" >/dev/null 2>&1 || editor=vi
    cp -a -- "$CONFIG" "$tmp" || return 1
    if ! "$editor" "$tmp"; then
        rm -f -- "$tmp"
        red "编辑器退出异常，原配置未改变。"
        return 1
    fi
    if ! python3 -m json.tool "$tmp" >/dev/null; then
        rm -f -- "$tmp"
        red "JSON 格式校验失败，已丢弃临时文件；原配置保持不变。"
        return 1
    fi
    backup_file "$CONFIG" || { rm -f -- "$tmp"; return 1; }
    chmod 600 "$tmp"
    mv -f -- "$tmp" "$CONFIG"
    green "配置文件已通过 JSON 校验并保存。"
    if confirm_yes "是否立即重启 AriNode 使配置生效？"; then
        "$ANCTL_BIN" restart
    fi
}

show_config() {
    require_arinode || return 1
    [[ -f "$CONFIG" ]] || { red "配置文件不存在。"; return 1; }
    yellow "配置文件包含 Xboard Token、API Key 等敏感信息。"
    confirm_yes "确认在终端显示完整明文配置？" || return 0
    cat "$CONFIG"
}




version_upgrade_menu() {
    require_arinode || return 1
    while true; do
        echo
        blue "========== AriNode 版本与升级管理 =========="
        "$ANCTL_BIN" version 2>/dev/null || true
        echo
        echo "1. 检查官方最新版本"
        echo "2. 升级 AriNode"
        echo "0. 返回主菜单"
        read -e -r -p "请选择 [0-2]： " choice
        case "$choice" in
            1) check_upgrade || red "版本检查失败。"; pause ;;
            2) upgrade_arinode || red "升级失败。"; pause ;;
            0) return 0 ;;
            *) red "无效选择。"; pause ;;
        esac
    done
}

# -------------------- 协议 / TLS / 证书管理 --------------------
cert_manager() {
    require_arinode || return 1
    require_command python3 || return 1
    require_command sha256sum || return 1
    [[ -f "$CONFIG" ]] || { red "配置文件不存在：$CONFIG"; return 1; }
    local before after
    before="$(sha256sum "$CONFIG" | awk '{print $1}')"
    configure_tls_certificates "$CONFIG" "" manage || return 1
    after="$(sha256sum "$CONFIG" | awk '{print $1}')"
    if [[ "$before" != "$after" ]]; then
        if confirm_yes "证书配置已修改，是否立即重启 AriNode 使其生效？"; then
            "$ANCTL_BIN" restart
        else
            yellow "已保存证书配置；请稍后执行 ari-node 菜单第 4 项重启节点。"
        fi
    fi
}

# -------------------- 升级管理 --------------------
check_upgrade() {
    require_arinode || return 1
    "$ANCTL_BIN" upgrade check
}

upgrade_arinode() {
    require_arinode || return 1
    echo
    yellow "AriNode 将从官方 GitHub Release 检查并安装最新正式版。"
    echo "升级过程会校验 SHA256；配置文件不会被覆盖。"
    confirm_yes "确认升级 AriNode？" || return 0
    backup_all || return 1
    "$ANCTL_BIN" upgrade
}


# -------------------- 备份恢复 / DSOM / 高级功能 --------------------
list_backups() {
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    echo "备份目录：$BACKUP_DIR"
    find "$BACKUP_DIR" -maxdepth 1 -type f -name 'arinode-backup-*.tar.gz' -printf '%TY-%Tm-%Td %TH:%TM  %s bytes  %p\n' 2>/dev/null | sort -r || true
}

restore_backup() {
    require_arinode || return 1
    local archive
    list_backups
    echo
    read -e -r -p "请输入要恢复的备份文件完整路径：" archive
    [[ -f "$archive" && "$archive" == "$BACKUP_DIR"/arinode-backup-*.tar.gz ]] || { red "备份文件路径无效，必须位于 $BACKUP_DIR。"; return 1; }
    python3 - "$archive" <<'PY_TAR_CHECK' || return 1
import sys,tarfile
p=sys.argv[1]
try:
 with tarfile.open(p,'r:gz') as t:
  members=t.getmembers()
  if not members: raise ValueError('备份包为空')
  for m in members:
   from pathlib import PurePosixPath
   q=PurePosixPath(m.name)
   if q.is_absolute() or '..' in q.parts or not (str(q)=='etc/arinode' or str(q).startswith('etc/arinode/')):
    raise ValueError('发现不安全路径：'+m.name)
   if not (m.isfile() or m.isdir()):
    raise ValueError('备份中不允许符号链接/硬链接/特殊文件：'+m.name)
 print('备份包路径校验通过。')
except Exception as e:
 print('备份包校验失败：'+str(e),file=sys.stderr); sys.exit(1)
PY_TAR_CHECK
    confirm_yes "恢复会覆盖当前 /etc/arinode 配置。确认继续？" || return 0
    backup_all || return 1
    systemctl stop "$SERVICE" 2>/dev/null || true
    tar -xzf "$archive" -C / || { red "解包失败。"; return 1; }
    if [[ -f "$CONFIG" ]]; then
        python3 -m json.tool "$CONFIG" >/dev/null || { red "恢复后的 config.json JSON 校验失败；当前备份仍保留。"; return 1; }
    fi
    green "配置与证书恢复完成。"
    if confirm_yes "是否立即启动 AriNode？"; then "$ANCTL_BIN" start; fi
}

dsom_status() {
    require_arinode || return 1
    echo "正在读取本机 AriNode 状态 API（默认 http://127.0.0.1:18086/v1/status）……"
    "$ANCTL_BIN" dsom status --url http://127.0.0.1:18086/v1/status
}

dsom_diagnose() {
    require_arinode || return 1
    local host port attempts timeout
    read -e -r -p "请输入你有权诊断的 SOCKS5 网关主机名或 IP：" host
    [[ -n "$host" ]] || { red "主机不能为空。"; return 1; }
    read -e -r -p "请输入网关 TCP 端口：" port
    [[ "$port" =~ ^[0-9]+$ ]] && ((port>=1 && port<=65535)) || { red "端口无效。"; return 1; }
    read -e -r -p "TCP 检测次数 [10]：" attempts; attempts="${attempts:-10}"
    read -e -r -p "单次超时秒数 [5]：" timeout; timeout="${timeout:-5}"
    [[ "$attempts" =~ ^[0-9]+$ ]] && ((attempts>=1 && attempts<=50)) || { red "检测次数必须为 1–50。"; return 1; }
    [[ "$timeout" =~ ^[0-9]+$ ]] && ((timeout>=1 && timeout<=30)) || { red "超时必须为 1–30 秒。"; return 1; }
    "$ANCTL_BIN" dsom diagnose --host "$host" --port "$port" --attempts "$attempts" --timeout "$timeout"
}


advanced_menu() {
    require_arinode || return 1
    while true; do
        echo
        blue "================ AriNode 高级功能 ================"
        echo "1. 版本与升级管理"
        echo "2. 备份与恢复管理"
        echo "3. DSOM 动态 SOCKS5 出站状态 / 诊断"
        echo "4. 协议 / TLS / 证书检查"
        echo "0. 返回主菜单"
        read -e -r -p "请选择 [0-4]： " choice
        case "$choice" in
            1) version_upgrade_menu ;;
            2)
                while true; do
                    echo; blue "========== 备份与恢复管理 =========="
                    echo "1. 创建配置与证书备份"
                    echo "2. 查看已有备份"
                    echo "3. 恢复配置与证书备份"
                    echo "0. 返回高级功能"
                    read -e -r -p "请选择 [0-3]： " sub
                    case "$sub" in
                        1) backup_all || red "备份失败。"; pause ;;
                        2) list_backups; pause ;;
                        3) restore_backup || red "恢复失败。"; pause ;;
                        0) break ;;
                        *) red "无效选择。"; pause ;;
                    esac
                done
                ;;
            3)
                while true; do
                    echo; blue "========== DSOM 动态 SOCKS5 出站 =========="
                    echo "1. 查看 DSOM 运行状态"
                    echo "2. 诊断指定 SOCKS5 网关连通性"
                    echo "0. 返回高级功能"
                    echo "说明：当前 AriNode 源码提供状态查询和网关诊断；未提供在此菜单中创建/修改 SOCKS5 出站的命令。"
                    read -e -r -p "请选择 [0-2]： " sub
                    case "$sub" in
                        1) dsom_status || red "DSOM 状态读取失败；请确认服务版本和状态 API。"; pause ;;
                        2) dsom_diagnose || red "DSOM 诊断失败。"; pause ;;
                        0) break ;;
                        *) red "无效选择。"; pause ;;
                    esac
                done
                ;;
            4) cert_manager || red "证书检查/配置失败。"; pause ;;
            0) return 0 ;;
            *) red "无效选择。"; pause ;;
        esac
    done
}

# -------------------- 卸载 --------------------
uninstall_arinode() {
    echo
    red "========== 卸载 AriNode =========="
    echo "将停止并禁用 AriNode 服务，删除 AriNode 主程序、anctl、systemd 服务文件及 ari-node 管理命令。"
    echo "保留配置/证书目录：$CONFIG_DIR"
    echo "保留备份目录：$BACKUP_DIR"
    echo
    read -e -r -p "确认卸载请输入大写 YES： " confirm
    [[ "$confirm" == "YES" ]] || { yellow "已取消卸载。"; return 0; }
    if [[ -d "$CONFIG_DIR" ]]; then backup_all || { red "备份失败，已中止卸载。"; return 1; }; fi
    if [[ -x "$ANCTL_BIN" ]]; then
        "$ANCTL_BIN" upgrade auto disable >/dev/null 2>&1 || true
    fi
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f -- "/etc/systemd/system/${SERVICE}"
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    rm -f -- "$ARINODE_BIN" "$ANCTL_BIN" "$MANAGER_BIN" "$MANAGER_CONFIG"
    if [[ -f "$LEGACY_MANAGER_BIN" ]] && grep -q 'AriNode 安装与管理脚本' "$LEGACY_MANAGER_BIN"; then rm -f -- "$LEGACY_MANAGER_BIN"; fi
    green "AriNode 程序、服务文件及 ari-node 管理命令已卸载。"
    echo "配置和证书仍保留：$CONFIG_DIR"
    echo "备份仍保留：$BACKUP_DIR"
}

# -------------------- 菜单 --------------------
show_menu() {
    clear 2>/dev/null || true
    echo
    blue "=================================================="
    blue "                 AriNode 节点管理面板"
    blue "=================================================="
    echo "程序目录：$BIN_DIR"
    echo "配置文件：$CONFIG"
    echo "备份目录：$BACKUP_DIR"
    if is_installed; then
        green "安装状态：已安装"
        printf '服务状态：'
        if systemctl is-active --quiet "$SERVICE"; then green "运行中"; else yellow "未运行"; fi
        printf '当前版本：'; "$ANCTL_BIN" version 2>/dev/null || echo "未知"
    else
        yellow "安装状态：未完整安装"
    fi
    echo
    echo " 1. 安装 AriNode"
    echo " 2. 启动节点"
    echo " 3. 停止节点"
    echo " 4. 重启节点"
    echo " 5. 查看运行状态"
    echo " 6. 查看实时日志"
    echo " 7. 查看 config.json"
    echo " 8. 编辑 config.json"
    echo " 9. 自定义 DNS 解锁 IP"
    echo "10. 高级功能"
    echo "11. 卸载 AriNode"
    echo " 0. 退出"
    echo
}

main_menu() {
    require_root || exit 1
    check_platform || exit 1
    load_manager_config
    while true; do
        show_menu
        read -e -r -p "请输入操作编号 [0-11]： " choice || exit 0
        case "$choice" in
            1)
                if install_arinode; then install_manager_command || red "管理命令安装失败。"; else red "安装未完成，请检查上方输出。"; fi
                pause ;;
            2) start_node || red "启动失败。"; pause ;;
            3) stop_node || red "停止失败。"; pause ;;
            4) restart_node || red "重启失败。"; pause ;;
            5) status_node; pause ;;
            6) logs_node || red "日志查看结束或失败。"; pause ;;
            7) show_config || red "查看配置失败。"; pause ;;
            8) edit_config || red "编辑或校验配置失败。"; pause ;;
            9) dns_menu || red "DNS 管理失败。"; pause ;;
            10) advanced_menu || red "高级功能菜单异常退出。"; pause ;;
            11) uninstall_arinode; pause ;;
            0) exit 0 ;;
            *) red "无效选项。"; pause ;;
        esac
    done
}

# -------------------- 入口 --------------------
main() {
    require_root || exit 1
    check_platform || exit 1
    load_manager_config

    case "${1:-menu}" in
        menu)
            main_menu
            ;;
        install)
            install_arinode && install_manager_command
            ;;
        start) start_node ;;
        stop) stop_node ;;
        restart) restart_node ;;
        status) status_node ;;
        log|logs) logs_node ;;
        backup) backup_all ;;
        dns) dns_menu ;;
        upgrade-check) check_upgrade ;;
        upgrade) upgrade_arinode ;;
        cert-check|cert-config) cert_manager ;;
        *)
            echo "用法："
            echo "  bash AriNode.sh                 打开管理菜单"
            echo "  bash AriNode.sh install         安装 / 初始化 AriNode"
            echo "  bash AriNode.sh status          查看服务状态"
            echo "  bash AriNode.sh backup          备份配置与证书"
            echo "  bash AriNode.sh dns             自定义 DNS 解锁 IP 管理"
            echo "  bash AriNode.sh upgrade-check   检查官方版本"
            echo "  bash AriNode.sh upgrade         升级 AriNode"
            echo "  bash AriNode.sh cert-check      自动识别协议 / TLS / 证书配置"
            exit 1
            ;;
    esac
}

main "$@"
