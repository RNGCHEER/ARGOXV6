# 【ArgoXV6】 = ArgoX + IPv4/IPv6 分栈代理协议管理

中文 | [English](README_EN.md)

> 在已部署 ArgoX 的服务器上，为 IPv4 设备与 IPv6 设备分别设置独立的代理协议 / 端口 / 凭据。解决 ArgoX 只能双栈共用一套入站协议的限制。

---

## 目录

- [更新信息](#更新信息)
- [项目特点](#项目特点)
- [前置条件](#前置条件)
- [快速开始](#快速开始)
- [菜单与命令行](#菜单与命令行)
- [支持的协议](#支持的协议)
- [工作原理](#工作原理)
- [主体目录文件及说明](#主体目录文件及说明)
- [常见问题](#常见问题)
- [感谢](#感谢)
- [免责声明](#免责声明)
- [许可证](#许可证)

---

## 更新信息

- **v1.0.1 (2026.10.31)**：协议字母支持一次输入多个批量添加（如 `bcdlm`，`a` 或回车 = 全部），与 ArgoX 的解析习惯一致；未安装 ArgoX 时可选一键安装（调用 ArgoX 官方脚本）；修复端口冲突检测的字段比较错误（同栈批量添加会重复推荐同一端口）。
- **v1.0.0 (2026.10.31)**：首个版本。支持为 IPv4 / IPv6 分栈添加独立代理协议入站；同端口可按栈区分协议；复用 ArgoX 的 Reality 密钥对与自签证书；分栈防火墙放行；Xray 服务集成与卸载还原。

---

## 项目特点

**ArgoX 的限制**：[ArgoX](https://github.com/fscarmen/ArgoX) 的所有直连协议入站均不设置 listen 字段，即同时监听 IPv4(0.0.0.0) 与 IPv6(::) 双栈；WS/XHTTP 类入站固定监听 127.0.0.1 走 Argo 隧道。订阅链接的服务器地址也只能填一个。因此无法为 IPv4 设备和 IPv6 设备指定不同的代理协议。

**ArgoXV6 的做法**：在 ArgoX 之上追加第三个 Xray 配置文件 argoxv6.json，把新增入站**精确绑定到服务器的 IPv6 地址或 IPv4 地址**（listen 设为具体地址）。于是：

- IPv6 设备走「IPv6 侧」的独立协议 / 独立端口 / 独立凭据；
- IPv4 设备走「IPv4 侧」的独立协议（或继续用 ArgoX 原有节点）；
- 即使**同一端口**也能按栈区分协议（v6 绑具体 IPv6 地址、v4 绑具体 IPv4 地址，两个 socket 互不冲突）；
- 完全不改动 ArgoX 原有入站 / 出站 / 防火墙，随时可卸载还原。

---

## 前置条件

- 一台已安装并正常运行 [ArgoX](https://github.com/fscarmen/ArgoX) 的服务器（Linux，systemd 或 Alpine OpenRC）。
- 服务器具备公网 IPv4 与 / 或 IPv6 地址（脚本自动探测，也可手动指定）。
- root 权限。

---

## 快速开始

~~~bash
bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
~~~

或者使用 curl：

~~~bash
bash <(curl -fsSL https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
~~~

一条命令即可交互式运行（与 ArgoX 相同的调用方式），无需下载保存。命令行参数同样适用，例如修复集成：

~~~bash
bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh) -r
~~~

首次进入会自动探测公网 IPv4 / IPv6 地址，然后进入菜单。为 IPv6 设备添加协议只需选菜单 1，为 IPv4 设备添加协议选菜单 2。如果服务器还没有安装 ArgoX，脚本会提示并可一键安装 ArgoX（调用 ArgoX 官方安装脚本）后继续。

选择协议时与 ArgoX 的输入习惯一致：**支持一次输入多个字母批量添加**（如 `bcdlm`），`a` 或直接回车 = 全部添加；逐个确认端口（回车用推荐值，同栈自动错开）后一次性重建配置并重启 Xray。

---

## 菜单与命令行

交互式菜单：

| 选项 | 功能 |
| --- | --- |
| 1 | 为 IPv6 设备添加 / 更换代理协议 |
| 2 | 为 IPv4 设备添加 / 更换代理协议 |
| 3 | 查看节点链接（分栈输出） |
| 4 | 删除某个协议 |
| 5 | 重新检测公网 IP 并更新监听地址 |
| 6 | 修复 Xray 服务集成（ArgoX 升级 / 重装后执行） |
| 7 | 卸载 argoxv6 |
| 0 | 退出 |

命令行参数：

| 参数 | 功能 |
| --- | --- |
| -r | 仅修复 Xray 服务集成 |
| -l | 仅显示节点链接 |
| -u | 卸载 argoxv6 |

---

## 支持的协议

协议字母沿用 ArgoX 的命名习惯：

| 字母 | 协议 | 传输 | 说明 |
| --- | --- | --- | --- |
| b | VLESS + Reality Vision | TCP | 复用 ArgoX 的 Reality 密钥对 |
| d | VLESS + Reality gRPC | gRPC | 复用 ArgoX 的 Reality 密钥对 |
| c | Hysteria2 | UDP/QUIC | 自签证书 |
| k | VLESS + XHTTP HTTP/3 Direct | QUIC | TLS 自签证书 |
| l | Trojan Direct | TCP | TLS 自签证书 |
| m | Shadowsocks 2022 Direct | TCP/UDP | 2022-blake3-aes-128-gcm |

---

## 工作原理

1. **独立配置文件**：在 ArgoX 的 $WORK_DIR（默认 /etc/argox）下新增 argoxv6.json，通过 Xray 的多配置合并机制加载（xray run -c inbound.json -c outbound.json -c argoxv6.json），三份配置的 inbounds 合并，互不影响。
2. **按栈绑定监听**：新增入站的 listen 字段被设为具体的 IPv6 或 IPv4 公网地址，从而只在该栈上监听。同一端口在两个栈上各自绑定不同地址，socket 不冲突。
3. **复用 ArgoX 资产**：Reality 协议自动复用 ArgoX 的 privateKey / publicKey / serverNames；TLS 协议复用或生成自签证书（/etc/argox/cert）。
4. **分栈防火墙**：ufw / firewalld / iptables + ip6tables 按栈放行对应端口，iptables 规则带 ArgoxV6 注释标记，持久化复用 ArgoX 的 rules.v4 / rules.v6。
5. **服务集成**：给 xray.service 的 ExecStart（或 OpenRC command_args）追加 -c argoxv6.json；ArgoX 升级重装后用菜单 6 一键修复。

---

## 主体目录文件及说明

| 文件 | 说明 |
| --- | --- |
| /etc/argox/argoxv6.json | argoxv6 生成的分栈入站配置 |
| /etc/argox/argoxv6.conf | argoxv6 自身状态（IP、端口、UUID 等，key=value） |
| /etc/argox/cert/cert.pem、private.key | 自签证书（复用或生成） |
| /etc/systemd/system/xray.service | Xray 服务单元，被追加 -c argoxv6.json |

---

## 常见问题

**Q：ArgoX 升级 / 重装后 argoxv6 节点失效？**
执行 bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh) -r 或菜单 6，重新把 argoxv6.json 集成进 Xray 服务。

**Q：能否为 IPv4 和 IPv6 用同一个端口但不同协议？**
可以。argoxv6 会把 v6 入站绑到具体 IPv6 地址、v4 入站绑到具体 IPv4 地址，两个 socket 互不冲突。

**Q：卸载会影响 ArgoX 原有节点吗？**
不会。卸载仅删除 argoxv6 新增的入站、还原 xray 服务、关闭对应防火墙端口，ArgoX 的 inbound.json / outbound.json 原样保留。

**Q：只有 IPv4（或只有 IPv6）公网地址怎么办？**
脚本会提示只能为存在的栈设置独立协议。

---

## 感谢

- [fscarmen/ArgoX](https://github.com/fscarmen/ArgoX)：ArgoX 项目，本辅助脚本在其基础上工作。
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)：Xray 内核。

---

## 免责声明

本脚本仅供学习与研究使用，请遵守当地法律法规。使用本脚本所产生的一切后果由使用者自行承担。本项目与 ArgoX 及其作者无关。

---

## 许可证

本项目采用 [GPL-3.0](LICENSE) 许可证，与上游 [ArgoX](https://github.com/fscarmen/ArgoX) 一致。
