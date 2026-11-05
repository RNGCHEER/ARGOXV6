#!/usr/bin/env bash
# =============================================================================
#  argoxv6.sh  v2.1.1  (2026.11.03)
#  ArgoX 双栈助手 —— ArgoX 管 IPv4，argoxv6 管 IPv6；并支持「双栈添加」一次输出两栈节点
#
#  【v2.1.0 新增：双栈添加】
#    · 菜单 3 / -b：同一协议同时绑到 IPv4(0.0.0.0) 与 IPv6(本机 GUA)，
#      两侧可复用同一端口（不同地址族 socket 互不冲突）；
#      生成的 v4 入站同样走 Xray API 热挂载，ArgoX 完全不受影响。
#    · 菜单 4 / -l：按栈分组同时列出 IPv4 + IPv6 全部节点，
#      并附一份含全部节点的 Base64 订阅（可整串导入客户端）。
#    · 删除支持 4 / 6 / b（b = 两栈一起删）。
# =============================================================================
#
#  【为什么旧版 argoxv6 会把 ArgoX 搞坏】
#    旧版（v1.0.x）的做法是：sed 改写 /etc/systemd/system/xray.service 的
#    ExecStart，尾部追加 -c /etc/argox/argoxv6.json。这带来 4 个硬伤：
#
#    1) ArgoX 每次"装/改协议"都会重写 xray.service（argox.sh 里
#       write_xray_daemon 在 setup 流程被无条件调用），追加的那段被抹掉；
#       反过来，一旦 argoxv6.json 被删/写坏，而 ExecStart 还引用它，
#       xray 直接起不来 —— 表现就是"整个 ArgoX 全挂"。
#    2) argoxv6.json 里的 listen 是写死的某个 IPv6 地址。VPS 的 IPv6
#       前缀一变（RA 续约、换 IP），bind 失败 → 同样整个 xray 起不来。
#    3) ArgoX 的热更新 api_hot_reload inbounds 会 rmi 掉"运行中存在但
#       inbound.json 里没有"的所有 tag —— v6 入站每次都被人清掉。
#    4) 旧版还把 v4 入站也绑到具体 IPv4 地址，IPv4 一变就一起挂。
#
#  【新版怎么做的】
#    · 不再碰 ExecStart（一行都不改）。v6 入站用 Xray 原生 gRPC API
#      (xray api adi / rmi) 热挂载到运行中的进程上。
#      → 配置写坏、地址失效、文件丢失，最多只是 v6 节点没了，
#        ArgoX 的 v4 节点毫发无伤。
#    · 服务集成只用 systemd drop-in，且脚本前缀 "-"（ExecStartPre=-...），
#      即使 hook 文件被删、执行失败，systemd 也会忽略，绝不阻塞开机。
#    · v4 侧：把 ArgoX inbound.json 里"没写 listen"的入站钉成 0.0.0.0，
#      让 ArgoX 只监听 IPv4；WS/XHTTP（127.0.0.1 走 Argo 隧道）不动。
#    · v6 侧：新入站 listen 绑本机公网 IPv6 地址，并在每次启动时自动
#      重新探测，地址变了自动改。
#    · 提供"调用 ArgoX"入口：菜单 1 直接拉起官方 argox.sh 管 v4，
#      退出后自动同步（重钉 v4-only + 重挂 v6 入站）。
#
#  用法：
#    bash argoxv6.sh            交互菜单
#    bash argoxv6.sh -b         直接进入双栈添加（同一协议同时出 IPv4+IPv6 节点）
#    bash argoxv6.sh -b -p 12300  双栈添加并指定起始端口：第一个协议 12300，其余依次顺延
#    bash argoxv6.sh -l         同时输出 IPv4 + IPv6 全部节点链接（含 Base64 订阅）

#  端口规则：
#    · 单个协议：在端口提示里直接输入想要的端口（如 65000）即可
#    · 批量协议（bcdlm 或 a）：输入一个起始端口，其余协议按顺序顺延
#      例：起始 12300 → b=12300、c=12301、d=12302 …（被占用的端口自动跳过并提示）
#    · 回车 = 逐个确认（每个协议单独问，推荐值从 35000 起自动错开）
#    bash argoxv6.sh -s         一键同步 / 自检修复
#    bash argoxv6.sh -u         卸载（还原 ArgoX）
#    bash argoxv6.sh -6 <addr>  手动指定 IPv6 绑定地址
#    bash argoxv6.sh -v         版本
#
#  环境变量（测试/特殊场景）：
#    ARGOX_DIR=/etc/argox   SYSTEMD_DIR=/etc/systemd/system
#    INITD_DIR=/etc/init.d  ARGOXV6_FLAG=/run/argoxv6.need-restart
#
#  许可证：GPL-3.0（与上游 ArgoX 一致）
# =============================================================================

WORK_DIR="${ARGOX_DIR:-/etc/argox}"
CUSTOM_FILE="$WORK_DIR/custom"
IB="$WORK_DIR/inbound.json"
OB="$WORK_DIR/outbound.json"
V6_JSON="$WORK_DIR/argoxv6.json"
V6_CONF="$WORK_DIR/argoxv6.conf"
HOOK="$WORK_DIR/argoxv6-hook.sh"
STATE_DIR="$WORK_DIR/argoxv6.d"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
INITD_DIR="${INITD_DIR:-/etc/init.d}"
DROPIN="$SYSTEMD_DIR/xray.service.d/50-argoxv6.conf"
OPENRC_UNIT="$INITD_DIR/argoxv6"
FLAG="${ARGOXV6_FLAG:-/run/argoxv6.need-restart}"
START_PORT=''          # -p <port>：本批协议的起始端口，其余依次顺延

# ArgoX 官方主脚本
ARGOX_URL='https://raw.githubusercontent.com/fscarmen/ArgoX/main/argox.sh'
ARGOX_CACHE="$STATE_DIR/argox.sh"

# ---------------------------------------------------------------------------
# 协议表（字母沿用 ArgoX 习惯）
# ---------------------------------------------------------------------------
PROTO_LETTERS='b c d k l m'
PROTO_NAME_b='reality-vision';     PROTO_DESC_b='VLESS + Reality Vision'
PROTO_NAME_c='hysteria2';          PROTO_DESC_c='Hysteria2'
PROTO_NAME_d='reality-grpc';       PROTO_DESC_d='VLESS + Reality gRPC'
PROTO_NAME_k='xhttp-h3-direct';    PROTO_DESC_k='VLESS + XHTTP HTTP/3 Direct'
PROTO_NAME_l='trojan-direct';      PROTO_DESC_l='Trojan Direct'
PROTO_NAME_m='ss2022-direct';      PROTO_DESC_m='Shadowsocks 2022 Direct'

# ---------------------------------------------------------------------------
# 基础输出
# ---------------------------------------------------------------------------
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error()   { echo -e "\033[31m\033[01m$*\033[0m" >&2; exit 1; }
info()    { echo -e "\033[32m\033[01m$*\033[0m"; }
hint()    { echo -e "\033[33m\033[01m$*\033[0m"; }
plain()   { echo -e "$*"; }

# reading "提示语" 变量名 [默认值]
reading() {
  local _p="$1" _v="$2" _d="${3:-}" _in=''
  if [ -n "$_d" ]; then
    read -r -p "$(echo -e "$_p [$_d]: ")" _in || true
    [ -z "$_in" ] && _in="$_d"
  else
    read -r -p "$(echo -e "$_p ")" _in || exit 0
  fi
  printf -v "$_v" '%s' "$_in"
}

# 多字母解析：a 或回车 = 全部；去重保序
parse_letters() {
  local _in _ch _out=''
  _in=$(echo "${1:-}" | tr 'A-Z' 'a-z')
  if [ -z "$_in" ] || [ "$_in" = 'a' ]; then echo "$PROTO_LETTERS"; return 0; fi
  for _ch in $(printf '%s' "$_in" | grep -o .); do
    case " $PROTO_LETTERS " in
      *" $_ch "*)
        case " $_out " in
          *" $_ch "*) : ;;
          *) _out="$_out $_ch" ;;
        esac ;;
    esac
  done
  echo "${_out# }"
}

proto_name() { eval echo "\$PROTO_NAME_$1"; }
proto_desc() { eval echo "\$PROTO_DESC_$1"; }

# ---------------------------------------------------------------------------
# JSON 工具：ArgoX 的配置文件可能带 // 注释行，jq 前先剥掉
# ---------------------------------------------------------------------------
find_jq() {
  local _j=''
  if [ -x "$WORK_DIR/jq" ]; then _j="$WORK_DIR/jq"
  elif command -v jq >/dev/null 2>&1; then _j=$(command -v jq)
  fi
  echo "$_j"
}

need_jq() {
  JQ=$(find_jq)
  [ -n "$JQ" ] || error " 未找到 jq（$WORK_DIR/jq 或系统 jq），请先完成 ArgoX 安装。"
}

json_of() { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null; }
ibjq()    { json_of "$IB" | "$JQ" "$@"; }

# ---------------------------------------------------------------------------
# conf（argoxv6.conf，key='value'）
# ---------------------------------------------------------------------------
write_conf() {
  local _K="$1" _V="$2" _tmp
  mkdir -p "$(dirname "$V6_CONF")"
  [ -s "$V6_CONF" ] || : > "$V6_CONF"
  _tmp="$V6_CONF.tmp.$$"
  if grep -q "^${_K}=" "$V6_CONF" 2>/dev/null; then
    sed "s|^${_K}=.*|${_K}='${_V}'|" "$V6_CONF" > "$_tmp" && cat "$_tmp" > "$V6_CONF"
  else
    { cat "$V6_CONF"; echo "${_K}='${_V}'"; } > "$_tmp" && cat "$_tmp" > "$V6_CONF"
  fi
  rm -f "$_tmp"
}

conf_get() {
  [ -s "$V6_CONF" ] || return 0
  local _v
  _v=$(grep "^$1=" "$V6_CONF" 2>/dev/null | head -n1 | cut -d= -f2-)
  echo "${_v//\'/}"
}

del_conf_prefix() {
  [ -s "$V6_CONF" ] || return 0
  local _tmp="$V6_CONF.tmp.$$"
  grep -v "^$1" "$V6_CONF" > "$_tmp" 2>/dev/null
  cat "$_tmp" > "$V6_CONF"
  rm -f "$_tmp"
}

load_conf() {
  V6_BIND='' V6_PUB='' V4_PUB='' NODE_NAME='' HOOKS=''
  [ -s "$V6_CONF" ] && . "$V6_CONF"
}

item_key() { echo "ITEM_$1_$2_$3"; }   # FAM LETTER FIELD -> conf key

# 列出条目：每行 "FAM LETTER PORT"（FAM = 4 | 6）
list_items() {
  [ -s "$V6_CONF" ] || return 0
  sed -n "s/^ITEM_\([46]\)_\([bcdklm]\)_PORT='\{0,1\}\([0-9]\+\)'\{0,1\}$/\1 \2 \3/p" "$V6_CONF" | sort
}

item_tag() { echo "$NODE_NAME argoxv6-v$1-$(proto_name "$2")"; }   # $1=fam $2=letter

fam_label() { [ "$1" = '4' ] && echo 'IPv4' || echo 'IPv6'; }

# ---------------------------------------------------------------------------
# ArgoX 环境
# ---------------------------------------------------------------------------
argox_installed() { [ -s "$IB" ] && [ -s "$OB" ]; }

ensure_argox() {
  argox_installed && return 0
  echo ''
  warning " 未检测到 ArgoX 安装（$IB 不存在）。"
  hint " argoxv6 只是 ArgoX 的 IPv6 侧补充，需要先有 ArgoX。"
  if [ ! -t 0 ]; then
    error " 请先安装 ArgoX：bash <(wget -qO- $ARGOX_URL)"
  fi
  local _ok
  reading " 现在安装 ArgoX？(y/n)" _ok 'y'
  [ "$_ok" = 'y' ] || error " 已取消。"
  run_argox_script || error " ArgoX 安装未完成。"
  argox_installed || error " ArgoX 安装后仍未找到 $IB。"
}

XRAY=''
load_argox() {
  ensure_argox
  need_jq
  XRAY="$WORK_DIR/xray"

  # 系统初始化方式
  if [ -f "$SYSTEMD_DIR/xray.service" ] || command -v systemctl >/dev/null 2>&1; then
    SYSINIT='systemd'
    [ -f "$INITD_DIR/xray" ] && command -v rc-service >/dev/null 2>&1 && [ ! -d "$SYSTEMD_DIR" ] && SYSINIT='openrc'
  elif [ -f "$INITD_DIR/xray" ]; then
    SYSINIT='openrc'
  else
    SYSINIT='unknown'
  fi

  # ArgoX custom：language / serverIp / privateKey / publicKey / cdn / fingerprint ...
  REALITY_PRIVATE='' REALITY_PUBLIC='' FINGER_PRINT='' TLS_SERVER=''
  if [ -s "$CUSTOM_FILE" ]; then
    . "$CUSTOM_FILE"
    REALITY_PRIVATE="${privateKey:-}"
    REALITY_PUBLIC="${publicKey:-}"
    FINGER_PRINT="${fingerprint:-}"
    SERVER_IP="${serverIp:-}"
    [ "${REALITY_PRIVATE}" = '__KEY_UNSET__' ] && REALITY_PRIVATE=''
    [ "${REALITY_PUBLIC}"  = '__KEY_UNSET__' ] && REALITY_PUBLIC=''
  fi

  # Reality 密钥 / SNI / 证书：优先从 ArgoX 的 inbound.json 里抄，保证互通
  local _rk _sni _dest _cf _kf
  _rk=$(ibjq -c '[.inbounds[]? | select(.streamSettings.security == "reality")][0] // empty' 2>/dev/null)
  if [ -n "$_rk" ]; then
    [ -z "$REALITY_PRIVATE" ] && REALITY_PRIVATE=$("$JQ" -r '.streamSettings.realitySettings.privateKey // empty' <<< "$_rk")
    [ -z "$REALITY_PUBLIC" ]  && REALITY_PUBLIC=$("$JQ" -r '.streamSettings.realitySettings.publicKey // empty' <<< "$_rk")
    _sni=$("$JQ" -r '.streamSettings.realitySettings.serverNames[0] // empty' <<< "$_rk")
    _dest=$("$JQ" -r '.streamSettings.realitySettings.dest // empty' <<< "$_rk")
    [ -n "$_sni" ] && TLS_SERVER="$_sni"
    [ -z "$TLS_SERVER" ] && [ -n "$_dest" ] && TLS_SERVER="${_dest%:*}"
  fi
  if [ -z "$TLS_SERVER" ]; then
    TLS_SERVER=$(ibjq -r '[.inbounds[]? | select(.streamSettings.network == "hysteria") | .streamSettings.tlsSettings.serverNames[0]][0] // empty' 2>/dev/null)
  fi
  if [ -z "$TLS_SERVER" ] && [ -s "$WORK_DIR/cert/cert.pem" ] && command -v openssl >/dev/null 2>&1; then
    TLS_SERVER=$(openssl x509 -noout -ext subjectAltName -in "$WORK_DIR/cert/cert.pem" 2>/dev/null | awk -F 'DNS:' '/DNS:/{gsub(/,.*/,"",$2); print $2; exit}')
  fi
  TLS_SERVER="${TLS_SERVER:-addons.mozilla.org}"
  FINGER_PRINT="${FINGER_PRINT:-chrome}"

  CERT_FILE='' CERT_KEY=''
  _cf=$(ibjq -r '[.inbounds[]? | .streamSettings.tlsSettings.certificates[]?.certificateFile][0] // empty' 2>/dev/null)
  _kf=$(ibjq -r '[.inbounds[]? | .streamSettings.tlsSettings.certificates[]?.keyFile][0] // empty' 2>/dev/null)
  [ -n "$_cf" ] && [ -s "$_cf" ] && CERT_FILE="$_cf"
  [ -n "$_kf" ] && [ -s "$_kf" ] && CERT_KEY="$_kf"
  if [ -z "$CERT_FILE" ] && [ -s "$WORK_DIR/cert/cert.pem" ]; then
    CERT_FILE="$WORK_DIR/cert/cert.pem"
    CERT_KEY="$WORK_DIR/cert/private.key"
  fi

  # 节点名沿用 ArgoX 习惯（inbound tag 去掉最后一段）
  local _n
  _n=$(ibjq -r '.inbounds[0].tag // empty' 2>/dev/null | sed 's/ [^ ]*$//')
  load_conf
  NODE_NAME="${NODE_NAME:-${_n:-$(hostname 2>/dev/null || echo ArgoX)}}"
}

# ---------------------------------------------------------------------------
# IPv6 地址探测：绑定地址（本机 GUA）与公网地址（写进链接）分开
# ---------------------------------------------------------------------------
detect_v6_bind() {
  local _if _a=''
  _if=$(ip -6 route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$_if" ]; then
    _a=$(ip -6 addr show dev "$_if" 2>/dev/null | sed -n 's#.*inet6 \([^/]*\)/[0-9]*.*global.*#\1#p' | head -n1)
  fi
  if [ -z "$_a" ]; then
    _a=$(ip -6 addr show scope global 2>/dev/null | sed -n 's#.*inet6 \([^/]*\)/[0-9]*.*global.*#\1#p' | grep -v '^fe80' | head -n1)
  fi
  echo "$_a"
}

detect_v6_pub() {
  local _a=''
  command -v curl >/dev/null 2>&1 && \
    _a=$(curl -6 -fsS --max-time 5 https://ipv6.icanhazip.com 2>/dev/null | head -n1)
  if [ -z "$_a" ] && command -v wget >/dev/null 2>&1; then
    _a=$(wget -6 -qO- --tries=1 --timeout=5 https://ipv6.icanhazip.com 2>/dev/null | head -n1)
  fi
  if [ -z "$_a" ] && command -v curl >/dev/null 2>&1; then
    _a=$(curl -6 -fsS --max-time 5 https://ip.cloudflare.now.cc 2>/dev/null | awk -F'"' '/"ip"/{print $4; exit}')
  fi
  echo "$_a" | tr -d '\r\n'
}

is_v6() { [[ "$1" == *:* ]]; }

# 探测并落盘；地址变化时返回 0（表示需要重建 v6 配置）
detect_v6() {
  [ -n "${V6_OVERRIDE:-}" ] && return 1     # 命令行强制指定时不自动覆盖
  local _new _pub _old
  _new=$(detect_v6_bind)
  _pub=$(detect_v6_pub)
  is_v6 "$_pub" || _pub="$_new"
  _old=$(conf_get V6_BIND)

  V6_BIND="${_new:-$_old}"
  V6_PUB="${_pub:-$V6_BIND}"
  [ -n "$V6_BIND" ] && write_conf 'V6_BIND' "$V6_BIND"
  [ -n "$V6_PUB" ]  && write_conf 'V6_PUB'  "$V6_PUB"

  [ -n "$_new" ] && [ "$_new" != "$_old" ] && return 0
  return 1
}

# IPv4 地址探测：绑定地址用不上（v4 侧统一 listen 0.0.0.0），
# 但链接里的主机名需要公网 IPv4
is_v4_addr() { [[ "${1:-}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; }

detect_v4_bind() {
  local _if _a=''
  _if=$(ip -4 route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$_if" ] && _a=$(ip -4 addr show dev "$_if" 2>/dev/null | sed -n 's#.*inet \([^/]*\)/[0-9]*.*global.*#\1#p' | head -n1)
  [ -z "$_a" ] && _a=$(ip -4 addr show scope global 2>/dev/null | sed -n 's#.*inet \([^/]*\)/[0-9]*.*global.*#\1#p' | head -n1)
  echo "$_a"
}

detect_v4_pub() {
  local _a=''
  # 1) ArgoX custom 里的 serverIp 若是 IPv4，优先使用（与 ArgoX 订阅保持一致）
  is_v4_addr "$SERVER_IP" && { echo "$SERVER_IP"; return 0; }
  # 2) 在线探测
  command -v curl >/dev/null 2>&1 && _a=$(curl -4 -fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | head -n1)
  if [ -z "$_a" ] && command -v wget >/dev/null 2>&1; then
    _a=$(wget -4 -qO- --tries=1 --timeout=5 https://ipv4.icanhazip.com 2>/dev/null | head -n1)
  fi
  if [ -z "$_a" ] && command -v curl >/dev/null 2>&1; then
    _a=$(curl -4 -fsS --max-time 5 https://ip.cloudflare.now.cc 2>/dev/null | awk -F'"' '/"ip"/{print $4; exit}')
  fi
  # 3) 兜底：本机网卡地址
  [ -z "$_a" ] && _a=$(detect_v4_bind)
  echo "$_a" | tr -d '\r\n'
}

# 探测并落盘；地址变化返回 0
detect_v4() {
  local _pub
  _pub=$(detect_v4_pub)
  is_v4_addr "$_pub" || return 1
  if [ "$_pub" = "$(conf_get V4_PUB)" ]; then V4_PUB="$_pub"; return 1; fi
  V4_PUB="$_pub"
  write_conf 'V4_PUB' "$V4_PUB"
  return 0
}

host_for_link() { is_v6 "$1" && echo "[$1]" || echo "$1"; }

# ---------------------------------------------------------------------------
# Xray API（v6 入站的生命线，全程只走 API，不碰服务文件）
# ---------------------------------------------------------------------------
_API=''
api_addr() {
  [ -n "$_API" ] && { echo "$_API"; return 0; }
  local _p=''
  _p=$(ibjq -r '.api.listen // empty' 2>/dev/null | awk -F: '{print $NF}')
  if [ -n "$_p" ]; then
    _API="127.0.0.1:$_p"
    echo "$_API"
    return 0
  fi
  # 兜底：扫进程监听的本地端口，逐个试
  local _lp
  for _lp in $(ss -tlnp 2>/dev/null | grep -i '[x]ray' | grep -oE '127\.0\.0\.1:[0-9]+' | awk -F: '{print $2}' | sort -un); do
    if [ -x "$XRAY" ] && "$XRAY" api lsi --server="127.0.0.1:$_lp" >/dev/null 2>&1; then
      _API="127.0.0.1:$_lp"
      echo "$_API"
      return 0
    fi
  done
  return 1
}

api_ready() {
  [ -x "$XRAY" ] || return 1
  local _a; _a=$(api_addr) || return 1
  "$XRAY" api lsi --server="$_a" >/dev/null 2>&1
}

wait_api() {
  local _t="${1:-15}" _i=0
  while [ "$_i" -lt "$_t" ]; do
    api_ready && return 0
    _i=$((_i + 1))
    sleep 1
  done
  return 1
}

# 运行中的 tag 列表（每行一个，tag 里可能有空格，必须按行读）
live_tags_file() {
  local _out _f="$1"
  : > "$_f"
  [ -x "$XRAY" ] || return 0
  local _a; _a=$(api_addr) || return 0
  _out=$("$XRAY" api lsi --server="$_a" --isOnlyTags=true 2>/dev/null | tr -d '\r')
  [ -z "$_out" ] && return 0
  if printf '%s' "$_out" | "$JQ" -r '.inbounds[]?.tag // empty' 2>/dev/null | tr -d '\r' > "$_f" && [ -s "$_f" ]; then
    return 0
  fi
  printf '%s\n' "$_out" | tr -d '\r' | tr -d '"' | tr -d '[]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^,\{0,1\}$' | grep -v '^[{}[]' > "$_f"
}

xray_active() {
  case "$SYSINIT" in
    systemd) systemctl is-active xray >/dev/null 2>&1 ;;
    openrc)  rc-service xray status >/dev/null 2>&1 ;;
    *)       ps -eo args 2>/dev/null | grep -q "[x]ray run" ;;
  esac
}

restart_xray() {
  case "$SYSINIT" in
    systemd)
      systemctl daemon-reload >/dev/null 2>&1
      systemctl restart xray >/dev/null 2>&1 ;;
    openrc)
      rc-service xray restart >/dev/null 2>&1 ;;
    *)
      warning " 无法识别服务管理器，请手动重启 xray。"
      return 1 ;;
  esac
  wait_api 20 && return 0
  warning " Xray 重启后 API 未就绪，请执行：systemctl status xray -l  排查。"
  return 1
}

# ---------------------------------------------------------------------------
# v4 侧加固：把 ArgoX"没写 listen"的入站钉成 0.0.0.0（= 只听 IPv4）
#   · 只动 listen 字段缺失或为 "::" 的入站
#   · 127.0.0.1（WS/XHTTP 走 Argo 隧道）一律不碰
#   · 写坏就整体回滚，绝不留下半截文件
# ---------------------------------------------------------------------------
V4_TMP="$WORK_DIR/.inbound.v4tmp"

v4_patch() {
  [ -s "$IB" ] || return 1
  local _n
  _n=$(ibjq -r '[.inbounds[]? | select((.listen // "") == "" or .listen == "::")] | length' 2>/dev/null)
  [ -z "$_n" ] && return 1
  [ "$_n" = '0' ] && return 0

  json_of "$IB" | "$JQ" '(.inbounds[]? | select((.listen // "") == "" or .listen == "::")) |= (. + {listen: "0.0.0.0"})' > "$V4_TMP" 2>/dev/null
  if [ ! -s "$V4_TMP" ] || ! "$JQ" empty "$V4_TMP" >/dev/null 2>&1; then
    rm -f "$V4_TMP"
    warning " 生成 IPv4-only 配置失败，已放弃（ArgoX 保持原样，不影响使用）。"
    return 1
  fi
  cat "$V4_TMP" > "$IB"
  rm -f "$V4_TMP"
  return 0
}

# 还原成 ArgoX 原生的双栈监听
v4_unpatch() {
  [ -s "$IB" ] || return 1
  local _n
  _n=$(ibjq -r '[.inbounds[]? | select(.listen == "0.0.0.0")] | length' 2>/dev/null)
  [ -z "$_n" ] && return 1
  [ "$_n" = '0' ] && return 0

  json_of "$IB" | "$JQ" '(.inbounds[]? | select(.listen == "0.0.0.0")) |= del(.listen)' > "$V4_TMP" 2>/dev/null
  if [ ! -s "$V4_TMP" ] || ! "$JQ" empty "$V4_TMP" >/dev/null 2>&1; then
    rm -f "$V4_TMP"
    warning " 还原双栈配置失败，请手动检查 $IB。"
    return 1
  fi
  cat "$V4_TMP" > "$IB"
  rm -f "$V4_TMP"
  return 0
}

v4_state() {
  local _n
  _n=$(ibjq -r '[.inbounds[]? | select((.listen // "") == "" or .listen == "::")] | length' 2>/dev/null)
  if [ "$_n" = '0' ]; then echo 'v4only'; else echo 'dual'; fi
}

v4_summary() {
  ibjq -r '.inbounds[]? | "\(.tag // "-")\t\(.listen // "双栈")\t\(.port // "-")"' 2>/dev/null | while IFS="$(printf '\t')" read -r _tag _ls _pt; do
    [ -z "$_tag" ] && continue
    plain "   ${_pt} | ${_ls} | ${_tag}"
  done
}

# ---------------------------------------------------------------------------
# hook 脚本（独立文件，被 systemd / OpenRC 调用；也可被主脚本直接调用）
#   pre  : 钉 v4-only + 修正 v6 地址        （在 xray 启动前）
#   post : 用 API 把 v6 入站挂到运行中的 xray （在 xray 启动后）
#   两个动作都保证 exit 0，任何异常都不影响 ArgoX
# ---------------------------------------------------------------------------
write_hook() {
  mkdir -p "$WORK_DIR"
  {
    echo '#!/bin/sh'
    echo '# 由 argoxv6 自动生成，请勿手工编辑。所有失败都静默，绝不阻塞 Xray 启动。'
    echo "WORK_DIR='$WORK_DIR'"
    echo "FLAG='$FLAG'"
    echo "MODE=\"\${1:-pre}\""
    cat << 'HOOK_BODY'

IB="$WORK_DIR/inbound.json"
V6_JSON="$WORK_DIR/argoxv6.json"
V6_CONF="$WORK_DIR/argoxv6.conf"
XRAY="$WORK_DIR/xray"

find_jq() {
  if [ -x "$WORK_DIR/jq" ]; then echo "$WORK_DIR/jq"; return; fi
  command -v jq 2>/dev/null
}

usable() { [ -x "$XRAY" ] && [ -n "$(find_jq)" ]; }

patch_v4() {
  JQ=$(find_jq); [ -n "$JQ" ] || return 0
  [ -s "$IB" ] || return 0
  TMP="$WORK_DIR/.inbound.hook.$$"
  grep -vE '^[[:space:]]*//' "$IB" \
    | "$JQ" '(.inbounds[]? | select((.listen // "") == "" or .listen == "::")) |= (. + {listen: "0.0.0.0"})' \
    > "$TMP" 2>/dev/null || { rm -f "$TMP"; return 0; }
  if [ ! -s "$TMP" ] || ! "$JQ" empty "$TMP" >/dev/null 2>&1; then rm -f "$TMP"; return 0; fi
  if cmp -s "$TMP" "$IB"; then rm -f "$TMP"; return 0; fi
  cat "$TMP" > "$IB" && rm -f "$TMP"
  : > "$FLAG" 2>/dev/null
}

detect_v6() {
  IF=$(ip -6 route show default 2>/dev/null | awk '/default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$IF" ]; then
    A=$(ip -6 addr show dev "$IF" 2>/dev/null | sed -n 's#.*inet6 \([^/]*\)/[0-9]*.*global.*#\1#p' | head -n1)
  fi
  [ -z "$A" ] && A=$(ip -6 addr show scope global 2>/dev/null | sed -n 's#.*inet6 \([^/]*\)/[0-9]*.*global.*#\1#p' | grep -v '^fe80' | head -n1)
  echo "$A"
}

refresh_v6() {
  JQ=$(find_jq); [ -n "$JQ" ] || return 0
  [ -s "$V6_JSON" ] || return 0
  NEW=$(detect_v6); [ -n "$NEW" ] || return 0
  # 只改 v6 入站的 listen（tag 含 -v6-）；v4 入站固定 0.0.0.0，绝不能跟着改
  OLD=$("$JQ" -r '[.inbounds[]? | select((.tag // "") | contains("-v6-")) | .listen // empty] | .[0] // empty' "$V6_JSON" 2>/dev/null)
  [ -n "$OLD" ] || return 0
  [ "$OLD" = "$NEW" ] && return 0
  TMP="$V6_JSON.new.$$"
  "$JQ" --arg a "$OLD" --arg b "$NEW" '(.inbounds[]? | select((.tag // "") | contains("-v6-")) | select(.listen == $a)) |= (.listen = $b)' "$V6_JSON" > "$TMP" 2>/dev/null
  if [ -s "$TMP" ] && "$JQ" empty "$TMP" >/dev/null 2>&1; then mv -f "$TMP" "$V6_JSON"; else rm -f "$TMP"; fi
  [ -s "$V6_CONF" ] && sed -i "s|^V6_BIND=.*|V6_BIND='$NEW'|" "$V6_CONF" 2>/dev/null
  return 0
}

api_addr() {
  JQ=$(find_jq); [ -n "$JQ" ] || return 1
  P=$(grep -vE '^[[:space:]]*//' "$IB" 2>/dev/null | "$JQ" -r '.api.listen // empty' 2>/dev/null | awk -F: '{print $NF}')
  [ -n "$P" ] || return 1
  echo "127.0.0.1:$P"
}

hash_of() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v cksum >/dev/null 2>&1; then cksum "$1" 2>/dev/null | awk '{print $1"-"$2}'
  fi
}

ensure_v6() {
  usable || return 0
  [ -s "$V6_JSON" ] || return 0
  JQ=$(find_jq)
  API=$(api_addr) || return 0
  I=0
  while [ $I -lt 20 ]; do
    "$XRAY" api lsi --server="$API" >/dev/null 2>&1 && break
    I=$((I+1)); sleep 0.5
  done
  "$XRAY" api lsi --server="$API" >/dev/null 2>&1 || return 0

  CNT=$("$JQ" '.inbounds | length' "$V6_JSON" 2>/dev/null)
  [ -n "$CNT" ] || return 0
  [ "$CNT" -gt 0 ] || return 0

  TAGS="$WORK_DIR/.hooktags.$$"
  LIVE="$WORK_DIR/.hooklive.$$"
  "$JQ" -r '.inbounds[]?.tag // empty' "$V6_JSON" 2>/dev/null | tr -d '\r' > "$TAGS"
  OUT=$("$XRAY" api lsi --server="$API" --isOnlyTags=true 2>/dev/null | tr -d '\r')
  if printf '%s' "$OUT" | "$JQ" -r '.inbounds[]?.tag // empty' 2>/dev/null | tr -d '\r' > "$LIVE" && [ -s "$LIVE" ]; then
    :
  else
    printf '%s\n' "$OUT" | tr -d '\r' | tr -d '"' | tr -d '[]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^,\{0,1\}$' | grep -v '^[{}[]' > "$LIVE"
  fi

  # 1) 清掉历史残留的 argoxv6 入站（不在当前配置里的）
  while IFS= read -r T; do
    [ -z "$T" ] && continue
    case "$T" in
      *argoxv6*) grep -qxF "$T" "$TAGS" || "$XRAY" api rmi --server="$API" "$T" >/dev/null 2>&1 ;;
    esac
  done < "$LIVE"

  # 2) 按需重挂：配置没变且该入站已在运行 → 完全不动它（避免无谓断连）
  NOW=$(hash_of "$V6_JSON")
  OLD=$(cat "$V6_JSON.hash" 2>/dev/null)
  I=0
  while [ $I -lt "$CNT" ]; do
    T=$("$JQ" -r ".inbounds[$I].tag // empty" "$V6_JSON" 2>/dev/null | tr -d '\r')
    if [ -n "$NOW" ] && [ "$NOW" = "$OLD" ] && [ -n "$T" ] && grep -qxF "$T" "$LIVE"; then
      I=$((I+1)); continue
    fi
    F="$WORK_DIR/.hookadi.$$"
    "$JQ" -c "{inbounds: [.inbounds[$I]]}" "$V6_JSON" > "$F" 2>/dev/null
    if [ -s "$F" ]; then
      [ -n "$T" ] && "$XRAY" api rmi --server="$API" "$T" >/dev/null 2>&1
      "$XRAY" api adi --server="$API" "$F" >/dev/null 2>&1
    fi
    rm -f "$F"
    I=$((I+1))
  done

  [ -n "$NOW" ] && echo "$NOW" > "$V6_JSON.hash" 2>/dev/null
  rm -f "$TAGS" "$LIVE"
  return 0
}

case "$MODE" in
  pre)
    patch_v4
    refresh_v6
    ;;
  post)
    if [ -f "$FLAG" ] && command -v rc-service >/dev/null 2>&1 && [ ! -d /etc/systemd/system ]; then
      rc-service xray restart >/dev/null 2>&1
      rm -f "$FLAG"
    fi
    ensure_v6
    ;;
esac
exit 0
HOOK_BODY
  } > "$HOOK"
  chmod 755 "$HOOK"
}

hooks_installed() {
  case "$SYSINIT" in
    systemd) [ -f "$DROPIN" ] && [ -x "$HOOK" ] ;;
    openrc)  [ -x "$OPENRC_UNIT" ] && [ -x "$HOOK" ] ;;
    *)       [ -x "$HOOK" ] ;;
  esac
}

install_hooks() {
  write_hook
  case "$SYSINIT" in
    systemd)
      mkdir -p "$(dirname "$DROPIN")"
      cat > "$DROPIN" << EOF
# 由 argoxv6 生成。只做两件事，且都以 "-" 前缀忽略失败：
#   pre  → 把 ArgoX 直连入站钉成 0.0.0.0（IPv4-only）+ 校正 v6 地址
#   post → 用 Xray API 把 v6 入站热挂到运行中的进程
# 即使本 hook 被删除或执行失败，Xray / ArgoX 仍能正常启动。
[Service]
ExecStartPre=-$HOOK pre
ExecStartPost=-$HOOK post
EOF
      systemctl daemon-reload >/dev/null 2>&1
      ;;
    openrc)
      cat > "$OPENRC_UNIT" << EOF
#!/sbin/openrc-run
name="argoxv6"
description="argoxv6 IPv6 side guard for ArgoX"

depend() { need xray; after xray; }

start() {
    ebegin "argoxv6: sync IPv6 inbounds"
    $HOOK pre
    if [ -f $FLAG ]; then rc-service xray restart >/dev/null 2>&1; rm -f $FLAG; fi
    $HOOK post
    eend 0
}
EOF
      chmod 755 "$OPENRC_UNIT"
      rc-update add argoxv6 default >/dev/null 2>&1
      ;;
  esac
  write_conf 'HOOKS' 'yes'
  if [ "$SYSINIT" = 'unknown' ]; then
    info " 已生成本地 hook：$HOOK"
    hint " 未识别到服务管理器，无法自动挂钩；重启后请手动执行一次 bash argoxv6.sh -s"
  else
    info " 已安装开机守护（ArgoX 重装/升级都不会冲掉它）。"
  fi
}

remove_hooks() {
  case "$SYSINIT" in
    systemd)
      if [ -f "$DROPIN" ]; then
        rm -f "$DROPIN"
        rmdir "$(dirname "$DROPIN")" 2>/dev/null
        systemctl daemon-reload >/dev/null 2>&1
        info " 已移除 systemd drop-in。"
      fi
      ;;
    openrc)
      if [ -f "$OPENRC_UNIT" ]; then
        rc-update del argoxv6 default >/dev/null 2>&1
        rm -f "$OPENRC_UNIT"
        info " 已移除 OpenRC 服务。"
      fi
      ;;
  esac
  write_conf 'HOOKS' 'no'
}

ensure_hooks() {
  hooks_installed && return 0
  local _ans
  _ans=$(conf_get HOOKS)
  [ "$_ans" = 'no' ] && return 1
  # 之前已经同意过：直接补装（比如 drop-in 被手工删掉）
  if [ "$_ans" = 'yes' ]; then install_hooks; return 0; fi
  [ -t 0 ] || return 1
  echo ''
  hint " 是否安装开机守护？"
  plain "   · 装了：服务器重启后 v6 入站自动挂回来（推荐）"
  plain "   · 不装：只本次生效，重启后需要再跑一次 argoxv6"
  local _ok
  reading " 安装开机守护？(y/n)" _ok 'y'
  [ "$_ok" = 'y' ] || { write_conf 'HOOKS' 'no'; return 1; }
  install_hooks
  return 0
}

# ---------------------------------------------------------------------------
# 端口
# ---------------------------------------------------------------------------
argox_ports() {
  ibjq -r '.inbounds[]?.port // empty' 2>/dev/null
}

# 该端口能否在 v6 上监听：只有"通配监听 / 具体 IPv6 监听"才会妨碍绑定
# （纯 IPv4 的 0.0.0.0:x 或 1.2.3.4:x 不影响 [v6addr]:x）
port_free_on_v6() {
  local _p="$1" _addrs _a
  command -v ss >/dev/null 2>&1 || return 0
  _addrs=$(ss -H -lntu 2>/dev/null | awk '{print $4}' | grep -E "[:.]${_p}\$" 2>/dev/null)
  while IFS= read -r _a; do
    [ -z "$_a" ] && continue
    case "$_a" in
      \[*\]:*|*::*) return 1 ;;                            # [::]:p、[2001:db8::1]:p、:::p
      0.0.0.0:*|127.*) continue ;;                          # 纯 IPv4 通配/回环：不冲突
      [0-9]*.[0-9]*.[0-9]*.[0-9]*:*) continue ;;            # 具体 IPv4 地址：不冲突
      *) return 1 ;;                                        # *:p 等未知写法：按冲突处理
    esac
  done <<< "$_addrs"
  return 0
}

# 该端口能否在 v4 上监听（0.0.0.0 通配）：只有"IPv4 通配/具体 IPv4/回环"才妨碍
port_free_on_v4() {
  local _p="$1" _addrs _a
  command -v ss >/dev/null 2>&1 || return 0
  _addrs=$(ss -H -lntu 2>/dev/null | awk '{print $4}' | grep -E "[:.]${_p}\$" 2>/dev/null)
  while IFS= read -r _a; do
    [ -z "$_a" ] && continue
    case "$_a" in
      \[*\]:*|*::*) continue ;;                             # 纯 IPv6 监听：不影响 v4
      0.0.0.0:*|127.*) return 1 ;;                            # IPv4 通配/回环：冲突
      [0-9]*.[0-9]*.[0-9]*.[0-9]*:*) return 1 ;;              # 具体 IPv4：与 0.0.0.0 冲突
      *) return 1 ;;
    esac
  done <<< "$_addrs"
  return 0
}

is_port_conflict() {   # $1=port $2=fam（默认 6，保持旧调用兼容）
  local _p="$1" _f="${2:-6}" _it
  # 1) ArgoX 占用的端口：一律避开（保证 v4 侧不动、也不会互相踩）
  grep -qx "$_p" <<< "$(argox_ports)" && return 0
  # 2) 自己已用的同栈端口（异栈同端口允许：绑不同地址，socket 不冲突）
  while IFS= read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    [ "$3" = "$_p" ] && [ "$1" = "$_f" ] && return 0
  done <<< "$(list_items)"
  # 3) 系统里同地址族的其它监听
  if [ "$_f" = '4' ]; then
    port_free_on_v4 "$_p" && return 1
  else
    port_free_on_v6 "$_p" && return 1
  fi
  return 0
}

suggest_port() {   # $1=fam（默认 6）
  local _f="${1:-6}" _p=35000
  while is_port_conflict "$_p" "$_f"; do _p=$((_p + 1)); done
  echo "$_p"
}

# 双栈：找一个在 v4 与 v6 两侧都空闲的端口
suggest_port_dual() {
  local _p=35000
  while is_port_conflict "$_p" 6 || is_port_conflict "$_p" 4; do _p=$((_p + 1)); done
  echo "$_p"
}

# ---------------------------------------------------------------------------
# 凭据 / 证书
# ---------------------------------------------------------------------------
gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid; return; fi
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; return; fi
  od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

rand_b64_16() { head -c 16 /dev/urandom | base64 | tr -d '\n'; }

ensure_reality() {
  if [ -n "${REALITY_PRIVATE}" ] && [ -n "${REALITY_PUBLIC}" ]; then return 0; fi
  [ -x "$XRAY" ] || error " 需要 $WORK_DIR/xray 生成 Reality 密钥对。"
  local _kp
  _kp=$("$XRAY" x25519 2>/dev/null)
  REALITY_PRIVATE=$(awk '/[Pp]rivate/{print $NF}' <<< "$_kp")
  REALITY_PUBLIC=$(awk '/[Pp]ublic/{print $NF}' <<< "$_kp")
  [ -n "$REALITY_PRIVATE" ] || error " 生成 Reality 密钥对失败。"
}

ensure_cert() {
  if [ -n "${CERT_FILE}" ] && [ -s "$CERT_FILE" ] && [ -n "${CERT_KEY}" ] && [ -s "$CERT_KEY" ]; then
    return 0
  fi
  command -v openssl >/dev/null 2>&1 || error " 需要 openssl 生成自签证书（ArgoX 一般已装）。"
  local _d="$WORK_DIR/cert"
  mkdir -p "$_d"
  info " 正在生成自签证书（CN=$TLS_SERVER）..."
  openssl ecparam -genkey -name prime256v1 -out "$_d/private.key" 2>/dev/null
  cat > "$_d/cert.conf" << EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $TLS_SERVER
[v3]
subjectAltName = @alt
[alt]
DNS = $TLS_SERVER
EOF
  openssl req -new -x509 -days 36500 -key "$_d/private.key" -out "$_d/cert.pem" \
    -config "$_d/cert.conf" -subj "/CN=$TLS_SERVER" -extensions v3 2>/dev/null
  rm -f "$_d/cert.conf"
  [ -s "$_d/cert.pem" ] || error " 生成证书失败。"
  CERT_FILE="$_d/cert.pem"
  CERT_KEY="$_d/private.key"
}

# ---------------------------------------------------------------------------
# 生成 v6 入站（listen 绑本机 IPv6 地址）
# ---------------------------------------------------------------------------
build_block() {   # $1=fam $2=letter $3=port $4=uuid/pass $5=pass(ss)
  local _fam="$1" _l="$2" _port="$3" _cred="$4" _pass="$5" _tag _path _listen
  _tag=$(item_tag "$_fam" "$_l")
  _path="argoxv6-v$_fam-$_l"
  # v6：绑本机公网 IPv6；v4：统一 0.0.0.0（与 v2.0.0 的 v4 加固思路一致，换 IP 也不慌）
  if [ "$_fam" = '4' ]; then _listen='0.0.0.0'; else _listen="$V6_BIND"; fi
  case "$_l" in
    b) cat << JSONEOF
    {
      "tag": "$_tag",
      "listen": "$_listen",
      "port": $_port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$_cred", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$TLS_SERVER:443",
          "xver": 0,
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
      "listen": "$_listen",
      "port": $_port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$_cred", "flow": "" } ],
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
      "listen": "$_listen",
      "port": $_port,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [ { "auth": "$_cred" } ]
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
      "listen": "$_listen",
      "port": $_port,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$_cred" } ],
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
      "listen": "$_listen",
      "port": $_port,
      "protocol": "trojan",
      "settings": {
        "clients": [ { "password": "$_cred" } ]
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
      "listen": "$_listen",
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

rebuild_json() {
  local _blocks='' _sep='' _it _f _l _port _uuid _pass

  # 有 v6 条目但没探测到 IPv6 地址时不能生成（空 listen = 双栈，会踩 ArgoX 的端口）
  if [ -z "$V6_BIND" ] && grep -q '^ITEM_6_' "$V6_CONF" 2>/dev/null; then
    warning " 未获取到本机 IPv6 地址，已跳过配置生成（现有 v6 节点不动）。"
    return 1
  fi

  while IFS= read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    _f="$1" _l="$2" _port="$3"
    _uuid=$(conf_get "$(item_key "$_f" "$_l" UUID)")
    _pass=$(conf_get "$(item_key "$_f" "$_l" PASS)")
    _blocks="$_blocks$_sep$(build_block "$_f" "$_l" "$_port" "$_uuid" "$_pass")"
    _sep=$',\n'
  done <<< "$(list_items)"

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

  if ! "$JQ" empty "$V6_JSON" >/dev/null 2>&1; then
    warning " 生成 $V6_JSON 失败（JSON 无效）。诊断：$JQ empty $V6_JSON"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 同步：钉 v4-only → （必要时）重启 → 热挂 v6
# ---------------------------------------------------------------------------
verify_v6() {
  local _it _f _l _tag _live _ok=0 _bad=0
  local _lf="$WORK_DIR/.v6live.$$"
  live_tags_file "$_lf"
  while IFS= read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    _f="$1" _l="$2"
    _tag=$(item_tag "$_f" "$_l")
    if grep -qxF "$_tag" "$_lf" 2>/dev/null; then
      _ok=$((_ok + 1))
    else
      _bad=$((_bad + 1))
      warning "   ✗ 未挂载：$(proto_desc "$_l")（端口 $3）"
    fi
  done <<< "$(list_items)"
  rm -f "$_lf"
  [ "$_ok" -gt 0 ] && info "   ✓ 已挂载 v6 协议：$_ok 个"
  [ "$_bad" = '0' ]
}

sync_all() {
  local _ret=0
  rebuild_json || return 1

  ensure_hooks

  # 1) 钉 v4-only + 校正 v6 地址
  [ -x "$HOOK" ] || write_hook
  local _before _after
  _before=$(md5sum "$IB" 2>/dev/null | awk '{print $1}')
  rm -f "$FLAG" 2>/dev/null
  "$HOOK" pre >/dev/null 2>&1
  _after=$(md5sum "$IB" 2>/dev/null | awk '{print $1}')

  # 2) 需要重启吗
  local _need_restart='no'
  xray_active || _need_restart='yes'
  [ -f "$FLAG" ] && _need_restart='yes'
  if [ "$_before" != "$_after" ] && [ -n "$_before" ]; then _need_restart='yes'; fi

  if [ "$_need_restart" = 'yes' ]; then
    if [ "$_before" != "$_after" ] && [ -n "$_before" ]; then
      info " ArgoX 的入站已加固为 IPv4-only，重启 Xray 生效..."
    else
      info " 重启 Xray ..."
    fi
    rm -f "$FLAG" 2>/dev/null
    restart_xray || _ret=1
  fi

  # 3) 热挂 v6 入站
  api_ready || { warning " Xray API 未就绪，v6 入站暂时无法挂载。"; return 1; }
  "$HOOK" post >/dev/null 2>&1
  sleep 0.3
  verify_v6 || _ret=1
  return $_ret
}

# ---------------------------------------------------------------------------
# 防火墙（只放行 v6 侧端口）
# ---------------------------------------------------------------------------
fw_backend() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then echo ufw
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then echo firewalld
  elif command -v ip6tables >/dev/null 2>&1 || command -v iptables >/dev/null 2>&1; then echo netfilter
  else echo none; fi
}

fw_protos() {
  case "$1" in
    c) echo 'udp' ;;
    k|m) echo 'tcp udp' ;;
    *) echo 'tcp' ;;
  esac
}

persist_iptables() {
  if [ -d /etc/iptables ]; then
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
  elif command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

# 同地址族的 netfilter 命令：v4 -> iptables，v6 -> ip6tables
fw_bin_for() { [ "$1" = '4' ] && echo iptables || echo ip6tables; }

fw_allow() {   # $1=fam $2=letter $3=port
  local _f="$1" _l="$2" _p="$3" _be _t _bin
  _be=$(fw_backend)
  _bin=$(fw_bin_for "$_f")
  for _t in $(fw_protos "$_l"); do
    case "$_be" in
      ufw) ufw allow "$_p/$_t" comment "argoxv6" >/dev/null 2>&1 ;;
      firewalld) firewall-cmd --permanent --add-port="$_p/$_t" >/dev/null 2>&1 ;;
      netfilter)
        command -v "$_bin" >/dev/null 2>&1 || continue
        "$_bin" -C INPUT -p "$_t" --dport "$_p" -m comment --comment "argoxv6" -j ACCEPT 2>/dev/null \
          || "$_bin" -I INPUT -p "$_t" --dport "$_p" -m comment --comment "argoxv6" -j ACCEPT 2>/dev/null ;;
    esac
  done
  [ "$_be" = 'firewalld' ] && firewall-cmd --reload >/dev/null 2>&1
  [ "$_be" = 'netfilter' ] && persist_iptables
  [ "$_be" = 'none' ] && hint " 未检测到防火墙，请自行放行 $(fam_label "$_f") 端口 $_p"
  return 0
}

fw_deny() {    # $1=fam $2=letter $3=port
  local _f="$1" _l="$2" _p="$3" _be _t _bin
  _be=$(fw_backend)
  _bin=$(fw_bin_for "$_f")
  for _t in $(fw_protos "$_l"); do
    case "$_be" in
      ufw) ufw delete allow "$_p/$_t" >/dev/null 2>&1 ;;
      firewalld) firewall-cmd --permanent --remove-port="$_p/$_t" >/dev/null 2>&1 ;;
      netfilter)
        command -v "$_bin" >/dev/null 2>&1 || continue
        "$_bin" -D INPUT -p "$_t" --dport "$_p" -m comment --comment "argoxv6" -j ACCEPT 2>/dev/null ;;
    esac
  done
  [ "$_be" = 'firewalld' ] && firewall-cmd --reload >/dev/null 2>&1
  [ "$_be" = 'netfilter' ] && persist_iptables
  return 0
}

# ---------------------------------------------------------------------------
# 节点链接
# ---------------------------------------------------------------------------
build_link() {   # $1=fam $2=letter $3=port $4=uuid $5=pass
  local _f="$1" _l="$2" _port="$3" _cred="$4" _pass="$5" _h _n
  if [ "$_f" = '4' ]; then
    _h=$(host_for_link "${V4_PUB:-$SERVER_IP}")
  else
    _h=$(host_for_link "${V6_PUB:-$V6_BIND}")
  fi
  _n=$(item_tag "$_f" "$_l")
  _n=${_n// /%20}
  case "$_l" in
    b) echo "vless://${_cred}@${_h}:${_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${TLS_SERVER}&fp=${FINGER_PRINT}&pbk=${REALITY_PUBLIC}&type=tcp&headerType=none#${_n}" ;;
    d) echo "vless://${_cred}@${_h}:${_port}?encryption=none&security=reality&sni=${TLS_SERVER}&fp=${FINGER_PRINT}&pbk=${REALITY_PUBLIC}&type=grpc&serviceName=grpc&mode=multi#${_n}" ;;
    c) echo "hysteria2://${_cred}@${_h}:${_port}/?sni=${TLS_SERVER}&insecure=1&alpn=h3#${_n}" ;;
    k) echo "vless://${_cred}@${_h}:${_port}?encryption=none&security=tls&sni=${TLS_SERVER}&allowInsecure=1&fp=${FINGER_PRINT}&alpn=h3&type=xhttp&path=%2Fargoxv6-${_l}&mode=stream-up#${_n}" ;;
    l) echo "trojan://${_cred}@${_h}:${_port}?security=tls&sni=${TLS_SERVER}&allowInsecure=1&fp=${FINGER_PRINT}#${_n}" ;;
    m) local _b64
       _b64=$(printf '2022-blake3-aes-128-gcm:%s' "$_pass" | base64 | tr -d '\n')
       echo "ss://${_b64}@${_h}:${_port}#${_n}" ;;
  esac
}

show_links() {
  local _it _f _l _port _uuid _pass _all='' _any='no' _fam _cnt _link
  for _fam in 4 6; do
    _cnt=0
    while IFS= read -r _it; do
      [ -z "$_it" ] && continue
      set -- $_it
      [ "$1" = "$_fam" ] || continue
      _f="$1" _l="$2" _port="$3"
      _uuid=$(conf_get "$(item_key "$_f" "$_l" UUID)")
      _pass=$(conf_get "$(item_key "$_f" "$_l" PASS)")
      if [ "$_cnt" -eq 0 ]; then
        echo ''
        if [ "$_fam" = '4' ]; then
          info "============ IPv4 节点（listen 0.0.0.0，公网 ${V4_PUB:-未探测}）============"
        else
          info "============ IPv6 节点（listen ${V6_BIND:-未检测到}）============"
        fi
      fi
      _cnt=$((_cnt + 1)); _any='yes'
      _link=$(build_link "$_f" "$_l" "$_port" "$_uuid" "$_pass")
      plain "$(proto_desc "$_l")  ·  端口 $_port"
      plain "$_link"
      _all="$_all$_link"$'\n'
      echo ''
    done <<< "$(list_items)"
  done
  [ "$_any" = 'no' ] && { hint " 还没有配置任何节点（菜单 2 加 IPv6，菜单 3 双栈一起加）。"; return 0; }

  # 合并订阅：一次导入全部 IPv4 + IPv6 节点
  local _blob
  _blob=$(printf '%s' "$_all" | base64 -w0 2>/dev/null || printf '%s' "$_all" | base64)
  echo ''
  info "============ 全部节点 Base64 订阅（同时含 IPv4 + IPv6）============"
  plain "$_blob"
  echo ''
  hint " 可将整串 Base64 作为订阅内容导入（Clash / v2rayN / Shadowrocket 等）。"
  return 0
}

# ---------------------------------------------------------------------------
# 动作：添加 / 删除 / 刷新 / 状态 / 调用 ArgoX / 卸载
# ---------------------------------------------------------------------------
add_one() {   # $1=fam $2=letter [$3=port（双栈时由调用方给定）]
  local _f="$1" _l="$2" _given="${3:-}" _old _port _uuid _pass=''
  _old=$(conf_get "$(item_key "$_f" "$_l" PORT)")
  if [ -n "$_old" ]; then
    hint " 已存在 $(fam_label "$_f") $(proto_desc "$_l")（端口 $_old），将覆盖。"
  fi

  if [ -n "$_given" ]; then
    _port="$_given"
  else
    local _sug
    _sug=$(suggest_port "$_f")
    [ -n "$_old" ] && _sug="$_old"
    reading " $(proto_desc "$_l") 端口（回车用推荐值）" _port "$_sug"
  fi
  if ! [[ "$_port" =~ ^[0-9]+$ ]]; then warning " 端口无效：$_port"; return 1; fi
  if [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ]; then warning " 端口超出范围：$_port"; return 1; fi
  if [ "$_port" != "$_old" ] && is_port_conflict "$_port" "$_f"; then
    warning " 端口 $_port 在 $(fam_label "$_f") 侧已被占用（ArgoX 或本机其他服务），已跳过 $(proto_desc "$_l")。"
    return 1
  fi

  _uuid=$(conf_get "$(item_key "$_f" "$_l" UUID)")
  [ -z "$_uuid" ] && _uuid=$(gen_uuid)
  if [ "$_l" = 'm' ]; then
    _pass=$(conf_get "$(item_key "$_f" "$_l" PASS)")
    [ -z "$_pass" ] && _pass=$(rand_b64_16)
  fi

  case "$_l" in
    b|d) ensure_reality ;;
    c|k|l) ensure_cert ;;
  esac

  write_conf "$(item_key "$_f" "$_l" PORT)" "$_port"
  write_conf "$(item_key "$_f" "$_l" UUID)" "$_uuid"
  [ "$_l" = 'm' ] && write_conf "$(item_key "$_f" "$_l" PASS)" "$_pass"
  write_conf 'NODE_NAME' "$NODE_NAME"

  fw_allow "$_f" "$_l" "$_port"
  echo ''
  if [ "$_f" = '4' ]; then
    info " ✓ 已加入 IPv4：$(proto_desc "$_l")  →  0.0.0.0:${_port}"
  else
    info " ✓ 已加入 IPv6：$(proto_desc "$_l")  →  [${V6_BIND}]:${_port}"
  fi
  return 0
}

add_protocol() {   # $1=fam: 6（默认）| 4 | b（双栈：同一协议同时绑 v4+v6）
  local _fam="${1:-6}" _dual='no' _fams _f _l
  if [ "$_fam" = 'b' ]; then _dual='yes'; _fams='6 4'; else _fams="$_fam"; fi
  for _f in $_fams; do
    if [ "$_f" = '6' ]; then
      [ -n "$V6_BIND" ] || error " 本机没有可用的公网 IPv6 地址，v6 侧无法配置。"
    elif [ -z "$V4_PUB" ]; then
      hint " 未探测到公网 IPv4，v4 节点链接里的主机名可能缺失（可稍后执行菜单 6 重探）。"
    fi
  done

  echo ''
  if [ "$_dual" = 'yes' ]; then
    info "=========== 双栈添加：同一协议同时绑 IPv4 + IPv6 ==========="
    plain " · IPv4 侧 listen 0.0.0.0；IPv6 侧 listen ${V6_BIND}"
    plain " · 两侧可复用同一端口（不同地址族，socket 不冲突），两个节点链接一起输出"
  elif [ "$_fam" = '4' ]; then
    info "=========== 为 IPv4 设备添加协议（listen 0.0.0.0）==========="
  else
    info "=========== 为 IPv6 设备添加协议（绑定 $V6_BIND）==========="
  fi
  for _l in $PROTO_LETTERS; do hint " $_l. $(proto_desc "$_l")"; done
  hint " 可一次输入多个字母（如 bcdlm），a 或回车 = 全部"

  local _sel _letters _cnt=0
  while :; do
    reading " 选择协议" _sel
    _letters=$(parse_letters "$_sel")
    [ -n "$_letters" ] && break
    hint " 未识别，请重输（可选：$PROTO_LETTERS）"
  done

  # 协议个数
  local _n=0
  for _l in $_letters; do _n=$((_n + 1)); done

  # 起始端口：批量时只需给一次，其余协议依次顺延；回车 = 逐个确认
  local _base=''
  if [ -n "${START_PORT:-}" ]; then
    _base="$START_PORT"
  elif [ "$_n" -gt 1 ]; then
    reading " 起始端口（回车=逐个确认；填一个端口则本批协议依次顺延，如 12300）" _base ''
  fi
  if [ -n "$_base" ]; then
    if ! [[ "$_base" =~ ^[0-9]+$ ]] || [ "$_base" -lt 1 ] || [ "$_base" -gt 65535 ]; then
      warning " 起始端口无效：$_base，改为逐个确认。"
      _base=''
    fi
  fi

  local _port _sug _o _x _bad _cand _cursor="$_base" _exp="$_base"
  for _l in $_letters; do
    _port=''
    if [ -n "$_base" ]; then
      # 从游标往后找空闲端口：同批已写入 conf 的条目也会被 list_items 看到
      _cand="$_cursor"
      while :; do
        _bad='no'
        for _x in $_fams; do
          _o=$(conf_get "$(item_key "$_x" "$_l" PORT)")
          [ "$_cand" = "$_o" ] && continue
          is_port_conflict "$_cand" "$_x" && _bad='yes'
        done
        [ "$_bad" = 'no' ] && break
        _cand=$((_cand + 1))
        if [ "$_cand" -gt 65535 ]; then _cand=''; break; fi
      done
      if [ -z "$_cand" ]; then
        warning " 端口已用尽，跳过 $(proto_desc "$_l")。"
        continue
      fi
      _port="$_cand"
      _cursor=$((_port + 1))
      [ "$_port" != "$_exp" ] && hint " 端口 $_exp 已被占用，$(proto_desc "$_l") 顺延为 $_port"
      _exp=$((_port + 1))
    fi

    if [ "$_dual" = 'yes' ]; then
      if [ -z "$_port" ]; then
        # 双栈：只问一次端口，两侧复用；推荐值需在两侧都空闲
        _o=$(conf_get "$(item_key 6 "$_l" PORT)")
        if [ -n "$_o" ] && [ "$_o" = "$(conf_get "$(item_key 4 "$_l" PORT)")" ]; then
          _sug="$_o"
        else
          _sug=$(suggest_port_dual)
        fi
        reading " $(proto_desc "$_l") 双栈端口（回车用推荐值）" _port "$_sug"
        if ! [[ "$_port" =~ ^[0-9]+$ ]] || [ "$_port" -lt 1 ] || [ "$_port" -gt 65535 ]; then
          warning " 端口无效：$_port，已跳过 $(proto_desc "$_l")。"; continue
        fi
        # 两侧都先查冲突，避免只加了一半
        _bad='no'
        for _x in 6 4; do
          _o=$(conf_get "$(item_key "$_x" "$_l" PORT)")
          if [ "$_port" != "$_o" ] && is_port_conflict "$_port" "$_x"; then
            warning " 端口 $_port 在 $(fam_label "$_x") 侧已被占用，已跳过 $(proto_desc "$_l")。"
            _bad='yes'; break
          fi
        done
        [ "$_bad" = 'yes' ] && continue
      fi
      add_one 6 "$_l" "$_port" || continue
      add_one 4 "$_l" "$_port" || continue
      _cnt=$((_cnt + 1))
    else
      if [ -n "$_port" ]; then
        add_one "$_fam" "$_l" "$_port" || continue
      else
        add_one "$_fam" "$_l" || continue
      fi
      _cnt=$((_cnt + 1))
    fi
  done

  info " 正在应用（ArgoX 的 v4 直连入站不受影响）..."
  sync_all
  echo ''
  show_links
}

delete_protocol() {
  local _it _any='no'
  echo ''
  info "=========== 已配置的节点 ==========="
  while IFS= read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    hint " $(fam_label "$1")  |  $2 = $(proto_desc "$2")   端口 $3"
    _any='yes'
  done <<< "$(list_items)"
  [ "$_any" = 'no' ] && { hint " 尚未配置。"; return 0; }

  local _fs _l _fams _x _port _found _a _tag
  reading " 要删除的栈（4 / 6 / b=两栈一起删）" _fs
  reading " 要删除的协议字母" _l
  _l=$(parse_letters "$_l")
  [ -n "$_l" ] || error " 无效字母。"
  _l=${_l%% *}
  case "$_fs" in 4|6) _fams="$_fs" ;; b|B) _fams='6 4' ;; *) error " 栈只能是 4 / 6 / b。" ;; esac

  _found='no'
  for _x in $_fams; do
    [ -n "$(conf_get "$(item_key "$_x" "$_l" PORT)")" ] && _found='yes'
  done
  [ "$_found" = 'yes' ] || error " 未找到：$_fs 侧的 $(proto_desc "$_l")。"

  _a=$(api_addr) || true
  for _x in $_fams; do
    _port=$(conf_get "$(item_key "$_x" "$_l" PORT)")
    [ -n "$_port" ] || continue
    # 先从运行中的 xray 摘掉，再删配置
    if [ -n "$_a" ] && [ -x "$XRAY" ]; then
      _tag=$(item_tag "$_x" "$_l")
      "$XRAY" api rmi --server="$_a" "$_tag" >/dev/null 2>&1
    fi
    del_conf_prefix "ITEM_${_x}_${_l}_"
    fw_deny "$_x" "$_l" "$_port"
    info " 已删除 $(fam_label "$_x") 侧 $(proto_desc "$_l")（端口 $_port）。"
  done

  rebuild_json
  # 重挂剩下的
  if [ -x "$HOOK" ]; then "$HOOK" post >/dev/null 2>&1; fi
}

refresh_addr() {
  echo ''
  info " 正在重新探测公网地址 ..."
  local _changed='no'
  if detect_v6; then
    info " IPv6 地址已更新为：$V6_BIND"
    _changed='yes'
  else
    info " IPv6 地址未变化：${V6_BIND:-未检测到}"
  fi
  if detect_v4; then
    info " IPv4 公网地址已更新为：$V4_PUB"
    _changed='yes'
  else
    info " IPv4 公网地址：${V4_PUB:-未检测到}"
  fi
  if [ "$_changed" = 'yes' ]; then
    rebuild_json
    sync_all
  fi
}

status() {
  echo ''
  info "=============== argoxv6 状态 ==============="
  if argox_installed; then
    plain " ArgoX        : 已安装  ($WORK_DIR)"
  else
    plain " ArgoX        : 未安装"
  fi
  plain " 服务管理器   : $SYSINIT"
  plain " Xray 进程    : $(xray_active && echo 'running' || echo 'stopped')"
  if [ "$(v4_state)" = 'v4only' ]; then
    plain " IPv4 侧      : 已钉死 0.0.0.0（ArgoX 只听 IPv4）"
  else
    warning " IPv4 侧      : 双栈中（ArgoX 也能被 IPv6 访问）→ 菜单 5 修复"
  fi
  plain " IPv6 绑定    : ${V6_BIND:-未检测到}"
  plain " IPv6 公网    : ${V6_PUB:-同绑定地址}"
  plain " IPv4 公网    : ${V4_PUB:-未检测到}"
  plain " 开机守护     : $(hooks_installed && echo '已安装' || echo '未安装')"
  plain " 监听 API     : $(api_addr 2>/dev/null || echo '未找到')"
  echo ''
  plain " ArgoX 入站："
  v4_summary
  echo ''
  if [ -n "$(list_items)" ]; then
    plain " argoxv6 入站："
    local _it _lf="$WORK_DIR/.st.$$"
    live_tags_file "$_lf"
    while IFS= read -r _it; do
      [ -z "$_it" ] && continue
      set -- $_it
      local _ls="$V6_BIND"
      [ "$1" = '4' ] && _ls='0.0.0.0'
      if grep -qxF "$(item_tag "$1" "$2")" "$_lf" 2>/dev/null; then
        plain "   $3 | $_ls | $(fam_label "$1") | $(proto_desc "$2")  ✓ 运行中"
      else
        plain "   $3 | $_ls | $(fam_label "$1") | $(proto_desc "$2")  ✗ 未挂载"
      fi
    done <<< "$(list_items)"
    rm -f "$_lf"
  fi
  echo ''
}

# 调用 ArgoX 主脚本（v4 侧的唯一入口）
run_argox_script() {
  mkdir -p "$STATE_DIR"
  local _src=''
  info " 正在获取 ArgoX 主脚本 ..." >&2
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$ARGOX_URL" -o "$ARGOX_CACHE.new" 2>/dev/null && _src="$ARGOX_CACHE.new"
  fi
  if [ -z "$_src" ] && command -v wget >/dev/null 2>&1; then
    wget -qO "$ARGOX_CACHE.new" --timeout=30 --tries=2 "$ARGOX_URL" 2>/dev/null && _src="$ARGOX_CACHE.new"
  fi
  if [ -n "$_src" ] && [ -s "$_src" ]; then
    head -n 1 "$_src" | grep -q '#!' && mv -f "$_src" "$ARGOX_CACHE"
  fi
  rm -f "$ARGOX_CACHE.new"
  if [ -s "$ARGOX_CACHE" ]; then
    bash "$ARGOX_CACHE"
    return $?
  fi
  warning " 下载失败，尝试在线执行 ..." >&2
  if command -v curl >/dev/null 2>&1; then
    bash <(curl -fsSL "$ARGOX_URL")
  else
    bash <(wget -qO- "$ARGOX_URL")
  fi
}

manage_v4() {
  echo ''
  info "=========== 进入 ArgoX 管理 IPv4 节点 ==========="
  plain " · 这里添加/修改的节点都是 IPv4 侧（直连入站会被钉成 0.0.0.0）"
  plain " · 隧道类节点（WS/XHTTP）由 Cloudflare 边缘接入，v4/v6 设备都能用"
  plain " · 退出 ArgoX 后会自动同步，把 v6 入站挂回来"
  echo ''
  run_argox_script
  echo ''
  info "=========== 回到 argoxv6，开始同步 ==========="
  detect_v6 >/dev/null 2>&1 || true
  if ! argox_installed; then
    warning " ArgoX 尚未安装完成，跳过同步。"
    return 1
  fi
  sync_all
  echo ''
  show_links
}

uninstall_all() {
  echo ''
  warning " 即将卸载 argoxv6（只删它自己加的东西）："
  plain "   · 摘掉所有 argoxv6 入站（IPv4 + IPv6）"
  plain "   · 移除开机守护（systemd drop-in / OpenRC 服务）"
  plain "   · 关闭它为两栈放行的防火墙端口"
  plain "   · 可选：把 ArgoX 还原为原生双栈监听"
  echo ''
  local _ok
  reading " 确认卸载？(y/n)" _ok 'n'
  [ "$_ok" = 'y' ] || { hint " 已取消。"; return 0; }

  # 1) 摘 v6 入站
  local _a _it _f _l
  _a=$(api_addr) || true
  if [ -n "$_a" ] && [ -x "$XRAY" ]; then
    while IFS= read -r _it; do
      [ -z "$_it" ] && continue
      set -- $_it
      "$XRAY" api rmi --server="$_a" "$(item_tag "$1" "$2")" >/dev/null 2>&1
    done <<< "$(list_items)"
    # 顺手清理历史残留
    local _lf="$WORK_DIR/.un.$$"
    live_tags_file "$_lf"
    while IFS= read -r _f; do
      case "$_f" in *argoxv6*) "$XRAY" api rmi --server="$_a" "$_f" >/dev/null 2>&1 ;; esac
    done < "$_lf"
    rm -f "$_lf"
    info " 已摘除 IPv6 入站。"
  fi

  # 2) 防火墙
  while IFS= read -r _it; do
    [ -z "$_it" ] && continue
    set -- $_it
    fw_deny "$1" "$2" "$3"
  done <<< "$(list_items)"

  # 3) 开机守护
  remove_hooks

  # 4) 是否还原 ArgoX 双栈
  local _keep='n'
  if [ "$(v4_state)" = 'v4only' ]; then
    reading " 是否把 ArgoX 还原为原生双栈监听？(y/n)" _keep 'n'
    if [ "$_keep" = 'y' ]; then
      v4_unpatch && info " 已还原 ArgoX 双栈监听（restart xray 生效）。"
      restart_xray
    else
      info " 保留 IPv4-only 监听（ArgoX 只听 IPv4）。"
    fi
  fi

  # 5) 删文件
  rm -f "$V6_JSON" "$V6_JSON.hash" "$V6_CONF" "$HOOK" "$WORK_DIR/.inbound.v4tmp" "$FLAG"
  rm -f "$WORK_DIR"/.v6live.* "$WORK_DIR"/.inbound.hook.* "$WORK_DIR"/.hooktags.* "$WORK_DIR"/.hooklive.* "$WORK_DIR"/.hookadi.* 2>/dev/null
  rm -rf "$STATE_DIR"
  info " argoxv6 已卸载，ArgoX 仍可正常使用。"
}

# ---------------------------------------------------------------------------
# 菜单
# ---------------------------------------------------------------------------
menu() {
  while :; do
    echo ''
    info "================= argoxv6 · 双栈分工 ================="
    if [ "$(v4_state)" = 'v4only' ]; then
      hint " ArgoX(v4) : 已钉死 IPv4-only ✓"
    else
      warning " ArgoX(v4) : 双栈中（建议执行 5 修复）"
    fi
    hint " IPv6 绑定 : ${V6_BIND:-未检测到}"
    hint " Xray      : $(xray_active && echo running || echo stopped)    开机守护: $(hooks_installed && echo 已装 || echo 未装)"
    echo " -----------------------------------------------------"
    hint " 1. 管理 IPv4 节点（调用 ArgoX 主脚本）"
    hint " 2. 为 IPv6 添加 / 更换协议"
    hint " 3. 双栈添加：同一协议同时出 IPv4 + IPv6 节点"
    hint " 4. 查看节点链接（IPv4 + IPv6，含 Base64 订阅）"
    hint " 5. 删除某个协议（栈可选 4 / 6 / b）"
    hint " 6. 一键同步 / 自检修复"
    hint " 7. 重新探测 IPv6 地址"
    hint " 8. 查看当前状态"
    hint " 9. 卸载 argoxv6"
    hint " 0. 退出"
    local _c
    reading " 请选择" _c
    case "$_c" in
      1) manage_v4 ;;
      2) add_protocol 6 ;;
      3) add_protocol b ;;
      4) show_links ;;
      5) delete_protocol ;;
      6) sync_all ;;
      7) refresh_addr ;;
      8) status ;;
      9) uninstall_all; return 0 ;;
      0) exit 0 ;;
      *) hint " 无效选项。" ;;
    esac
  done
}

main() {
  local _manual_v6='' _mode=''
  # 逐个扫描全部参数（-p 必须能与 -b / 菜单共存，不能遇到旗标就 break）
  while [ $# -gt 0 ]; do
    case "$1" in
      -6) _manual_v6="${2:-}"; shift 2 ;;
      -p) START_PORT="${2:-}"; shift 2 ;;
      -l|-s|-u|-b|-v|-h|--help)
        [ -z "$_mode" ] && _mode="$1"
        shift ;;
      *) shift ;;
    esac
  done
  if [ -n "$START_PORT" ]; then
    if ! [[ "$START_PORT" =~ ^[0-9]+$ ]] || [ "$START_PORT" -lt 1 ] || [ "$START_PORT" -gt 65535 ]; then
      warning " -p 端口无效：$START_PORT（已忽略）"
      START_PORT=''
    fi
  fi

  case "$_mode" in
    -v) echo 'argoxv6 v2.1.1'; exit 0 ;;
  esac

  load_argox
  if [ -n "$_manual_v6" ]; then
    is_v6 "$_manual_v6" || error " 不是合法 IPv6 地址：$_manual_v6"
    V6_OVERRIDE="$_manual_v6"
  fi

  detect_v6 >/dev/null 2>&1 || true
  if [ -n "${V6_OVERRIDE:-}" ]; then
    V6_BIND="$V6_OVERRIDE"
    V6_PUB="$V6_OVERRIDE"
    write_conf 'V6_BIND' "$V6_BIND"
    write_conf 'V6_PUB' "$V6_PUB"
  fi
  [ -n "$V6_BIND" ] || warning " 未检测到公网 IPv6，v6 侧将不可用。"
  detect_v4 >/dev/null 2>&1 || true

  case "$_mode" in
    -l) show_links ;;
    -s) sync_all ;;
    -u) uninstall_all ;;
    -b) add_protocol b ;;
    -h|--help)
      sed -n '2,60p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true
      ;;
    *)
      if [ -n "$(list_items)" ] && [ "$(v4_state)" = 'dual' ]; then
        hint " 提示：ArgoX 当前为双栈监听，v6 设备也能连到 v4 节点。"
        hint "       菜单 5 可一键加固为 IPv4-only。"
      fi
      menu
      ;;
  esac
}

main "$@"
