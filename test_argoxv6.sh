#!/usr/bin/env bash
# argoxv6.sh v2.1.4 在 WSL mock 环境下的集成测试
set -u
T=/tmp/argoxtest
rm -rf "$T"
mkdir -p "$T/bin" "$T/argox" "$T/systemd" "$T/initd"
A="$T/argox"

# 归一化 CRLF
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
sed 's/\r$//' "$SCRIPT_DIR/argoxv6.sh" > "$T/argoxv6.sh"

# ---- mock ArgoX 目录 ----
cat > "$A/inbound.json" <<'MOCKEOF'
{
  // mock ArgoX inbound
  "inbounds": [
    {
      "tag": "reality-vision",
      "port": 30001,
      "protocol": "vless",
      "settings": { "clients": [ { "id": "11111111-2222-3333-4444-555555555555", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "addons.mozilla.org:443",
          "serverNames": [ "addons.mozilla.org" ],
          "privateKey": "MOCK_PRIVATE_KEY",
          "publicKey": "MOCK_PUBLIC_KEY",
          "shortIds": [ "" ]
        }
      }
    },
    {
      "tag": "hysteria2",
      "port": 30002,
      "protocol": "hysteria",
      "settings": { "version": 2, "clients": [ { "auth": "mockauth" } ] },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverNames": [ "addons.mozilla.org" ],
          "alpn": [ "h3" ],
          "certificates": [ { "certificateFile": "/etc/argox/cert/cert.pem", "keyFile": "/etc/argox/cert/private.key" } ]
        }
      }
    }
  ],
  "api": { "listen": "127.0.0.1:10085" }
}
MOCKEOF
echo '{ "outbounds": [ { "protocol": "freedom", "tag": "direct" } ] }' > "$A/outbound.json"
cat > "$A/custom" <<'MOCKEOF'
language='en'
serverIp='192.0.2.10'
privateKey='MOCK_PRIVATE_KEY'
publicKey='MOCK_PUBLIC_KEY'
cdn='www.visa.com'
MOCKEOF

# ---- 假 xray：x25519 / run -test / api lsi（模拟热挂载查询） ----
cat > "$A/xray" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1" in
  x25519)
    echo "Private key: MOCKGEN_PRIVATE"
    echo "Public key: MOCKGEN_PUBLIC" ;;
  run)
    shift
    f=''
    for a in "$@"; do
      if [ "$a" = "-c" ]; then f='next'; elif [ "$f" = "next" ]; then
        grep -vE '^[[:space:]]*//' "$a" | jq empty 2>/dev/null || { echo "bad json: $a"; exit 1; }
        f=''
      fi
    done
    echo "config test ok" ;;
  api)
    shift
    case " $* " in
      *lsi*)
        [ -s /tmp/argoxtest/argox/argoxv6.json ] && jq -r '.inbounds[]?.tag // empty' /tmp/argoxtest/argox/argoxv6.json 2>/dev/null
        ;;
    esac
    exit 0 ;;
esac
MOCKEOF
chmod +x "$A/xray"

# ---- 假 systemd / systemctl / wget / curl ----
cat > "$T/bin/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "systemctl $*" >> /tmp/argoxtest/systemctl.log
exit 0
MOCKEOF
cat > "$T/bin/wget" <<'MOCKEOF'
#!/usr/bin/env bash
case " $* " in
  *argox.sh*) cat /tmp/argoxtest/fake_argox_install.sh ;;
  *" -6 "*)   echo '2001:db8::1' ;;
  *)          echo '192.0.2.10' ;;
esac
MOCKEOF
cat > "$T/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
case " $* " in
  *" -6 "*) echo '2001:db8::1' ;;
  *)       echo '192.0.2.10' ;;
esac
MOCKEOF
chmod +x "$T/bin/"*

RUN() { env PATH="$T/bin:$PATH" ARGOX_DIR="$A" SYSTEMD_DIR="$T/systemd" INITD_DIR="$T/initd" ARGOXV6_FLAG="$T/flag" ARGOXV6_BIN_DIR="$T/bin_install" bash "$T/argoxv6.sh" -6 2001:db8::1 "$@"; }

echo '=================== SESSION 1: 添加 v6-b，看链接 ==================='
printf '2\nb\n\n4\n0\n' | RUN 2>&1 | tail -22

echo ''
echo '=================== SESSION 1 后的状态 ==================='
echo '--- argoxv6.json ---'
jq -c '[.inbounds[] | {tag, listen, port, protocol}]' "$A/argoxv6.json" 2>/dev/null || echo '(无)'
echo '--- ArgoX inbound.json 是否被钉成 0.0.0.0（v4-only）---'
jq -r '[.inbounds[] | "\(.tag):\(.listen // "双栈")"] | join(" , ")' "$A/inbound.json"

echo ''
echo '=================== SESSION 2: 双栈添加 b/m（v4+v6，两侧链接一起出） ==================='
printf '3\nbm\n\n\n\n4\n0\n' | RUN 2>&1 | grep -E '双栈|已加入|Base64|vless://|ss://|hysteria2://|trojan://|无效|已被占用'
echo '--- 监听核对（同一协议 v4/v6 不同 listen）---'
jq -r '.inbounds[] | "\(.listen)\t\(.port)\t\(.tag)"' "$A/argoxv6.json"

echo ''
echo '=================== SESSION 2b: 起始端口顺延（双栈 cm，起始 40000） ==================='
printf '3\ncm\n40000\n4\n0\n' | RUN 2>&1 | grep -E '顺延|已加入|无效|已被占用'
echo '--- 40000/40001 是否落在两栈 ---'
jq -r '.inbounds[] | select(.port >= 40000) | "\(.listen)\t\(.port)"' "$A/argoxv6.json"

echo ''
echo '=================== SESSION 2c: 单协议指定端口（v6 b = 65000） ==================='
printf '2\nb\n65000\n4\n0\n' | RUN 2>&1 | grep -E '已加入|无效'
jq -r '.inbounds[] | select(.listen != "0.0.0.0") | select(.port == 65000) | "\(.listen)\t\(.port)\t\(.tag)"' "$A/argoxv6.json"

echo ''
echo '=================== SESSION 2d: -b -p 36800（CLI 指定起始端口，双栈） ==================='
printf 'l\n' | RUN -b -p 36800 2>&1 | grep -E '已加入|无效' | head -3
jq -r '.inbounds[] | select(.port == 36800) | "\(.listen)\t\(.port)"' "$A/argoxv6.json"

echo ''
echo '=================== SESSION 3: a = 全部添加（v6） ==================='
printf '2\na\n\n\n\n\n\n\n\n0\n' | RUN 2>&1 | grep -E '已加入' | head -8

echo ''
echo '=================== SESSION 4: 无 ArgoX（非交互）应明确报错 ==================='
rm -rf "$T/noargox"
printf '' | env PATH="$T/bin:$PATH" ARGOX_DIR="$T/noargox" SYSTEMD_DIR="$T/systemd" INITD_DIR="$T/initd" ARGOXV6_FLAG="$T/flag" bash "$T/argoxv6.sh" 2>&1 | head -5

echo '=================== SESSION 5a: 删除前先列编号；非法输入只重问、取消不落地 ==================='
printf '5\nx\n1\nn\n0\n' | RUN 2>&1 | grep -E '已配置的节点|[0-9]+\) |只能输入序号|将要删除|已取消|已删除'
echo '--- conf 条目数（取消后应保持不变）---'
grep -c '^ITEM_' "$A/argoxv6.conf"

echo ''
echo '=================== SESSION 5b: 按序号删 1 个（y 确认） ==================='
printf '5\n1\ny\n0\n' | RUN 2>&1 | grep -E '已删除|剩余节点'
echo '--- conf 条目数（应减 1 组）---'
grep -c '^ITEM_' "$A/argoxv6.conf"

echo ''
echo '=================== SESSION 5c: a=全部删除 + 卸载 ==================='
printf '5\na\ny\n9\ny\n' | RUN 2>&1 | grep -E '将要删除|已删除|没有 argoxv6 节点|卸载|残留'
echo '--- argoxv6.json ---'
cat "$A/argoxv6.json" 2>/dev/null || echo '(已删除)'
echo '--- argoxv6.conf ---'
cat "$A/argoxv6.conf" 2>/dev/null || echo '(已删除)'
echo '--- ArgoX inbound.json 完好性 ---'
jq -r '[.inbounds[].tag] | join(",")' "$A/inbound.json"
echo '--- drop-in / hook 残留 ---'
ls "$T/systemd" 2>/dev/null; ls "$A/argoxv6-hook.sh" 2>/dev/null || echo '(hook 已清理)'

echo ''
echo '=================== SESSION 6: IPv6 地址探测（多地址 / 临时地址 / 探测到别的地址） ==================='
D6="$T/detect"; rm -rf "$D6"; mkdir -p "$D6/argox" "$D6/bin"
cp "$A/inbound.json" "$A/outbound.json" "$A/custom" "$A/xray" "$D6/argox/"
chmod +x "$D6/argox/xray"
cat > "$D6/bin/ip" <<'IPEOF'
#!/bin/sh
case "$*" in
  *"route get"*)
    echo '2606:4700:4700::1111 via fe80::1 dev eth0 src 2001:df6:11c0:3e2a::1015 metric 0 uid 0'
    echo '    cache expires in 597sec'
    ;;
  *"route show default"*) echo 'default via fe80::1 dev eth0 proto ra metric 600' ;;
  *"addr show"*)
    echo '1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 state UNKNOWN'
    echo '    inet6 ::1/128 scope host'
    echo '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP'
    echo '    inet6 fd00:aaaa::1/64 scope global'
    echo '    inet6 2001:df6:11c0:3e2a::1015/64 scope global'
    echo '    inet6 2001:df6:11c0:3e2a:abcd::9/64 scope global temporary dynamic'
    echo '    inet6 fe80::1/64 scope link'
    ;;
  *) echo '' ;;
esac
IPEOF
chmod +x "$D6/bin/ip"
cat > "$D6/bin/curl" <<'CEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in *icanhazip*|*ident.me*|*cloudflare*) echo '2001:db8::dead:beef'; exit 0 ;; esac
done
exit 1
CEOF
chmod +x "$D6/bin/curl"
D6RUN() { env PATH="$D6/bin:$T/bin:$PATH" ARGOX_DIR="$D6/argox" SYSTEMD_DIR="$T/systemd" INITD_DIR="$T/initd" ARGOXV6_FLAG="$T/flag" bash "$T/argoxv6.sh" "$@" 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g'; }
echo '--- -d 诊断输出 ---'
D6RUN -d | grep -E '监听地址|链接显示地址|出站源地址|本机全局|^   [0-9]\)|conf:|V6_'
echo '--- 添加一个 v6 节点后的链接 ---'
printf '2\nb\n36000\n4\n0\n' | D6RUN | grep -oE 'vless://[^ ]*' | head -1
echo '--- 断言：链接主机必须是 ::1015 ---'
_lnk=$(printf '2\nb\n36000\n4\n0\n' | D6RUN | grep -oE 'vless://[^ ]*' | head -1)
case "$_lnk" in
  *'[2001:df6:11c0:3e2a::1015]'*) echo ' ✓ 链接主机 = 2001:df6:11c0:3e2a::1015' ;;
  *) echo ' ✗ 链接主机错误:' "$_lnk" ;;
esac
echo ''
echo '=================== SESSION 7: argoxv6 命令（自安装 / 直接进入 / 版本更新 / 卸载删除） ==================='
BIN="$T/bin_install"; rm -rf "$BIN"; mkdir -p "$BIN"
BINRUN() { env PATH="$BIN:$T/bin:$PATH" ARGOX_DIR="$A" SYSTEMD_DIR="$T/systemd" INITD_DIR="$T/initd" ARGOXV6_FLAG="$T/flag" ARGOXV6_BIN_DIR="$BIN" bash "$T/argoxv6.sh" "$@" 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g'; }
echo '--- 7a 菜单启动时自动安装命令 ---'
printf '0\n' | BINRUN | grep -E '已安装命令|已更新|argoxv6 命令'
echo -n "  文件: "; ls -l "$BIN/argoxv6" 2>/dev/null | awk '{print $1, $NF}' || echo "(未安装)"
echo -n "  版本: "; "$BIN/argoxv6" -v 2>/dev/null || echo "(无法执行)"
bash -n "$BIN/argoxv6" 2>/dev/null && echo "  语法: OK" || echo "  语法: 失败"
echo '--- 7b 直接输 argoxv6 进入菜单（不应重复安装）---'
printf '0\n' | env ARGOXV6_BIN_DIR="$BIN" PATH="$BIN:$T/bin:$PATH" ARGOX_DIR="$A" SYSTEMD_DIR="$T/systemd" INITD_DIR="$T/initd" "$BIN/argoxv6" 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g' | grep -E "argoxv6 · 双栈分工|已退出|命令      :" | head -5
echo '--- 7c 命令是旧版时自动更新（v2.0.9 → v2.1.4）---'
sed -i 's/^#  argoxv6\.sh  v2\.1\.4/#  argoxv6.sh  v2.0.9/' "$BIN/argoxv6"
printf '0\n' | BINRUN | grep -E "已更新|已安装命令"
echo -n "  更新后版本: "; "$BIN/argoxv6" -v
echo '--- 7d 卸载时删除命令 ---'
printf 'y\nn\n' | BINRUN -u | grep -E '已删除命令|已卸载'
ls "$BIN/argoxv6" 2>/dev/null || echo "  (命令已删除 ✓)"
