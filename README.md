# ArgoXV6 v2

**ArgoX 只管 IPv4，argoxv6 只管 IPv6 —— 互不干扰的 ArgoX 双栈助手；也支持「双栈添加」一次同时输出 V4 + V6 节点**

> **v2.1.2 修复**：IPv6 地址探测不再「抓到哪个算哪个」——按内核出站源地址 → 默认网卡公网 GUA → 全网卡兜底取地址，跳过隐私扩展的临时地址；节点链接的主机默认就用**你实际监听的地址**。并新增 `-d` 诊断（本机全部 IPv6 / 出站源地址 / 在线探测结果 / conf 值一次打全）。
>
> **v2.1.0 新增**：菜单 3 / `-b` 双栈添加（同一协议同时绑 IPv4 0.0.0.0 与 IPv6，可复用同一端口，两个节点链接一起出）；菜单 4 / `-l` 按栈同时列出 V4+V6 全部节点并附**含全部节点的 Base64 订阅**；删除支持 `4 / 6 / b`。

[![License](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Based on](https://img.shields.io/badge/基于-fscarmen%2FArgoX-orange.svg)](https://github.com/fscarmen/ArgoX)
[![Platform](https://img.shields.io/badge/系统-Linux%20%7C%20systemd%20%7C%20OpenRC-green.svg)](#)
[![Version](https://img.shields.io/badge/版本-v2.1.2-brightgreen.svg)](#)

> 这是 [RNGCHEER/ARGOXV6](https://github.com/RNGCHEER/ARGOXV6) v1.0.x 的重写版本。
> 旧版会与 ArgoX 互相破坏（详见 [为什么旧版会把 ArgoX 搞坏](#为什么旧版会把-argox-搞坏)）；v2.0.0 从架构上彻底解耦：**任一侧出问题，另一侧照常运行**。

中文 | [English](README_EN.md)

---

## 目录

- [一命令安装](#一命令安装)
- [它能做什么](#它能做什么)
- [为什么旧版会把 ArgoX 搞坏](#为什么旧版会把-argox-搞坏)
- [新版架构](#新版架构)
- [快速开始](#快速开始)
- [菜单与命令行](#菜单与命令行)
- [支持的协议](#支持的协议ipv6-侧双栈添加时同样用于-ipv4-侧)
- [文件清单](#文件清单)
- [环境变量](#环境变量)
- [常见问题](#常见问题)
- [卸载](#卸载)
- [新旧版本对照](#新旧版本对照)
- [感谢](#感谢)
- [免责声明](#免责声明)
- [许可证](#许可证)

---

## 一命令安装

在**已安装 [ArgoX](https://github.com/fscarmen/ArgoX)** 的服务器上执行：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
```

或使用 curl：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
```

> 没装 ArgoX？脚本会检测到并询问是否直接调用 ArgoX 官方脚本安装，装完自动继续。

---

## 它能做什么

- **ArgoX（v4 侧）**：把 ArgoX 直连入站的 `listen` 钉成 `0.0.0.0`，只监听 IPv4（WS / XHTTP 隧道类 `127.0.0.1` 入站一律不碰）。
- **argoxv6（v6 侧）**：为 IPv6 设备提供独立的协议 / 端口 / 凭据（Reality、Hysteria2、gRPC、XHTTP-H3、Trojan、SS2022）。
- **菜单 1 直接调用 ArgoX**：管理 v4 节点不用退出本脚本，退出后自动同步。
- **双栈添加（菜单 3 / `-b`）**：v4 侧由 argoxv6 直接建入站（`listen 0.0.0.0`），v6 侧绑本机 IPv6，同一协议两个节点、链接与订阅一次给全，ArgoX 依旧不受影响。
- **IPv6 地址自愈**：VPS 换 IPv6 前缀后，重启 Xray 即自动校正监听地址。
- **开机守护**：systemd drop-in（带 `-` 前缀，hook 失效也绝不阻塞 Xray 启动）/ OpenRC 独立服务。
- **幂等热挂载**：v6 入站经 Xray gRPC API 挂载，配置哈希没变就不发一条指令，不反复断连。
- **干净卸载**：API 摘入站 + 删 drop-in + 关端口，ArgoX 零残留。

---

## 为什么旧版会把 ArgoX 搞坏

对着 `argox.sh` v2.2.0 源码逐条定位的结论（不是猜测）：

| # | 旧版做法 | 后果 | argox.sh 位置 |
|---|---|---|---|
| 1 | `sed` 改 `xray.service` 的 `ExecStart`，尾部追加 `-c argoxv6.json` | ArgoX 每次装 / 换协议都会重写 service 文件，追加段被抹掉；反向：argoxv6.json 一旦坏 / 丢，**Xray 直接起不来 → ArgoX 全部节点失效** | `write_xray_daemon()` 约 805 行，调用点约 5368 行 |
| 2 | v6 入站 `listen` 写死具体 IPv6 地址 | IPv6 前缀一变，bind 失败 → **整个 Xray 起不来** | 旧版 `build_block()` |
| 3 | 不做防御 | `api_hot_reload inbounds` 会 rmi 掉不在 `inbound.json` 里的 tag，**v6 入站每次被清空** | 约 1005–1103、5382 行 |
| 4 | v4 入站绑死具体 IPv4 地址 | IPv4 一变就跟着挂 | 旧版 `add_protocol 4` |

**根因一句话：旧版把"可选功能"塞进了"必经启动路径"。**

---

## 新版架构

```
                 ┌──────────────────────────────┐
  v4 设备 ─────▶ │ ArgoX inbound.json           │  直连入站 listen = 0.0.0.0
                 │  (reality / hy2 / trojan…)   │  ← 只监听 IPv4
                 └──────────────┬───────────────┘
                                │  同一个 xray 进程
                 ┌──────────────┴───────────────┐
  v6 设备 ─────▶ │ argoxv6.json                 │  listen = 本机公网 IPv6
                 │  (由 xray api adi 热挂载)     │  ← 只监听 IPv6
                 └──────────────────────────────┘
                                │
                 systemd drop-in（可选，"-" 前缀忽略失败）：
                 ExecStartPre=-hook pre    钉 v4-only + 校正 v6 地址
                 ExecStartPost=-hook post  用 API 把 v6 挂回来
```

三条设计原则：

1. **绝不碰 `ExecStart`** —— v6 入站走 Xray 原生 gRPC API（`adi` / `rmi`）热挂载，失败只影响 v6 自己。
2. **失败必须隔离** —— v6 配置写坏、地址失效、文件丢失，最多 v6 节点没了，ArgoX 的 v4 一定还在。
3. **幂等 + 可回滚** —— 配置哈希没变就不动，卸载可完整还原 ArgoX 双栈。

---

## 快速开始

```bash
bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
```

首次运行自动探测公网 IPv4 / IPv6（无公网 IPv6 时会明确提示且不碰 ArgoX）。典型流程：

1. **菜单 1**：进入 ArgoX 添加 / 修改 IPv4 节点，退出后自动同步；
2. **菜单 2**：为 IPv6 设备添加协议（支持 `bcdlm` 批量输入，`a` 或回车 = 全部）；
3. **菜单 3**：双栈添加 —— 同一协议同时出 IPv4 + IPv6 节点（可复用同一端口）；
4. **菜单 4**：按栈查看 IPv4 + IPv6 全部节点链接，并给出含全部节点的 Base64 订阅，复制到客户端即可。

---

## 菜单与命令行

| 菜单 | 功能 |
|---|---|
| 1 | 管理 IPv4 节点（调用 ArgoX 官方脚本，退出自动同步） |
| 2 | 为 IPv6 添加 / 更换协议 |
| 3 | **双栈添加：同一协议同时出 IPv4 + IPv6 节点** |
| 4 | **查看节点链接（IPv4 + IPv6，含 Base64 订阅）** |
| 5 | 删除某个协议（栈可选 `4` / `6` / `b`） |
| 6 | 一键同步 / 自检修复 |
| 7 | 重新探测 IPv6 地址 |
| 8 | 查看当前状态（含每个入站是否真的挂载） |
| 9 | 卸载 |
| 0 | 退出 |

### 端口规则

- **单个协议**：在端口提示里直接输入想要的端口即可（如 `65000`）；回车 = 用推荐值（35000 起自动错开）。
- **批量协议**（`bcdlm` 或 `a`）：先问**一个起始端口**，其余协议按顺序顺延 ——
  例：起始 `12300` → `b`=12300、`c`=12301、`d`=12302 …；被占用的端口**自动跳过并提示**（12300 被占 → 该协议用 12301，后续继续 12302）。
- 双栈添加时，**同一个起始端口同时用于 IPv4 和 IPv6**，两个节点共用端口号，后续协议同样顺延。
- 端口一律避开 ArgoX 已占用端口与本机同地址族监听，并限制在 1–65535。

命令行参数：

```bash
bash argoxv6.sh                # 交互菜单
bash argoxv6.sh -s             # 同步 / 自检修复
bash argoxv6.sh -b             # 直接进入双栈添加（同一协议同时出 IPv4 + IPv6）
bash argoxv6.sh -b -p 12300    # 双栈添加并指定起始端口：12300、12301、12302… 依次顺延
bash argoxv6.sh -l             # 同时输出 IPv4 + IPv6 全部节点链接（含 Base64 订阅）
bash argoxv6.sh -u             # 卸载
bash argoxv6.sh -d             # 诊断 IPv6 地址（本机全部地址 / 出站源地址 / 在线探测 / conf）
bash argoxv6.sh -6 2001:db8::1 # 手动指定 IPv6 地址（监听 + 链接都用它；NAT66 / 多地址场景）
bash argoxv6.sh -p 65000 -b    # -p 可与 -b / 菜单任意组合
bash argoxv6.sh -v             # 版本
bash argoxv6.sh -h             # 帮助（打印脚本头部说明）
```

---

## 支持的协议（IPv6 侧；双栈添加时同样用于 IPv4 侧）

| 字母 | 协议 | 传输 | 说明 |
|---|---|---|---|
| b | VLESS + Reality Vision | TCP | 复用 ArgoX 的 Reality 密钥与 SNI |
| c | Hysteria2 | UDP/QUIC | 复用 / 生成自签证书 |
| d | VLESS + Reality gRPC | gRPC | 同上（复用 Reality 密钥） |
| k | VLESS + XHTTP HTTP/3 Direct | QUIC | 自签证书 |
| l | Trojan Direct | TCP | 自签证书 |
| m | Shadowsocks 2022 | TCP/UDP | 2022-blake3-aes-128-gcm |

端口默认从 **35000** 起自动错开，强制避开 ArgoX 已占用端口及本机其他监听。双栈添加时同一个端口会同时用在 IPv4（`0.0.0.0`）与 IPv6 上 —— 两侧地址族不同，socket 互不冲突。

---

## 文件清单

| 路径 | 说明 |
|---|---|
| `/etc/argox/argoxv6.json` | v6 入站配置（只被 API 读取，不参与 Xray 启动） |
| `/etc/argox/argoxv6.conf` | 自身状态：绑定地址、端口 / UUID / 密码 |
| `/etc/argox/argoxv6-hook.sh` | 开机钩子，`pre` / `post` 两个动作，永远 `exit 0` |
| `/etc/systemd/system/xray.service.d/50-argoxv6.conf` | 仅两行带 `-` 前缀的 ExecStartPre / Post |
| `/etc/init.d/argoxv6` | OpenRC 系统的独立守护服务 |
| `/etc/argox/cert/` | 自签证书（ArgoX 没有时生成） |
| `/etc/argox/argoxv6.d/argox.sh` | ArgoX 主脚本缓存（菜单 1 用） |

ArgoX 自身的 `inbound.json` / `outbound.json` / `xray.service` **一个都不改写**（v4 侧只调整 `listen` 字段，且绝不碰 `127.0.0.1` 入站）。

---

## 环境变量

测试 / 特殊场景下可用环境变量覆盖默认路径：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `ARGOX_DIR` | `/etc/argox` | ArgoX 工作目录 |
| `SYSTEMD_DIR` | `/etc/systemd/system` | systemd 单元目录 |
| `INITD_DIR` | `/etc/init.d` | OpenRC 服务目录 |
| `ARGOXV6_FLAG` | `/run/argoxv6.need-restart` | 重启标记文件 |

---

## 常见问题

**Q：ArgoX 升级 / 重装后要重新修复吗？**
不需要。drop-in 是独立文件，ArgoX 重写 `xray.service` 冲不掉它。极端情况（unit 被整体删除重建）也只需菜单 6（同步/自检修复）。

**Q：在 ArgoX 里改协议，v6 节点会掉线吗？**
ArgoX 的热更新只认自己 `inbound.json` 里的 tag，会顺带清掉 v6 入站——所以请从**菜单 1** 进 ArgoX（退出自动重挂）；若直接跑了 `argox.sh`，回来点**菜单 6**（同步）即可。

> **Q：节点里的 IPv6 地址不对（比如机器是 `...::1015`，链接却写成 `...::1`）/ 客户端连不上？**
先跑 `bash argoxv6.sh -d` 看诊断：
- 「本机全局 IPv6 地址」里会列出网卡上的全部地址，并标出临时地址（隐私扩展生成、会变，不能用来 bind）；
- 「出站源地址」是内核实际用这个地址对外通信的那一个，通常就是客户端该连的地址；
- 「当前监听地址 / 链接显示地址」若与预期不符，用 `-6 <地址>` 强制指定（监听和链接会同时改），再 `-s` 同步一次即可。
**Q：VPS 换了 IPv6 前缀怎么办？**
什么都不用做。hook 在每次 Xray 启动时重新探测地址，不一致就自动改写配置，重启一次自愈。

**Q：WS / XHTTP（隧道类）节点能按栈隔离吗？**
不能。它们由 Cloudflare 边缘接入回源 `127.0.0.1`，v4 / v6 设备都能用——这是 Argo 隧道本身的特性，非脚本限制。可分栈的只有直连协议。

**Q：隧道 / v4 入站会不会被误改？**
不会。v4 加固只改 `listen` 一个字段且绝不碰 `127.0.0.1`；生成失败自动放弃并保持 ArgoX 原样。

**Q：只有 IPv4 没有 IPv6 怎么办？**
脚本会明确提示 v6 侧不可用，不产生任何配置，ArgoX 照常使用。

**Q：开机守护装了有什么用？**
装了：服务器重启后 v6 入站自动挂回来（推荐）。不装：只本次生效，重启后需再跑一次 `argoxv6.sh -s`。

---

## 卸载

菜单 9 或 `bash argoxv6.sh -u`：

1. API 摘除全部 v6 入站；
2. 移除 drop-in / OpenRC 服务；
3. 关闭 v6 防火墙端口；
4. 可选还原 ArgoX 原生双栈；
5. 删除自身文件。

ArgoX 配置原样保留。

---

## 新旧版本对照

| 项目 | v1.0.x（旧） | v2.0.0（本版） |
|---|---|---|
| 集成方式 | 改 `ExecStart` 追加 `-c` | Xray API 热挂载 + `-` 前缀 drop-in |
| v6 配置写坏 | **整个 Xray 起不来** | 只丢 v6 节点 |
| ArgoX 改协议 | 集成被抹掉 / v6 被清空 | 自动重新挂回 |
| IPv6 地址变化 | **整个 Xray 起不来** | 启动时自动校正 |
| v4 侧 | 绑死具体 IPv4 | 钉 `0.0.0.0`，IPv4 变了也没事 |
| 调用 ArgoX | 无 | 菜单 1 直进，退出自动同步 |
| 重复执行 | 每次重启 Xray | 配置没变一个指令都不发 |
| 卸载 | 还原 service 文件 | 删 drop-in + API 摘入站，零残留 |

---

## 感谢

- [fscarmen/ArgoX](https://github.com/fscarmen/ArgoX) —— ArgoX 项目，本脚本在其之上工作
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) —— Xray 内核

---

## 免责声明

本脚本仅供学习与研究使用，请遵守当地法律法规。使用本脚本所产生的一切后果由使用者自行承担。本项目与 ArgoX 及其作者无关。

---

## 许可证

[GPL-3.0](LICENSE)，与上游 ArgoX 一致。
