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
TUIC_PORT=8444

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
# TUIC 安装与配置
# =======================
mkdir -p /etc/tuic
TUIC_PASS=$(openssl rand -hex 8)

cat > /etc/tuic/config.json <<EOF
{
  "server": "[::]:$TUIC_PORT",
  "users": {
    "$UUID": "$TUIC_PASS"
  },
  "certificate": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
  "private_key": "/etc/letsencrypt/live/$DOMAIN/privkey.pem",
  "congestion_control": "bbr",
  "alpn": ["h3"]
}
EOF

# 自动下载 TUIC 最新版本
# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_NAME="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) ARCH_NAME="aarch64-unknown-linux-gnu" ;;
    armv7l) ARCH_NAME="armv7-unknown-linux-gnueabihf" ;;
    i686) ARCH_NAME="i686-unknown-linux-gnu" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

# 从 GitHub API 获取最新版本、匹配架构的 URL，只取第一条
TUIC_LATEST=$(curl -s https://api.github.com/repos/tuic-protocol/tuic/releases/latest \
| jq -r ".assets[] | select(.name | test(\"$ARCH_NAME\")) | .browser_download_url" | head -n1)

if [[ -z "$TUIC_LATEST" ]]; then
    echo "无法获取 TUIC 下载链接，请检查 GitHub 发布页"
    exit 1
fi

wget -O /usr/local/bin/tuic-server "$TUIC_LATEST"
chmod +x /usr/local/bin/tuic-server

cat > /etc/systemd/system/tuic.service <<EOF
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tuic
systemctl start tuic

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
- {name: Hysteria2, type: hysteria2, server: $DOMAIN, port: $HYSTERIA_PORT, password: $HY_PASS, sni: $DOMAIN, skip-cert-verify: true}
- {name: TUIC, type: tuic, server: $DOMAIN, port: $TUIC_PORT, uuid: $UUID, password: $TUIC_PASS, alpn: [h3], skip-cert-verify: true}
EOF

echo ""
echo "=============================="
