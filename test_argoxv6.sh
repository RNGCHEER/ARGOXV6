#!/usr/bin/env bash
# argoxv6.sh 在 WSL mock 环境下的集成测试
set -u
T=/tmp/argoxtest
rm -rf "$T"
mkdir -p "$T/bin" "$T/argox"
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
  ]
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

# ---- 假 xray：x25519 生成 + run -test 用 jq 校验每个 -c 文件 ----
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
esac
MOCKEOF
chmod +x "$A/xray"

# ---- 假 systemd unit ----
cat > "$T/xray.service" <<'MOCKEOF'
[Service]
Type=simple
ExecStart=/etc/argox/xray run -c /etc/argox/inbound.json -c /etc/argox/outbound.json
Restart=on-failure
MOCKEOF

# ---- 假 systemctl / wget / curl ----
cat > "$T/bin/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
echo "systemctl $*" >> /tmp/argoxtest/systemctl.log
exit 0
MOCKEOF
cat > "$T/bin/wget" <<'MOCKEOF'
#!/usr/bin/env bash
case " $* " in
  *" -6 "*) echo '{"ip":"2001:db8::1","country":"US","isp":"Mock"}' ;;
  *)       echo '{"ip":"192.0.2.10","country":"US","isp":"Mock"}' ;;
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

echo '=================== SESSION 1: 添加 v6-b / v4-c，看链接 ==================='
printf '1\nb\n\n3\n2\nc\n\n3\n0\n' | env PATH="$T/bin:$PATH" ARGOX_DIR="$A" XRAY_DAEMON_FILE="$T/xray.service" bash "$T/argoxv6.sh" 2>&1

echo ''
echo '=================== SESSION 1 后的状态 ==================='
echo '--- argoxv6.json (tags/listens/ports/protocols) ---'
jq '[.inbounds[] | {tag, listen, port, protocol}]' "$A/argoxv6.json"
echo '--- reality 密钥复用检查 ---'
jq -r '.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.privateKey' "$A/argoxv6.json"
echo '--- argoxv6.conf ---'
cat "$A/argoxv6.conf"
echo '--- xray.service (集成补丁) ---'
cat "$T/xray.service"
echo '--- systemctl.log ---'
cat "$T/systemctl.log"
echo '--- 证书 ---'
ls -la "$A/cert" 2>/dev/null || echo '(未生成)'

echo ''
echo '=================== SESSION 2: 删 v6-b，卸载 ==================='
printf '4\n6\nb\n7\ny\n0\n' | env PATH="$T/bin:$PATH" ARGOX_DIR="$A" XRAY_DAEMON_FILE="$T/xray.service" bash "$T/argoxv6.sh" 2>&1

echo ''
echo '=================== SESSION 2 后的状态 ==================='
echo '--- argoxv6.json ---'
cat "$A/argoxv6.json" 2>/dev/null || echo '(已删除)'
echo '--- argoxv6.conf ---'
cat "$A/argoxv6.conf" 2>/dev/null || echo '(已删除)'
echo '--- xray.service (应还原) ---'
cat "$T/xray.service"
echo '--- mock inbound.json 完好性 ---'
grep -vE '^[[:space:]]*//' "$A/inbound.json" | jq -r '[.inbounds[].tag] | join(",")'
