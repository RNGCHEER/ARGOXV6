#!/usr/bin/env bash
# ============================================================
# argoxv6.sh — ArgoX 辅助脚本：IPv4 / IPv6 分栈代理协议管理
# 版本：v1.0.0 (2026.10.31)
# 项目主页：https://github.com/RNGCHEER/ARGOXV6
# 许可证：GPL-3.0（与上游 ArgoX 相同）
#
# 背景：ArgoX（https://github.com/fscarmen/ArgoX）的所有入站均为
#       双栈监听（直连协议不设 listen）或 127.0.0.1（WS/XHTTP 走 Argo），
#       无法为 IPv4 / IPv6 设备分别指定不同的代理协议。
#       本辅助脚本在已安装 ArgoX 的服务器上，把新增入站精确绑定到
#       服务器的 IPv6 地址（或 IPv4 地址），实现：
#         * IPv6 设备走「IPv6 侧」独立协议 / 独立端口 / 独立凭据
#         * IPv4 设备走「IPv4 侧」独立协议（或继续用 ArgoX 原有节点）
#         * 同一端口可按栈区分协议（v6 绑具体 IPv6 地址、v4 绑具体
#           IPv4 地址，两个 socket 互不冲突）
#
# 前置条件：已安装 ArgoX（/etc/argox/xray、inbound.json、outbound.json 存在）
# 集成方式：给 xray 服务追加第三个配置文件 -c /etc/argox/argoxv6.json
#           （Xray 原生支持多配置合并，inbounds 数组合并，互不影响）
#
# 用法：
#   bash argoxv6.sh          # 交互菜单
#   bash argoxv6.sh -r      # 仅修复 Xray 服务集成（ArgoX 升级/重装后）
#   bash argoxv6.sh -l      # 仅显示节点链接
#   bash argoxv6.sh -u      # 卸载 argoxv6（还原服务、删除配置、关防火墙）
#
# 测试环境变量（一般用户无需理会）：
#   ARGOX_DIR=...           覆盖 ArgoX 工作目录（默认 /etc/argox）
#   XRAY_DAEMON_FILE=...    覆盖 systemd unit / OpenRC 脚本路径
# ============================================================

WORK_DIR="${ARGOX_DIR:-/etc/argox}"
CUSTOM_FILE="$WORK_DIR/custom"
V6_JSON="$WORK_DIR/argoxv6.json"
V6_CONF="$WORK_DIR/argoxv6.conf"

# 协议字母沿用 ArgoX 的命名习惯：
#   b = VLESS + Reality Vision      （TCP，Reality 复用 ArgoX 密钥对）
#   c = Hysteria2                   （UDP，自签证书复用 ArgoX cert）
#   d = VLESS + Reality gRPC
#   k = VLESS + XHTTP HTTP/3 Direct （TLS）
#   l = Trojan Direct               （TLS）
#   m = Shadowsocks 2022 Direct
PROTO_LETTERS='b c d k l m'
PROTO_NAME_b='reality-vision'
PROTO_NAME_c='hysteria2'
PROTO_NAME_d='reality-grpc'
PROTO_NAME_k='xhttp-h3-direct'
PROTO_NAME_l='trojan-direct'
PROTO_NAME_m='ss2022-direct'
PROTO_DESC_b='VLESS + Reality Vision'
PROTO_DESC_c='Hysteria2'
PROTO_DESC_d='VLESS + Reality gRPC'
PROTO_DESC_k='VLESS + XHTTP HTTP/3 Direct'
PROTO_DESC_l='Trojan Direct'
PROTO_DESC_m='Shadowsocks 2022 Direct'

# ---------------- 输出与输入 ----------------
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error()   { echo -e "\033[31m\033[01m$*\033[0m" && exit 1; }
info()    { echo -e "\033[32m\033[01m$*\033[0m"; }
hint()    { echo -e "\033[33m\033[01m$*\033[0m"; }

# reading "提示语" 变量名 [默认值]
reading() {
  local _p="$1" _v="$2" _d="${3:-}"
  if [ -n "$_d" ]; then
    read -r -p "$(echo -e "$_p [$_d]: ")" "$_v"
    [ -z "${!_v}" ] && eval "$_v='$_d'"
  else
    read -r -p "$(echo -e "$_p ")" "$_v"
  fi
}

# ---------------- 通用工具 ----------------
jq_bin() {
  if [ -x "$WORK_DIR/jq" ]; then echo "$WORK_DIR/jq"
  elif command -v jq >/dev/null 2>&1; then command -v jq
  else error " 未找到 jq，无法解析配置。请先完成 ArgoX 安装（自带 jq）。"; fi
}

gen_uuid() {
  [ -r /proc/sys/kernel/random/uuid ] && cat /proc/sys/kernel/random/uuid && return
  command -v uuidgen >/dev/null 2>&1 && uuidgen | tr 'A-Z' 'a-z' && return
  openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

is_v4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_v6() { [[ "$1" =~ : ]]; }

# ---------------- conf 读写（key=value 带单引号，可被 . 加载） ----------------
write_conf() {
  local _K="$1" _V="$2"
  if [ -s "$V6_CONF" ] && grep -q "^${_K}=" "$V6_CONF"; then
    sed -i "s|^${_K}=.*|${_K}='${_V}'|" "$V6_CONF"
  else
    echo "${_K}='${_V}'" >> "$V6_CONF"
  fi
}

conf_get() {
  [ -s "$V6_CONF" ] || return 0
  local _v
  _v=$(grep "^$1=" "$V6_CONF" | head -n1 | cut -d= -f2-)
  echo "${_v//\'/}"
}

del_conf_prefix() {
  [ -s "$V6_CONF" ] || return 0
  sed -i "/^$1/d" "$V6_CONF"
}

load_conf() {
  WAN4='' WAN6='' NODE_NAME=''
  [ -s "$V6_CONF" ] && . "$V6_CONF"
}

# 列出已配置条目：输出 "FAM LETTER PORT"
list_items() {
  [ -s "$V6_CONF" ] || return 0
  sed -n "s/^ITEM_\([46]\)_\([bcdklm]\)_PORT='\{0,1\}\([0-9]\+\)'\{0,1\}$/\1 \2 \3/p" "$V6_CONF" | sort
}

item_key() { echo "ITEM_$1_$2_$3"; }   # FAM LETTER FIELD

# ---------------- ArgoX 环境探测 ----------------
load_argox() {
  [ -s "$WORK_DIR/inbound.json" ] && [ -s "$WORK_DIR/outbound.json" ] || \
    error " 未检测到 ArgoX 安装（$WORK_DIR/inbound.json 不存在）。\n 请先安装 ArgoX：bash <(wget -qO- https://raw.githubusercontent.com/fscarmen/ArgoX/main/argox.sh)"
  [ -x "$WORK_DIR/xray" ] || hint " 提示：未找到 $WORK_DIR/xray，密钥生成与配置校验可能受限。"
  JQ=$(jq_bin)

  # custom：language / serverIp / privateKey / publicKey / cdn ...
  [ -s "$CUSTOM_FILE" ] && . "$CUSTOM_FILE"

  # 已保存的 argoxv6 配置
  load_conf

  # 节点名称：沿用 ArgoX 习惯（主机名）
  [ -z "$NODE_NAME" ] && NODE_NAME=$(hostname 2>/dev/null || echo 'ArgoX')
  NODE_NAME="argoxv6-${NODE_NAME// /-}"

  # 从 ArgoX inbound.json 提取 Reality 密钥对与 TLS SNI（有则复用）
  local _ib
  _ib=$(grep -vE '^[[:space:]]*//' "$WORK_DIR/inbound.json")
  if [ -n "$($JQ -r '[.inbounds[]? | select(.streamSettings.security == "reality")][0] // empty' <<< "$_ib" 2>/dev/null)" ]; then
    REALITY_PRIVATE=$($JQ -r '[.inbounds[]? | select(.streamSettings.security=="reality")][0].streamSettings.realitySettings.privateKey // empty' <<< "$_ib")
    REALITY_PUBLIC=$($JQ -r '[.inbounds[]? | select(.streamSettings.security=="reality")][0].streamSettings.realitySettings.publicKey // empty' <<< "$_ib")
    local _sni _dest
    _sni=$($JQ -r '[.inbounds[]? | select(.streamSettings.security=="reality")][0].streamSettings.realitySettings.serverNames[0] // empty' <<< "$_ib")
    _dest=$($JQ -r '[.inbounds[]? | select(.streamSettings.security=="reality")][0].streamSettings.realitySettings.dest // empty' <<< "$_ib")
    [ -n "$_sni" ] && TLS_SERVER="$_sni"
    [ -n "$_dest" ] && TLS_SERVER="${TLS_SERVER:-${_dest%:*}}"
  fi
  TLS_SERVER="${TLS_SERVER:-addons.mozilla.org}"

  # 证书路径：优先复用 ArgoX 自签证书
  local _cf _kf
  _cf=$($JQ -r '[.inbounds[]?.streamSettings.tlsSettings.certificates[]?.certificateFile][0] // empty' <<< "$_ib" 2>/dev/null)
  _kf=$($JQ -r '[.inbounds[]?.streamSettings.tlsSettings.certificates[]?.keyFile][0] // empty' <<< "$_ib" 2>/dev/null)
  [ -n "$_cf" ] && [ -s "$_cf" ] && CERT_FILE="$_cf"
  [ -n "$_kf" ] && [ -s "$_kf" ] && CERT_KEY="$_kf"
}

# ---------------- 公网 IP 探测 ----------------
detect_wan() {
  local _o4 _o6
  _o4=$(wget -4 -qO- --tries=2 --timeout=4 https://ip.cloudflare.now.cc 2>/dev/null \
        | awk -F'"' '/"ip"/{print $4; exit}')
  _o6=$(wget -6 -qO- --tries=2 --timeout=4 https://ip.cloudflare.now.cc 2>/dev/null \
        | awk -F'"' '/"ip"/{print $4; exit}')
  [ -z "$_o4" ] && _o4=$(curl -4 -s --max-time 4 https://api.ipify.org 2>/dev/null)
  [ -z "$_o6" ] && _o6=$(curl -6 -s --max-time 4 https://api64.ipify.org 2>/dev/null)
  [ -z "$_o4" ] && _o4=$(ip -4 addr show scope global 2>/dev/null | sed -n 's#.*inet \([^/]\+\)/.*#\1#p' | head -n1)
  [ -z "$_o6" ] && _o6=$(ip -6 addr show scope global 2>/dev/null | sed -n 's#.*inet6 \([^/]\+\)/.*#\1#p' | head -n1)
  is_v4 "$_o4" && WAN4="$_o4"
  is_v6 "$_o6" && WAN6="$_o6"
  write_conf 'WAN4' "$WAN4"
  write_conf 'WAN6' "$WAN6"
}

fam_addr() { [ "$1" = '6' ] && echo "$WAN6" || echo "$WAN4"; }
fam_name() { [ "$1" = '6' ] && echo 'IPv6' || echo 'IPv4'; }

# 链接里的主机：IPv6 需方括号
host_for_link() { is_v6 "$1" && echo "[$1]" || echo "$1"; }

# ---------------- 端口工具 ----------------
# ArgoX 已占用端口（其直连入站为双栈监听，一律视为冲突）
argox_ports() {
  grep -vE '^[[:space:]]*//' "$WORK_DIR/inbound.json" | $JQ -r '.inbounds[]?.port // empty' 2>/dev/null
}

is_port_conflict() {   # $1=port $2=fam
  local _p="$1" _f="$2" _used
  _used=$(argox_ports)
  grep -qx "$_p" <<< "$_used" && return 0
  # ss 实时监听（0.0.0.0 / :: 的双栈监听对两个家族都冲突）
  if command -v ss >/dev/null 2>&1; then
    ss -lntuH 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$' | grep -qx "$_p" && return 0
  fi
  # argoxv6 自身：同家族冲突、异家族同端口允许（绑不同地址）
  local _it
  while read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    [ "$2" = "$_p" ] && [ "$1" = "$_f" ] && return 0
  done < <(list_items)
  return 1
}

suggest_port() {   # $1=fam
  local _p=35000
  while is_port_conflict "$_p" "$1"; do _p=$((_p + 1)); done
  echo "$_p"
}

# ---------------- Reality / 证书 ----------------
ensure_reality() {
  if [ -z "${REALITY_PRIVATE:-}" ] || [ -z "${REALITY_PUBLIC:-}" ] || \
     [ "${REALITY_PRIVATE}" = '__KEY_UNSET__' ]; then
    local _kp
    if [ -x "$WORK_DIR/xray" ]; then
      _kp=$("$WORK_DIR/xray" x25519 2>/dev/null)
      REALITY_PRIVATE=$(awk '/Private/{print $NF}' <<< "$_kp")
      REALITY_PUBLIC=$(awk '/Public/{print $NF}' <<< "$_kp")
    fi
    [ -z "${REALITY_PRIVATE:-}" ] && error " 无法生成 Reality 密钥对（xray 不可用）。"
  fi
}

ensure_cert() {
  if [ -n "${CERT_FILE:-}" ] && [ -s "$CERT_FILE" ] && [ -n "${CERT_KEY:-}" ] && [ -s "$CERT_KEY" ]; then
    return 0
  fi
  command -v openssl >/dev/null 2>&1 || error " 需要 openssl 生成自签证书。"
  local _dir="$WORK_DIR/cert"
  mkdir -p "$_dir"
  openssl ecparam -genkey -name prime256v1 -out "$_dir/private.key" 2>/dev/null
  cat > "$_dir/cert.conf" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $(awk -F . '{print $(NF-1)"."$NF}' <<< "$TLS_SERVER")

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS = ${TLS_SERVER}
EOF
  openssl req -new -x509 -days 36500 \
    -key "$_dir/private.key" \
    -out "$_dir/cert.pem" \
    -config "$_dir/cert.conf" \
    -subj "/CN=$TLS_SERVER" \
    -extensions v3_req 2>/dev/null
  rm -f "$_dir/cert.conf"
  CERT_FILE="$_dir/cert.pem"
  CERT_KEY="$_dir/private.key"
  info " 已生成自签证书：$CERT_FILE"
}

# ---------------- 入站 JSON 构建 ----------------
# build_block FAM LETTER PORT UUID PASS -> 输出一个 inbound JSON 块
build_block() {
  local _f="$1" _l="$2" _port="$3" _uuid="$4" _pass="$5"
  local _addr; _addr=$(fam_addr "$_f")
  local _tag="$NODE_NAME argoxv6-v$_f-$(eval echo \$PROTO_NAME_$_l)"
  local _path="argoxv6-$_f-$_l"
  case "$_l" in
    b) cat << JSONEOF
    {
      "tag": "$_tag",
      "listen": "$_addr",
      "port": $_port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$_uuid", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$TLS_SERVER:443",
          "serverNames": [ "$TLS_SERVER" ],
          "privateKey": "$REALITY_PRIVATE",
          "publicKey": "$REALITY_PUBLIC",
          "shortIds": [ "" ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls" ] }
    }
JSONEOF
      ;;
    d) cat << JSONEOF
    {
      "tag": "$_tag",
      "listen": "$_addr",
      "port": $_port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$_uuid", "flow": "" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$TLS_SERVER:443",
          "xver": 0,
          "serverNames": [ "$TLS_SERVER" ],
          "privateKey": "$REALITY_PRIVATE",
          "publicKey": "$REALITY_PUBLIC",
          "shortIds": [ "" ]
        },
        "grpcSettings": { "serviceName": "grpc", "multiMode": true }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls" ] }
    }
JSONEOF
      ;;
    c) cat << JSONEOF
    {
      "tag": "$_tag",
      "listen": "$_addr",
      "port": $_port,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [ { "auth": "$_uuid" } ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverNames": [ "$TLS_SERVER" ],
          "alpn": [ "h3" ],
          "certificates": [ { "certificateFile": "$CERT_FILE", "keyFile": "$CERT_KEY" } ]
        }
      }
    }
JSONEOF
      ;;
    k) cat << JSONEOF
    {
      "tag": "$_tag",
      "listen": "$_addr",
      "port": $_port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$_uuid" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "mode": "stream-up",
          "extra": { "alpn": [ "h3" ] },
          "path": "/$_path"
        },
        "tlsSettings": {
          "serverName": "$TLS_SERVER",
          "alpn": [ "h3" ],
          "certificates": [ { "certificateFile": "$CERT_FILE", "keyFile": "$CERT_KEY" } ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
JSONEOF
      ;;
    l) cat << JSONEOF
    {
      "tag": "$_tag",
      "listen": "$_addr",
      "port": $_port,
      "protocol": "trojan",
      "settings": {
        "clients": [ { "password": "$_uuid" } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$TLS_SERVER",
          "certificates": [ { "certificateFile": "$CERT_FILE", "keyFile": "$CERT_KEY" } ]
        }
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
JSONEOF
      ;;
    m) cat << JSONEOF
    {
      "tag": "$_tag",
      "listen": "$_addr",
      "port": $_port,
      "protocol": "shadowsocks",
      "settings": {
        "method": "2022-blake3-aes-128-gcm",
        "password": "$_pass",
        "network": "tcp,udp"
      },
      "sniffing": { "enabled": true, "destOverride": [ "http", "tls", "quic" ] }
    }
JSONEOF
      ;;
  esac
}

# rebuild_json：由 conf 全量重建 argoxv6.json（幂等）
rebuild_json() {
  local _blocks='' _first=true _it _f _l _port _uuid _pass
  while read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    _f="$1" _l="$2" _port="$3"
    _uuid=$(conf_get "$(item_key "$_f" "$_l" UUID)")
    _pass=$(conf_get "$(item_key "$_f" "$_l" PASS)")
    $_first || _blocks+=$',\n'
    _blocks+="$(build_block "$_f" "$_l" "$_port" "$_uuid" "$_pass")"
    _first=false
  done < <(list_items)

  [ -s "$V6_JSON" ] && cp -f "$V6_JSON" "$V6_JSON.bak"
  if [ -z "$_blocks" ]; then
    echo '{ "inbounds": [] }' > "$V6_JSON"
  else
    cat > "$V6_JSON" << JSONEOF
{
  "inbounds": [
$_blocks
  ]
}
JSONEOF
  fi
  "$JQ" empty "$V6_JSON" 2>/dev/null || { [ -s "$V6_JSON.bak" ] && cp -f "$V6_JSON.bak" "$V6_JSON"; error " 生成 $V6_JSON 失败，已回滚。"; }
}

# ---------------- Xray 服务集成 ----------------
daemon_file() {
  if [ -n "${XRAY_DAEMON_FILE:-}" ]; then echo "$XRAY_DAEMON_FILE"
  elif [ -f /etc/systemd/system/xray.service ]; then echo /etc/systemd/system/xray.service
  elif [ -f /etc/init.d/xray ]; then echo /etc/init.d/xray
  else echo ''; fi
}

patch_daemon() {   # 追加 -c argoxv6.json
  local _f; _f=$(daemon_file)
  [ -z "$_f" ] && { hint " 未找到 xray 服务文件，请手动在 xray 启动命令中追加：-c $V6_JSON"; return 1; }
  grep -q 'argoxv6.json' "$_f" && return 0
  cp -f "$_f" "$_f.argoxv6.bak"
  if grep -q '^ExecStart=' "$_f"; then
    sed -i "s|^ExecStart=\(.*\)|ExecStart=\1 -c $V6_JSON|" "$_f"
  elif grep -q '^command_args=' "$_f"; then
    sed -i 's|^command_args="\(.*\)"$|command_args="\1 -c __ARGOXV6_JSON__"|' "$_f"
    grep -q '__ARGOXV6_JSON__' "$_f" || sed -i "s|^command_args=\(.*\)|command_args=\1 -c __ARGOXV6_JSON__|" "$_f"
    sed -i "s|__ARGOXV6_JSON__|$V6_JSON|" "$_f"
  else
    hint " 无法识别服务文件格式（$_f），请手动追加：-c $V6_JSON"
    return 1
  fi
  info " 已集成到 xray 服务：$_f"
}

unpatch_daemon() {
  local _f; _f=$(daemon_file)
  [ -z "$_f" ] && return 0
  grep -q 'argoxv6.json' "$_f" || return 0
  sed -i "s| -c $V6_JSON||g" "$_f"
  info " 已从 xray 服务移除 argoxv6 配置。"
}

repair_integration() {
  patch_daemon && restart_xray
}

restart_xray() {
  local _args=(-c "$WORK_DIR/inbound.json" -c "$WORK_DIR/outbound.json")
  [ -s "$V6_JSON" ] && _args+=(-c "$V6_JSON")
  # 校验合并配置
  if [ -x "$WORK_DIR/xray" ]; then
    if ! "$WORK_DIR/xray" run -test "${_args[@]}" >/dev/null 2>&1; then
      warning " Xray 配置校验失败，保留原运行状态。诊断命令："
      hint "   $WORK_DIR/xray run -test ${_args[*]}"
      return 1
    fi
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files xray.service >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1
    systemctl restart xray >/dev/null 2>&1 && { info " xray 服务已重启。"; return 0; }
  fi
  if [ -x /etc/init.d/xray ]; then
    /etc/init.d/xray restart >/dev/null 2>&1 && { info " xray 服务已重启（OpenRC）。"; return 0; }
  fi
  hint " 未能自动重启 xray，请手动执行：systemctl restart xray （或 rc-service xray restart）"
}

# ---------------- 防火墙 ----------------
fw_backend() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'active'; then echo ufw
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then echo firewalld
  elif command -v iptables >/dev/null 2>&1; then echo iptables
  else echo none; fi
}

fw_protos_for() {   # 协议字母 -> 需放行的传输层协议
  case "$1" in
    c) echo 'udp' ;;
    m|k) echo 'tcp udp' ;;
    *) echo 'tcp' ;;
  esac
}

fw_allow() {   # $1=fam $2=letter $3=port
  local _f="$1" _l="$2" _port="$3" _be _p
  _be=$(fw_backend)
  for _p in $(fw_protos_for "$_l"); do
    case "$_be" in
      ufw)
        ufw allow "$_port/$_p" comment "ArgoXV6 $_f $_l" >/dev/null 2>&1 ;;
      firewalld)
        firewall-cmd --permanent --add-port="$_port/$_p" >/dev/null 2>&1 ;;
      iptables)
        local _bin=iptables; [ "$_f" = '6' ] && _bin=ip6tables
        $_bin -C INPUT -p "$_p" --dport "$_port" -m comment --comment "ArgoXV6 $_f $_l" -j ACCEPT 2>/dev/null \
          || $_bin -I INPUT -p "$_p" --dport "$_port" -m comment --comment "ArgoXV6 $_f $_l" -j ACCEPT 2>/dev/null ;;
    esac
  done
  [ "$_be" = 'firewalld' ] && firewall-cmd --reload >/dev/null 2>&1
  [ "$_be" = 'iptables' ] && persist_iptables
  [ "$_be" = 'none' ] && hint " 未检测到防火墙，请自行放行端口 $_port（$(fam_name "$_f")）。"
}

fw_deny() {   # $1=fam $2=letter $3=port
  local _f="$1" _l="$2" _port="$3" _be _p
  _be=$(fw_backend)
  for _p in $(fw_protos_for "$_l"); do
    case "$_be" in
      ufw)
        ufw delete allow "$_port/$_p" >/dev/null 2>&1 ;;
      firewalld)
        firewall-cmd --permanent --remove-port="$_port/$_p" >/dev/null 2>&1 ;;
      iptables)
        local _bin=iptables; [ "$_f" = '6' ] && _bin=ip6tables
        $_bin -D INPUT -p "$_p" --dport "$_port" -m comment --comment "ArgoXV6 $_f $_l" -j ACCEPT 2>/dev/null ;;
    esac
  done
  [ "$_be" = 'firewalld' ] && firewall-cmd --reload >/dev/null 2>&1
  [ "$_be" = 'iptables' ] && persist_iptables
}

persist_iptables() {
  # ArgoX 已装 iptables 持久化钩子（rules.v4 / rules.v6），直接覆盖保存即可
  if [ -d /etc/iptables ]; then
    iptables-save  > /etc/iptables/rules.v4  2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6  2>/dev/null || true
  elif command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

# ---------------- 节点链接 ----------------
# build_link FAM LETTER PORT UUID PASS
build_link() {
  local _f="$1" _l="$2" _port="$3" _uuid="$4" _pass="$5"
  local _h; _h=$(host_for_link "$(fam_addr "$_f")")
  local _n="$NODE_NAME argoxv6-v$_f-$(eval echo \$PROTO_NAME_$_l)"
  _n=${_n// /%20}
  case "$_l" in
    b) echo "vless://${_uuid}@${_h}:${_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${TLS_SERVER}&fp=chrome&pbk=${REALITY_PUBLIC}&type=tcp&headerType=none#${_n}" ;;
    d) echo "vless://${_uuid}@${_h}:${_port}?encryption=none&security=reality&sni=${TLS_SERVER}&fp=chrome&pbk=${REALITY_PUBLIC}&type=grpc&serviceName=grpc&packetEncoding=xudp#${_n}" ;;
    c) echo "hysteria2://${_uuid}@${_h}:${_port}?sni=${TLS_SERVER}&insecure=1&alpn=h3#${_n}" ;;
    k) echo "vless://${_uuid}@${_h}:${_port}?encryption=none&security=tls&sni=${TLS_SERVER}&allowInsecure=1&fp=chrome&alpn=h3&type=xhttp&path=%2Fargoxv6-${_f}-${_l}&mode=stream-up#${_n}" ;;
    l) echo "trojan://${_uuid}@${_h}:${_port}?security=tls&sni=${TLS_SERVER}&allowInsecure=1&fp=chrome#${_n}" ;;
    m) local _b64
       _b64=$(printf '2022-blake3-aes-128-gcm:%s' "$_pass" | base64 -w0 2>/dev/null || printf '2022-blake3-aes-128-gcm:%s' "$_pass" | base64)
       echo "ss://${_b64}@${_h}:${_port}#${_n}" ;;
  esac
}

show_links() {
  local _it _f _l _port _uuid _pass _link _any=false _fam_lines
  for _f in 6 4; do
    _fam_lines=''
    while read -r _it; do
      [ -z "$_it" ] && continue
      set -- $_it
      [ "$1" = "$_f" ] || continue
      _l="$2" _port="$3"
      _uuid=$(conf_get "$(item_key "$_f" "$_l" UUID)")
      _pass=$(conf_get "$(item_key "$_f" "$_l" PASS)")
      _link=$(build_link "$_f" "$_l" "$_port" "$_uuid" "$_pass")
      _fam_lines+="$(eval echo \$PROTO_DESC_$_l) [端口 $_port]\n$_link\n\n"
      _any=true
    done < <(list_items)
    if [ -n "$_fam_lines" ]; then
      echo ''
      info "================ $(fam_name "$_f") 设备专用节点（监听 $(fam_addr "$_f")） ================"
      echo -e "$_fam_lines"
    fi
  done
  $_any || hint " 尚未配置任何 argoxv6 节点，请先在菜单中添加。"
}

# ---------------- 交互流程 ----------------
add_protocol() {   # $1=fam
  local _f="$1" _addr
  _addr=$(fam_addr "$_f")
  [ -z "$_addr" ] && error " 未检测到本机 $(fam_name "$_f") 公网地址，无法为 $(fam_name "$_f") 设备单独设置协议。"

  echo ''
  info "=========== 为 $(fam_name "$_f") 设备添加代理协议（绑定监听：$_addr） ==========="
  local _l
  for _l in $PROTO_LETTERS; do
    hint " $_l. $(eval echo \$PROTO_DESC_$_l)"
  done
  reading " 请选择协议字母" _l
  case " $PROTO_LETTERS " in
    *" $_l "*) : ;;
    *) error " 无效的协议字母：$_l" ;;
  esac

  # 同栈已有该协议 -> 询问覆盖
  local _old_port
  _old_port=$(conf_get "$(item_key "$_f" "$_l" PORT)")
  if [ -n "$_old_port" ]; then
    hint " $(fam_name "$_f") 侧已存在 $(eval echo \$PROTO_DESC_$_l)（端口 $_old_port），将覆盖。"
  fi

  local _port _sug
  _sug=$(suggest_port "$_f")
  [ -n "$_old_port" ] && _sug="$_old_port"
  reading " 请输入端口（直接回车使用推荐值）" _port "$_sug"
  [[ "$_port" =~ ^[0-9]+$ ]] && [ "$_port" -ge 100 ] && [ "$_port" -le 65535 ] || error " 端口无效：$_port"
  if is_port_conflict "$_port" "$_f" && [ "$_port" != "$_old_port" ]; then
    error " 端口 $_port 已被占用（ArgoX 或本机其他服务）。"
  fi

  local _uuid _pass=''
  _uuid=$(conf_get "$(item_key "$_f" "$_l" UUID)")
  [ -z "$_uuid" ] && _uuid=$(gen_uuid)
  if [ "$_l" = 'm' ]; then
    _pass=$(conf_get "$(item_key "$_f" "$_l" PASS)")
    [ -z "$_pass" ] && _pass=$(openssl rand -base64 16)
  fi

  # 依赖准备
  case "$_l" in
    b|d) ensure_reality ;;
    c|k|l) ensure_cert ;;
  esac

  # 写 conf
  write_conf "$(item_key "$_f" "$_l" PORT)" "$_port"
  write_conf "$(item_key "$_f" "$_l" UUID)" "$_uuid"
  [ "$_l" = 'm' ] && write_conf "$(item_key "$_f" "$_l" PASS)" "$_pass"
  write_conf 'NODE_NAME' "$NODE_NAME"

  rebuild_json
  patch_daemon
  fw_allow "$_f" "$_l" "$_port"
  restart_xray

  echo ''
  info " 已添加：$(fam_name "$_f") 侧 $(eval echo \$PROTO_DESC_$_l)（绑定 $_addr:$_port）"
  local _link
  _link=$(build_link "$_f" "$_l" "$_port" "$_uuid" "$_pass")
  echo ''
  echo " $_link"
}

delete_protocol() {
  local _it _any=false
  echo ''
  info "=========== 已配置的 argoxv6 协议 ==========="
  while read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    hint " $(fam_name "$1") 侧 | $2 = $(eval echo \$PROTO_DESC_$2) | 端口 $3"
    _any=true
  done < <(list_items)
  $_any || { hint " 尚未配置任何协议。"; return 0; }

  local _f _l
  reading " 请输入要删除的栈（4 或 6）" _f
  reading " 请输入要删除的协议字母" _l
  local _port
  _port=$(conf_get "$(item_key "$_f" "$_l" PORT)")
  [ -z "$_port" ] && error " 未找到：$(fam_name "$_f") 侧协议 $_l"

  del_conf_prefix "ITEM_${_f}_${_l}_"
  rebuild_json
  fw_deny "$_f" "$_l" "$_port"
  restart_xray
  info " 已删除 $(fam_name "$_f") 侧 $(eval echo \$PROTO_DESC_$_l)（端口 $_port）。"
}

update_addr() {
  echo ''
  hint " 正在重新探测公网 IP ..."
  detect_wan
  info " IPv4: ${WAN4:-未检测到}    IPv6: ${WAN6:-未检测到}"
  rebuild_json
  restart_xray
  info " 已按新地址重建入站监听。"
}

uninstall_v6() {
  echo ''
  warning " 即将卸载 argoxv6：删除全部分栈入站、还原 xray 服务、关闭相关防火墙端口。"
  reading " 确认卸载？(y/n)" _ok 'n'
  [ "$_ok" != 'y' ] && { hint " 已取消。"; return 0; }

  local _it
  while read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    fw_deny "$1" "$2" "$3"
  done < <(list_items)

  del_conf_prefix 'ITEM_'
  unpatch_daemon
  rm -f "$V6_JSON" "$V6_JSON.bak" "$V6_CONF"
  restart_xray
  info " argoxv6 已卸载。ArgoX 原有节点不受影响。"
}

menu() {
  while true; do
    echo ''
    info "================== argoxv6 分栈代理协议管理 =================="
    hint " 本机 IPv4: ${WAN4:-无}    本机 IPv6: ${WAN6:-无}"
    hint " 1. 为 IPv6 设备添加/更换代理协议"
    hint " 2. 为 IPv4 设备添加/更换代理协议"
    hint " 3. 查看节点链接（分栈输出）"
    hint " 4. 删除某个协议"
    hint " 5. 重新检测公网 IP 并更新监听地址"
    hint " 6. 修复 Xray 服务集成（ArgoX 升级/重装后执行）"
    hint " 7. 卸载 argoxv6"
    hint " 0. 退出"
    local _c
    reading " 请选择" _c
    case "$_c" in
      1) add_protocol 6 ;;
      2) add_protocol 4 ;;
      3) show_links ;;
      4) delete_protocol ;;
      5) update_addr ;;
      6) repair_integration ;;
      7) uninstall_v6 ;;
      0) exit 0 ;;
      *) hint " 无效选项。" ;;
    esac
  done
}

main() {
  load_argox
  case "${1:-}" in
    -r) repair_integration ;;
    -l) show_links ;;
    -u) uninstall_v6 ;;
    *)  detect_wan
        if [ -n "$WAN4" ] && [ -n "$WAN6" ]; then
          info " 检测到双栈公网地址：IPv4=$WAN4 / IPv6=$WAN6"
        else
          hint " 提示：仅检测到 IPv4=${WAN4:-无} / IPv6=${WAN6:-无}，只能为存在的栈设置独立协议。"
        fi
        menu ;;
  esac
}

main "$@"
