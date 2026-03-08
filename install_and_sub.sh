#!/usr/bin/env bash
set -e

echo "=============================="
echo "2026 三协议代理自动部署"
echo "Reality + Hysteria2 + TUIC"
echo "自动订阅版本"
echo "=============================="
while true; do
read -p "请输入你的域名: " DOMAIN
if [[ $DOMAIN =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]]; then
break
else
echo "域名格式错误"
fi
done

REALITY_PORT=8443
HY_PORT=5000
TUIC_PORT=8444

apt update -y
apt install -y curl wget uuid-runtime openssl certbot socat ufw jq

# BBR
grep -q "bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
grep -q "fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
sysctl -p

# 防火墙
ufw allow 22
ufw allow 80
ufw allow 443
ufw allow 8443
ufw allow 8444
ufw allow 5000
ufw --force enable

# =================
# Xray
# =================

bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

UUID=$(uuidgen)

KEYS=$(xray x25519)

PRIVATE=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
PUBLIC=$(echo "$KEYS" | grep Password | awk '{print $2}')

SHORTID=$(openssl rand -hex 8)

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
"dest":"www.microsoft.com:443",
"serverNames":["www.microsoft.com","www.cloudflare.com"],
"privateKey":"$PRIVATE",
"shortIds":["$SHORTID"]
}
}
}
],
"outbounds":[{"protocol":"freedom"}]
}
EOF

systemctl restart xray

# =================
# sing-box
# =================

curl -fsSL https://sing-box.app/install.sh | bash

certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || true

HY_PASS=$(openssl rand -hex 8)
TUIC_PASS=$(openssl rand -hex 8)

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
},

"obfs":{"type":"salamander","password":"$HY_PASS"}
},

{
"type":"tuic",
"listen":"0.0.0.0",
"listen_port":$TUIC_PORT,

"users":[{"uuid":"$UUID","password":"$TUIC_PASS"}],

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

# =================
# 订阅生成
# =================

mkdir -p /var/www/sub

cat > /var/www/sub/clash <<EOF
proxies:
- {name: Reality, server: $DOMAIN, port: $REALITY_PORT, type: vless, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: www.microsoft.com, client-fingerprint: chrome, reality-opts: {public-key: $PUBLIC, short-id: $SHORTID}}

- {name: Hysteria2, type: hysteria2, server: $DOMAIN, port: $HY_PORT, password: $HY_PASS, sni: $DOMAIN, skip-cert-verify: false, up: 50, down: 500, obfs: salamander, obfs-password: $HY_PASS}

- {name: TUIC, server: $DOMAIN, port: $TUIC_PORT, type: tuic, uuid: $UUID, password: $TUIC_PASS, sni: $DOMAIN, alpn: [h3], congestion-controller: bbr, skip-cert-verify: false}
EOF

cat > /var/www/sub/v2ray <<EOF
vless://$UUID@$DOMAIN:$REALITY_PORT?security=reality&pbk=$PUBLIC&sid=$SHORTID&type=tcp&flow=xtls-rprx-vision&sni=www.microsoft.com#Reality
EOF

cat > /var/www/sub/singbox <<EOF
hysteria2://$HY_PASS@$DOMAIN:$HY_PORT?sni=$DOMAIN#Hysteria2
tuic://$UUID:$TUIC_PASS@$DOMAIN:$TUIC_PORT?sni=$DOMAIN#TUIC
EOF

# =================
# Caddy
# =================

curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt | tee /etc/apt/sources.list.d/caddy-stable.list

apt update
apt install caddy -y

cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
root * /var/www/sub
file_server
}
EOF

systemctl restart caddy

# =================
# 证书自动续期
# =================

(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet") | crontab -

echo ""
echo "=============================="
echo "部署完成"
echo "=============================="

echo ""
echo "Clash订阅:"
echo "https://$DOMAIN/clash"

echo ""
echo "v2rayN订阅:"
echo "https://$DOMAIN/v2ray"

echo ""
echo "sing-box订阅:"
echo "https://$DOMAIN/singbox"
