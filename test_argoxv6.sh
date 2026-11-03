#!/usr/bin/env bash
# argoxv6.sh v2.1.0 在 WSL mock 环境下的集成测试
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

RUN() { env PATH="$T/bin:$PATH" ARGOX_DIR="$A" SYSTEMD_DIR="$T/systemd" INITD_DIR="$T/initd" ARGOXV6_FLAG="$T/flag" bash "$T/argoxv6.sh" -6 2001:db8::1 "$@"; }

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
printf '3\nbm\n\n\n4\n0\n' | RUN 2>&1 | grep -E '双栈|已加入|Base64|vless://|ss://|hysteria2://|trojan://|无效|已被占用'
echo '--- 监听核对（同一协议 v4/v6 不同 listen）---'
jq -r '.inbounds[] | "\(.listen)\t\(.port)\t\(.tag)"' "$A/argoxv6.json"

echo ''
echo '=================== SESSION 3: a = 全部添加（v6） ==================='
printf '2\na\n\n\n\n\n\n\n0\n' | RUN 2>&1 | grep -E '已加入' | head -8

echo ''
echo '=================== SESSION 4: 无 ArgoX（非交互）应明确报错 ==================='
rm -rf "$T/noargox"
printf '' | env PATH="$T/bin:$PATH" ARGOX_DIR="$T/noargox" SYSTEMD_DIR="$T/systemd" INITD_DIR="$T/initd" ARGOXV6_FLAG="$T/flag" bash "$T/argoxv6.sh" 2>&1 | head -5

echo ''
echo '=================== SESSION 5: 删除 b（双栈一起）+ 卸载 ==================='
printf '5\nb\nb\n9\ny\n' | RUN 2>&1 | grep -E '已删除|卸载|未找到|残留'

echo ''
echo '=================== SESSION 5 后的状态 ==================='
echo '--- argoxv6.json ---'
cat "$A/argoxv6.json" 2>/dev/null || echo '(已删除)'
echo '--- argoxv6.conf ---'
cat "$A/argoxv6.conf" 2>/dev/null || echo '(已删除)'
echo '--- ArgoX inbound.json 完好性 ---'
jq -r '[.inbounds[].tag] | join(",")' "$A/inbound.json"
echo '--- drop-in / hook 残留 ---'
ls "$T/systemd" 2>/dev/null; ls "$A/argoxv6-hook.sh" 2>/dev/null || echo '(hook 已清理)'