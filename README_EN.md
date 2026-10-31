# ArgoXV6 v2

**ArgoX handles IPv4 only, argoxv6 handles IPv6 only — a non-interfering dual-stack split for ArgoX**

[![License](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Based on](https://img.shields.io/badge/built%20on-fscarmen%2FArgoX-orange.svg)](https://github.com/fscarmen/ArgoX)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20systemd%20%7C%20OpenRC-green.svg)](#)
[![Version](https://img.shields.io/badge/version-v2.0.0-brightgreen.svg)](#)

> A rewrite of [RNGCHEER/ARGOXV6](https://github.com/RNGCHEER/ARGOXV6) v1.0.x.
> The old version broke ArgoX (see [why the old version broke ArgoX](#why-the-old-version-broke-argox)); v2.0.0 decouples the two sides entirely — **if one side fails, the other keeps running**.

[中文](README.md) | English

---

## Contents

- [One-line install](#one-line-install)
- [What it does](#what-it-does)
- [Why the old version broke ArgoX](#why-the-old-version-broke-argox)
- [Architecture](#architecture)
- [Quick start](#quick-start)
- [Menu and CLI](#menu-and-cli)
- [Supported IPv6 protocols](#supported-ipv6-protocols)
- [Files](#files)
- [Environment variables](#environment-variables)
- [FAQ](#faq)
- [Uninstall](#uninstall)
- [Old vs new](#old-vs-new)
- [Credits](#credits)
- [Disclaimer](#disclaimer)
- [License](#license)

---

## One-line install

On a server with [ArgoX](https://github.com/fscarmen/ArgoX) already installed:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
```

or with curl:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
```

> ArgoX not installed? The script detects it and offers to install it via the official ArgoX script, then continues automatically.

---

## What it does

- **ArgoX (v4 side)**: pins ArgoX direct inbounds' `listen` to `0.0.0.0` so they listen on IPv4 only (WS / XHTTP tunnel inbounds on `127.0.0.1` are never touched).
- **argoxv6 (v6 side)**: gives IPv6 clients their own protocols / ports / credentials (Reality, Hysteria2, gRPC, XHTTP-H3, Trojan, SS2022).
- **Menu 1 launches ArgoX**: manage v4 nodes without leaving the script; it syncs automatically on exit.
- **IPv6 address self-healing**: after an IPv6 prefix change, one Xray restart fixes the listen address.
- **Boot guard**: systemd drop-in with a `-` prefix (a broken/missing hook can never block Xray), or a standalone OpenRC service.
- **Idempotent hot-mount**: v6 inbounds are added via the Xray gRPC API; unchanged config hash sends zero commands, so no repeated disconnects.
- **Clean uninstall**: API removal + drop-in removal + firewall rollback, ArgoX left untouched.

---

## Why the old version broke ArgoX

Traced against the `argox.sh` v2.2.0 source, not guessed:

| # | Old approach | Consequence | Location in argox.sh |
|---|---|---|---|
| 1 | `sed` the `ExecStart` of `xray.service` to append `-c argoxv6.json` | ArgoX rewrites that unit on every install / protocol change, wiping the append. Conversely, if `argoxv6.json` is corrupt or missing while `ExecStart` still references it, **Xray won't start at all → every ArgoX node dies** | `write_xray_daemon()` ~line 805, called ~line 5368 |
| 2 | v6 inbound `listen` hard-coded to a specific IPv6 address | Prefix change → bind fails → **whole Xray fails to start** | old `build_block()` |
| 3 | No defence | `api_hot_reload inbounds` rmi's any tag not present in `inbound.json`, **wiping v6 inbounds on every protocol change** | ~1005–1103, 5382 |
| 4 | v4 inbounds bound to a specific IPv4 address | Breaks whenever the IPv4 changes | old `add_protocol 4` |

**Root cause in one sentence: the old version put an optional feature into the mandatory startup path.**

---

## Architecture

```
                 ┌──────────────────────────────┐
  IPv4 clients ─▶│ ArgoX inbound.json           │  direct inbounds listen = 0.0.0.0
                 │  (reality / hy2 / trojan…)   │  ← IPv4 only
                 └──────────────┬───────────────┘
                                │  same xray process
                 ┌──────────────┴───────────────┐
  IPv6 clients ─▶│ argoxv6.json                 │  listen = host public IPv6
                 │  (hot-mounted via xray api)  │  ← IPv6 only
                 └──────────────────────────────┘
                                │
                 systemd drop-in (optional, "-" prefix ignores failures):
                 ExecStartPre=-hook pre    pin v4-only + fix v6 address
                 ExecStartPost=-hook post  hot-mount v6 via API
```

Three principles:

1. **Never touch `ExecStart`** — v6 inbounds use the native Xray gRPC API (`adi` / `rmi`); a failure only affects v6.
2. **Failures must be isolated** — a broken config, a stale address, or a missing file costs you at most the v6 nodes; v4 keeps running.
3. **Idempotent and reversible** — config hash unchanged means no action; uninstall fully restores ArgoX dual-stack.

---

## Quick start

```bash
bash <(wget -qO- https://raw.githubusercontent.com/RNGCHEER/ARGOXV6/main/argoxv6.sh)
```

The first run auto-detects public IPv4 / IPv6 (no public IPv6 → clear warning, ArgoX untouched). Typical flow:

1. **Menu 1** — add / edit IPv4 nodes inside ArgoX; it syncs on exit.
2. **Menu 2** — add protocols for IPv6 clients (batch input like `bcdlm`, `a` or Enter = all).
3. **Menu 3** — copy the IPv6 links into your client.

---

## Menu and CLI

| Menu | Function |
|---|---|
| 1 | Manage IPv4 nodes (launches official ArgoX script, auto-syncs on exit) |
| 2 | Add / replace IPv6 protocols |
| 3 | Show IPv6 node links |
| 4 | Delete an IPv6 protocol |
| 5 | Sync / self-check & repair |
| 6 | Re-detect IPv6 address |
| 7 | Show status (including whether each inbound is actually mounted) |
| 8 | Uninstall |
| 0 | Exit |

Command-line arguments:

```bash
bash argoxv6.sh                 # interactive menu
bash argoxv6.sh -s              # sync / self-check
bash argoxv6.sh -l              # print IPv6 links only
bash argoxv6.sh -u              # uninstall
bash argoxv6.sh -6 2001:db8::1  # force bind address (NAT66 / multi-address)
bash argoxv6.sh -v              # version
bash argoxv6.sh -h              # help (print script header)
```

---

## Supported IPv6 protocols

| Letter | Protocol | Transport | Notes |
|---|---|---|---|
| b | VLESS + Reality Vision | TCP | reuses ArgoX Reality keys / SNI |
| c | Hysteria2 | UDP/QUIC | reuses or generates self-signed cert |
| d | VLESS + Reality gRPC | gRPC | same as above (reuses Reality keys) |
| k | VLESS + XHTTP HTTP/3 Direct | QUIC | self-signed cert |
| l | Trojan Direct | TCP | self-signed cert |
| m | Shadowsocks 2022 | TCP/UDP | 2022-blake3-aes-128-gcm |

Ports start from **35000** and auto-increment, always avoiding ArgoX-occupied ports and other local IPv6 listeners.

---

## Files

| Path | Description |
|---|---|
| `/etc/argox/argoxv6.json` | v6 inbound config (read only by the API, not part of Xray startup) |
| `/etc/argox/argoxv6.conf` | state: bind address, ports / UUIDs / passwords |
| `/etc/argox/argoxv6-hook.sh` | boot hook, `pre` / `post`, always `exit 0` |
| `/etc/systemd/system/xray.service.d/50-argoxv6.conf` | only two `-`-prefixed ExecStartPre/Post lines |
| `/etc/init.d/argoxv6` | standalone OpenRC guard service |
| `/etc/argox/cert/` | self-signed cert (generated if ArgoX has none) |
| `/etc/argox/argoxv6.d/argox.sh` | cached ArgoX script (menu 1) |

ArgoX's own `inbound.json` / `outbound.json` / `xray.service` are **never rewritten** (the v4 side only adjusts the `listen` field and never touches `127.0.0.1` inbounds).

---

## Environment variables

For tests / special cases, override the default paths:

| Variable | Default | Description |
|---|---|---|
| `ARGOX_DIR` | `/etc/argox` | ArgoX working directory |
| `SYSTEMD_DIR` | `/etc/systemd/system` | systemd unit directory |
| `INITD_DIR` | `/etc/init.d` | OpenRC service directory |
| `ARGOXV6_FLAG` | `/run/argoxv6.need-restart` | restart flag file |

---

## FAQ

**Do I need to repair after an ArgoX upgrade / reinstall?**
No. The drop-in is a separate file; ArgoX rewriting `xray.service` doesn't remove it. In the extreme case (unit deleted and recreated), just run menu 5.

**Will IPv6 nodes drop when I change protocols in ArgoX?**
ArgoX's hot reload only knows its own `inbound.json` tags and will remove v6 inbounds as a side effect. Use **menu 1** to enter ArgoX (it re-mounts on exit). If you ran `argox.sh` directly, run **menu 5** afterwards.

**What if my VPS changes its IPv6 prefix?**
Nothing to do. The hook re-detects the address on every Xray start and rewrites the config if it differs — one restart heals it.

**Can WS / XHTTP (tunnel) nodes be split per stack?**
No. They are reached through the Cloudflare edge and proxied to `127.0.0.1`; both IPv4 and IPv6 clients can use them. That's an Argo tunnel property, not a script limitation. Only direct protocols can be split.

**Will my tunnel / v4 inbounds be modified?**
No. The v4 hardening changes only the `listen` field and never touches `127.0.0.1` inbounds; if generation fails it aborts and leaves ArgoX as-is.

**What if I have no public IPv6?**
The script says so explicitly and writes nothing; ArgoX keeps working.

**What does the boot guard give me?**
Installed: v6 inbounds are re-mounted automatically after a reboot (recommended). Not installed: it only takes effect for the current run; after a reboot run `argoxv6.sh -s` again.

---

## Uninstall

Menu 8 or `bash argoxv6.sh -u`:

1. Remove all v6 inbounds via API.
2. Remove drop-in / OpenRC service.
3. Close the v6 firewall ports it opened.
4. Optionally restore ArgoX native dual-stack.
5. Delete its own files.

ArgoX config stays as-is.

---

## Old vs new

| Item | v1.0.x (old) | v2.0.0 (this) |
|---|---|---|
| Integration | edit `ExecStart`, append `-c` | Xray API hot-mount + `-`-prefixed drop-in |
| Broken v6 config | **whole Xray fails to start** | v6 nodes lost only |
| ArgoX protocol change | integration wiped / v6 wiped | re-mounted automatically |
| IPv6 address change | **whole Xray fails to start** | corrected at startup |
| v4 side | bound to specific IPv4 | pinned to `0.0.0.0`, safe when IPv4 changes |
| Launch ArgoX | none | menu 1, auto-sync on exit |
| Repeated runs | restart Xray every time | zero commands when unchanged |
| Uninstall | restore service file | drop-in + API removal, zero residue |

---

## Credits

- [fscarmen/ArgoX](https://github.com/fscarmen/ArgoX) — the ArgoX project this script builds on
- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) — the Xray core

---

## Disclaimer

For learning and research only. Please comply with your local laws and regulations. You are solely responsible for any consequences of using this script. This project is not affiliated with ArgoX or its author.

---

## License

[GPL-3.0](LICENSE), same as upstream ArgoX.
