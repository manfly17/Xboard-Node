# Xboard-Node

[Xboard](https://github.com/cedar2025/Xboard) 的节点后端，支持 `sing-box` / `xray-core` 双核心。

> **免责声明**：本项目仅用于教育和学习目的。

## 功能特性

- **协议支持**：V2Ray 系列协议、Trojan、Shadowsocks、Hysteria2、TUIC、AnyTLS
- **数据同步**：WebSocket 推送 + REST API 轮询双通道同步
- **用户管理**：速率限制、设备数量限制、在线 IP 追踪、配置热更新
- **部署模式**：节点模式（Node）、机器模式（Machine）、独立模式（Standalone）
- **多实例支持**：单个进程可同时绑定多个面板和多个节点

## 安装

### 系统依赖安装脚本

用于安装和检查 Linux 系统运行环境所需的依赖组件。

#### 下载并运行

```bash
curl -fsSL https://raw.githubusercontent.com/manfly17/Xboard-Node/refs/heads/dev/install-deps.sh \
  -o /root/install-deps.sh &&
chmod +x /root/install-deps.sh &&
bash /root/install-deps.sh
```

### Xboard-Node 管理脚本

交互式管理脚本，用于简化 Xboard-Node 的安装、部署和日常维护。

#### 下载并安装

```bash
curl -fsSL https://raw.githubusercontent.com/manfly17/Xboard-Node/refs/heads/dev/xboard-node.sh \
  -o /root/xboard-node.sh &&
chmod +x /root/xboard-node.sh &&
ln -sfn /root/xboard-node.sh /usr/local/bin/xbnode &&
/root/xboard-node.sh install
```

#### 再次运行

安装完成后，可直接使用以下命令启动管理菜单：

```bash
xbnode
```

### Docker 部署

```bash
docker run -d --restart=always --network=host \
  -e apiHost=https://panel.com -e apiKey=TOKEN -e nodeID=1 \
  ghcr.io/cedar2025/xboard-node:latest
```

### Docker Compose 部署

```bash
git clone -b compose --depth 1 https://github.com/cedar2025/xboard-node.git
cd xboard-node
vim config/config.yml   # 配置 panel.url、token、node_id
docker compose up -d
```

### Linux systemd 安装程序

#### 节点模式（Node Mode）

```bash
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | \
  sudo bash -s -- --mode node --panel https://panel.example.com --token TOKEN --node-id 1
```

#### 机器模式（Machine Mode）

```bash
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | \
  sudo bash -s -- --mode machine --panel https://panel.example.com --token TOKEN --machine-id 1
```

## xbctl 命令行管理工具

安装完成后，可使用 `xbctl` 查看帮助和管理实例。

常用命令：

```bash
xbctl list                          # 列出所有实例
xbctl status                        # 查看运行状态
xbctl bind add-node --panel URL --token TOKEN --node-id 1
                                    # 添加节点绑定
xbctl bind add-machine --panel URL --token TOKEN --machine-id 1
                                    # 添加机器绑定
xbctl bind remove-node --panel URL --node-id 1
                                    # 移除节点绑定
xbctl service restart               # 重启服务
```

## 配置说明

完全兼容旧版单面板配置格式。追加新的绑定配置后，会自动迁移为 `instances` 多实例配置格式。

详细配置请参考项目中的 `config.yml.example` 文件。

## 扩展功能

- **自定义路由规则**：[docs-custom-routes.md](docs-custom-routes.md)
- **自定义出站配置**：[docs-custom-outbounds.md](docs-custom-outbounds.md)
- **DNS 服务商配置（ACME DNS-01）**：[docs-dns-providers.md](docs-dns-providers.md)

## 开源协议

本项目采用 [MPL-2.0](https://www.mozilla.org/en-US/MPL/2.0/) 开源协议。
