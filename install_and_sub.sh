#!/usr/bin/env bash
set -e

# =======================
# 生产级 2026 顶级代理一键部署脚本
# =======================

while true; do
    read -p "请输入你的 VPS 域名: " DOMAIN
    # 简单域名正则: 支持子域名、字母、数字和短横线
    if [[ $DOMAIN =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]]; then
        break
    else
        echo "错误: 域名格式不正确，请重新输入"
    fi
done

REALITY_PORT=443
HYSTERIA_PORT=8443

echo "======================"
echo "停止可能占用端口 80 的服务..."
systemctl stop nginx || true
systemctl stop apache2 || true
systemctl stop caddy || true

echo "======================"
echo "安装基础依赖..."
apt update -y
apt install -y curl wget openssl uuid-runtime socat certbot jq

# =======================
# 开启 BBR
# =======================
echo "开启 BBR..."
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p

# =======================
# Xray 安装与配置
# =======================
echo "安装 Xray..."
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

UUID=$(uuidgen)
KEYS=$(xray x25519)
PRIVATE=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
PUBLIC=$(echo "$KEYS" | grep Password | awk '{print $2}')
SHORTID=$(openssl rand -hex 8)

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": $REALITY_PORT,
      "protocol": "vless",
      "settings": {
        "clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],
        "decryption":"none"
      },
      "streamSettings":{
        "network":"tcp",
        "security":"reality",
        "realitySettings":{
          "show":false,
          "dest":"www.microsoft.com:443",
          "xver":0,
          "serverNames":["www.microsoft.com"],
          "privateKey":"$PRIVATE",
          "shortIds":["$SHORTID"],
          "fingerprint":"chrome"
        }
      }
    }
  ],
  "outbounds":[{"protocol":"freedom"}]
}
EOF

systemctl restart xray
systemctl enable xray

# =======================
# Sing-Box / Hysteria2 安装与配置
# =======================
echo "安装 Sing-Box (Hysteria2)..."
curl -fsSL https://sing-box.app/install.sh | bash

echo "申请 TLS 证书..."
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" || true

HY_PASS=$(openssl rand -hex 8)

mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "0.0.0.0",
      "listen_port": $HYSTERIA_PORT,
      "users": [
        {"password": "$HY_PASS"}
      ],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
      },
      "obfs": {
        "type": "salamander",
        "password": "$HY_PASS"
      }
    }
  ],
  "outbounds": [
    {"type": "direct","tag": "direct"}
  ]
}
EOF

systemctl enable sing-box
systemctl restart sing-box

# =======================
#  Clash 节点订阅
# =======================
echo ""
echo "=============================="
echo "部署完成，Clash 节点订阅："
echo ""

cat <<EOF
proxies:
- {name: Reality, server: $DOMAIN, port: $REALITY_PORT, type: vless, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: www.microsoft.com, client-fingerprint: chrome, reality-opts: {public-key: $PUBLIC, short-id: $SHORTID}}
- {name: Sing-Box, type: hysteria2, server: <DOMAIN>, port: <HYSTERIA_PORT>, password: <HY_PASS>, sni: <DOMAIN>, skip-cert-verify: false, up: 50, down: 500, obfs: salamander, obfs-password: <HY_PASS>}
EOF

echo ""
echo "=============================="
