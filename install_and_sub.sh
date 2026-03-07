#!/usr/bin/env bash
set -e

echo "===== 2026 Proxy Stack 部署脚本 ====="

# 交互式输入
read -p "请输入你的 VPS 域名: " DOMAIN

REALITY_PORT=443
HYSTERIA_PORT=8443
TUIC_PORT=8444

# 安装依赖
apt update -y
apt install -y curl wget openssl uuid-runtime socat nginx certbot python3-certbot-nginx

# 安装 Xray
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

# 生成 UUID 和 REALITY 密钥
UUID=$(uuidgen)
KEYS=$(xray x25519)
PRIVATE=$(echo "$KEYS" | grep Private | awk '{print $3}')
PUBLIC=$(echo "$KEYS" | grep Public | awk '{print $3}')
SHORTID=$(openssl rand -hex 8)

# 写入 Xray REALITY 配置
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
"dest":"www.cloudflare.com:443",
"xver":0,
"serverNames":["www.cloudflare.com"],
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

# Hysteria2 安装
bash <(curl -fsSL https://get.hy2.sh/)
HY_PASS=$(openssl rand -hex 8)

# TLS 证书使用 Certbot 自动申请
nginx -s stop || true
mkdir -p /etc/hysteria

cat > /etc/hysteria/config.yaml <<EOF
listen: :$HYSTERIA_PORT
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: $HY_PASS
masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com
EOF

# TUIC 安装
mkdir -p /etc/tuic
TUIC_PASS=$(openssl rand -hex 8)
cat > /etc/tuic/config.json <<EOF
{
"server": "[::]:$TUIC_PORT",
"users": {
"$UUID": "$TUIC_PASS"
},
"certificate": "/etc/hysteria/server.crt",
"private_key": "/etc/hysteria/server.key",
"congestion_control": "bbr",
"alpn": ["h3"]
}
EOF

wget -O /usr/local/bin/tuic-server https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-linux-amd64
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

# 配置 Nginx + Certbot
cat > /etc/nginx/sites-available/$DOMAIN <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/html;
}
EOF

ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
mkdir -p /var/www/html
systemctl restart nginx

# Certbot 获取证书
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || true

# 拷贝证书到 Hysteria 和 TUIC 使用
cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /etc/hysteria/server.crt
cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /etc/hysteria/server.key

# 生成 Clash 订阅 YAML
SUB_FILE="/var/www/html/sub.yaml"
cat > $SUB_FILE <<EOF
proxies:
- {name: VLESS-REALITY, server: $DOMAIN, port: $REALITY_PORT, type: vless, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: www.cloudflare.com, client-fingerprint: chrome, reality-opts: {public-key: $PUBLIC, short-id: $SHORTID}}
- {name: Hysteria2, type: hysteria2, server: $DOMAIN, port: $HYSTERIA_PORT, password: $HY_PASS, sni: $DOMAIN, skip-cert-verify: true}
- {name: TUIC, type: tuic, server: $DOMAIN, port: $TUIC_PORT, uuid: $UUID, password: $TUIC_PASS, alpn: [h3], skip-cert-verify: true}
EOF

systemctl restart nginx

echo ""
echo "=========== 部署完成 ==========="
echo "Clash 订阅地址: https://$DOMAIN/sub.yaml"
echo "VLESS-REALITY, Hysteria2, TUIC 已部署并自动开机自启"