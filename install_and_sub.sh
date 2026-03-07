#!/usr/bin/env bash
set -e

echo "=============================="
echo " 2026 Proxy Stack Installer"
echo " Reality + Hysteria2 + TUIC "
echo "=============================="

read -rp "请输入你的域名: " DOMAIN

if [ -z "$DOMAIN" ]; then
    echo "域名不能为空"
    exit 1
fi

REALITY_PORT=443
HY_PORT=8443
TUIC_PORT=8444

echo "域名: $DOMAIN"

# 安装依赖
apt update -y
apt install -y curl wget openssl uuid-runtime socat certbot jq

# 开启BBR
echo "开启BBR..."

if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p || true
fi

# =====================
# 申请证书
# =====================

echo "申请 TLS 证书..."

certbot certonly \
--standalone \
-d $DOMAIN \
--non-interactive \
--agree-tos \
-m admin@$DOMAIN

echo "证书申请成功"

# =====================
# 安装 Xray
# =====================

bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

UUID=$(uuidgen)

KEYS=$(xray x25519)
PRIVATE=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
PUBLIC=$(echo "$KEYS" | grep Password | awk '{print $2}')

SHORTID=$(openssl rand -hex 8)

mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
"log":{"loglevel":"warning"},
"inbounds":[
{
"port":$REALITY_PORT,
"protocol":"vless",
"settings":{
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
"shortIds":["$SHORTID"]
}
}
}
],
"outbounds":[{"protocol":"freedom"}]
}
EOF

systemctl enable xray
systemctl restart xray

# =====================
# 安装 sing-box
# =====================

curl -fsSL https://sing-box.app/install.sh | bash

HY_PASS=$(openssl rand -hex 8)

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
"log":{"level":"info"},
"inbounds":[
{
"type":"hysteria2",
"listen":"0.0.0.0",
"listen_port":$HY_PORT,
"users":[{"password":"$HY_PASS"}],
"tls":{
"enabled":true,
"server_name":"$DOMAIN",
"certificate_path":"/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
"key_path":"/etc/letsencrypt/live/$DOMAIN/privkey.pem"
}
}
],
"outbounds":[{"type":"direct"}]
}
EOF

systemctl enable sing-box
systemctl restart sing-box

# =====================
# 安装 TUIC
# =====================

mkdir -p /etc/tuic

TUIC_PASS=$(openssl rand -hex 8)

wget -O /usr/local/bin/tuic-server \
https://github.com/EAimTY/tuic/releases/latest/download/tuic-server-linux-amd64

chmod +x /usr/local/bin/tuic-server

cat > /etc/tuic/config.json <<EOF
{
"server":"[::]:$TUIC_PORT",
"users":{
"$UUID":"$TUIC_PASS"
},
"certificate":"/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
"private_key":"/etc/letsencrypt/live/$DOMAIN/privkey.pem",
"congestion_control":"bbr",
"alpn":["h3"]
}
EOF

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

# =====================
# 订阅
# =====================

mkdir -p /var/www/html

cat > /var/www/html/sub.yaml <<EOF
proxies:
- {name: Reality, server: $DOMAIN, port: $REALITY_PORT, type: vless, uuid: $UUID, network: tcp, tls: true, flow: xtls-rprx-vision, servername: www.microsoft.com, client-fingerprint: chrome, reality-opts: {public-key: $PUBLIC, short-id: $SHORTID}}

- {name: Hysteria2, type: hysteria2, server: $DOMAIN, port: $HY_PORT, password: $HY_PASS, sni: $DOMAIN, skip-cert-verify: true}

- {name: TUIC, type: tuic, server: $DOMAIN, port: $TUIC_PORT, uuid: $UUID, password: $TUIC_PASS, alpn: [h3], skip-cert-verify: true}
EOF

nohup socat TCP-LISTEN:80,fork FILE:/var/www/html/sub.yaml &>/dev/null &

echo ""
echo "=============================="
echo "安装完成"
echo ""
echo "订阅地址:"
echo "http://$DOMAIN/sub.yaml"
echo ""
echo "Reality UUID:"
echo "$UUID"
echo "=============================="
