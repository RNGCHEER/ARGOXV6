# 【ArgoXV6】 = ArgoX + Per-Stack Proxy Protocol for IPv4/IPv6

[中文](README.md) | English

> On a server already running ArgoX, set independent proxy protocols / ports / credentials separately for IPv4 and IPv6 devices. Solves ArgoX's limitation of sharing one inbound protocol across both stacks.

---

## Contents

- [Updates](#updates)
- [Highlights](#highlights)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Menu & Command Line](#menu--command-line)
- [Supported Protocols](#supported-protocols)
- [How It Works](#how-it-works)
- [Files](#files)
- [FAQ](#faq)
- [Credits](#credits)
- [Disclaimer](#disclaimer)
- [License](#license)

---

## Updates

- **v1.0.0 (2026.10.31)**: First release. Add independent proxy-protocol inbounds per stack (IPv4/IPv6); same port can carry different protocols on different stacks; reuses ArgoX's Reality key pair and self-signed certificate; per-stack firewall rules; Xray service integration and clean uninstall.

---

## Highlights

**ArgoX's limitation**: all direct inbound protocols in [ArgoX](https://github.com/fscarmen/ArgoX) leave the listen field unset, so they listen on both IPv4 (0.0.0.0) and IPv6 (::). WS/XHTTP inbounds are pinned to 127.0.0.1 behind an Argo tunnel. The subscription server address is a single value. So there is no way to give IPv4 and IPv6 devices different proxy protocols.

**What ArgoXV6 does**: it adds a third Xray config file (argoxv6.json) on top of ArgoX and binds new inbounds **exactly to the server's IPv6 or IPv4 address** (listen set to a concrete address). As a result:

- IPv6 devices use the "IPv6 side" protocol / port / credentials;
- IPv4 devices use the "IPv4 side" protocol (or keep using ArgoX's original nodes);
- even the **same port** can carry different protocols per stack (v6 binds a specific IPv6 address, v4 binds a specific IPv4 address; the two sockets do not conflict);
- ArgoX's original inbounds / outbounds / firewall are untouched and can be uninstalled at any time.

---

## Requirements

- A server with [ArgoX](https://github.com/fscarmen/ArgoX) installed and running (Linux, systemd or Alpine OpenRC).
- Public IPv4 and/or IPv6 address (auto-detected, or set manually).
- Root privileges.

---

## Quick Start

~~~bash
bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
~~~

Or with curl:

~~~bash
bash <(curl -fsSL https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
~~~

One command runs it interactively (same invocation style as ArgoX), no download needed. Command-line flags work the same way, e.g. repair integration:

~~~bash
bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh) -r
~~~

On first run it auto-detects public IPv4/IPv6 addresses and shows the menu. Use menu 1 to add a protocol for IPv6 devices, menu 2 for IPv4 devices.

---

## Menu & Command Line

Interactive menu:

| Option | Function |
| --- | --- |
| 1 | Add / replace proxy protocol for IPv6 devices |
| 2 | Add / replace proxy protocol for IPv4 devices |
| 3 | Show node links (grouped per stack) |
| 4 | Delete a protocol |
| 5 | Re-detect public IP and update listen addresses |
| 6 | Repair Xray service integration (after ArgoX upgrade/reinstall) |
| 7 | Uninstall argoxv6 |
| 0 | Exit |

Command line flags:

| Flag | Function |
| --- | --- |
| -r | Only repair Xray service integration |
| -l | Only show node links |
| -u | Uninstall argoxv6 |

---

## Supported Protocols

Protocol letters follow ArgoX's naming:

| Letter | Protocol | Transport | Notes |
| --- | --- | --- | --- |
| b | VLESS + Reality Vision | TCP | Reuses ArgoX's Reality key pair |
| d | VLESS + Reality gRPC | gRPC | Reuses ArgoX's Reality key pair |
| c | Hysteria2 | UDP/QUIC | Self-signed certificate |
| k | VLESS + XHTTP HTTP/3 Direct | QUIC | TLS self-signed certificate |
| l | Trojan Direct | TCP | TLS self-signed certificate |
| m | Shadowsocks 2022 Direct | TCP/UDP | 2022-blake3-aes-128-gcm |

---

## How It Works

1. **Independent config file**: argoxv6.json is added under ArgoX's $WORK_DIR (default /etc/argox) and loaded through Xray's multi-config merge (xray run -c inbound.json -c outbound.json -c argoxv6.json). The inbounds of all three files merge without affecting each other.
2. **Per-stack listen binding**: the listen field of new inbounds is set to a concrete IPv6 or IPv4 public address, so it only serves that stack. The same port on two stacks binds different addresses — the sockets do not conflict.
3. **Reuses ArgoX assets**: Reality reuses ArgoX's privateKey / publicKey / serverNames; TLS reuses or generates a self-signed certificate (/etc/argox/cert).
4. **Per-stack firewall**: ufw / firewalld / iptables + ip6tables open the matching port per stack; iptables rules carry ArgoxV6 comment marks and persist via ArgoX's rules.v4 / rules.v6.
5. **Service integration**: appends -c argoxv6.json to xray.service's ExecStart (or OpenRC command_args); run menu 6 after an ArgoX upgrade to repair.

---

## Files

| File | Description |
| --- | --- |
| /etc/argox/argoxv6.json | Per-stack inbound config generated by argoxv6 |
| /etc/argox/argoxv6.conf | argoxv6 state (IP, port, UUID, etc., key=value) |
| /etc/argox/cert/cert.pem, private.key | Self-signed certificate (reused or generated) |
| /etc/systemd/system/xray.service | Xray unit, with -c argoxv6.json appended |

---

## FAQ

**After upgrading/reinstalling ArgoX, argoxv6 nodes stopped working?**
Run bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh) -r or menu 6 to re-integrate argoxv6.json into the Xray service.

**Can IPv4 and IPv6 use the same port with different protocols?**
Yes. argoxv6 binds the v6 inbound to a specific IPv6 address and the v4 inbound to a specific IPv4 address; the two sockets do not conflict.

**Does uninstalling affect ArgoX's original nodes?**
No. Uninstall only removes argoxv6's added inbounds, restores the xray service, and closes the matching firewall ports. ArgoX's inbound.json / outbound.json remain intact.

**What if the server only has IPv4 (or only IPv6)?**
The script will note that you can only set an independent protocol for the stack that exists.

---

## Credits

- [fscarmen/ArgoX](https://github.com/fscarmen/ArgoX): the ArgoX project this helper builds upon.
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core): the Xray core.

---

## Disclaimer

This script is for learning and research only. Please comply with local laws and regulations. You are solely responsible for any consequences of using this script. This project is not affiliated with ArgoX or its author.

---

## License

This project is licensed under [GPL-3.0](LICENSE), consistent with upstream [ArgoX](https://github.com/fscarmen/ArgoX).
