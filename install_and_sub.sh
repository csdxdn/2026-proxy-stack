#!/usr/bin/env bash
set -e

echo "=============================="
echo "2026 三协议代理自动部署"
echo "Reality + Hysteria2 + TUIC"
echo "自动订阅版本"
echo "=============================="

# -------------------------------
# 域名输入
# -------------------------------
while true; do
  read -p "请输入你的域名: " DOMAIN
  if [[ $DOMAIN =~ ^([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,}$ ]]; then
    break
  else
    echo "域名格式错误"
  fi
done

REALITY_PORT=8443
HY_PORT=443
TUIC_PORT=8444

# -------------------------------
# 系统依赖
# -------------------------------
apt update -y
apt install -y curl wget uuid-runtime openssl certbot socat ufw jq lsof

# -------------------------------
# BBR 加速
# -------------------------------
grep -q "bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
grep -q "fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
sysctl -p

# -------------------------------
# 防火墙
# -------------------------------
ufw allow 22
ufw allow 80
ufw allow $REALITY_PORT
ufw allow $TUIC_PORT
ufw allow $HY_PORT
ufw --force enable

# -------------------------------
# Xray 安装
# -------------------------------
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
    "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
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

# -------------------------------
# sing-box 安装
# -------------------------------
curl -fsSL https://sing-box.app/install.sh | bash

# 停止可能占用 80 端口的服务
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true

# -------------------------------
# 申请证书
# -------------------------------
certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

if [ ! -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
    echo "证书申请失败，请检查 DNS 是否解析到服务器"
    exit 1
fi

HY_PASS=$(openssl rand -hex 8)
TUIC_PASS=$(openssl rand -hex 8)

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": $HY_PORT,
      "users": [{"password": "$HY_PASS"}],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "certificate_path": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
      },
      "obfs": {"type": "salamander", "password": "$HY_PASS"}
    },
    {
      "type": "tuic",
      "listen": "0.0.0.0",
      "listen_port": $TUIC_PORT,
      "users": [{"uuid": "$UUID", "password": "$TUIC_PASS"}],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "alpn": ["h3"],
        "certificate_path": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
      }
    }
  ],
  "outbounds": [{"type": "direct"}]
}
EOF

systemctl enable sing-box
systemctl restart sing-box

# -------------------------------
# 证书自动续期
# -------------------------------
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet && systemctl restart sing-box") | crontab -

# -------------------------------
# 输出节点订阅
# -------------------------------
echo ""
echo "=============================="
echo "部署完成，以下为节点订阅配置"
echo "=============================="
echo ""
echo "Clash订阅节点:"
echo "- Reality:"
echo "  - server: $DOMAIN"
echo "  - port: $REALITY_PORT"
echo "  - uuid: $UUID"
echo "  - flow: xtls-rprx-vision"
echo "  - tls: true"
echo "  - udp: true"
echo "  - servername: www.microsoft.com"
echo "  - reality opts: public-key=$PUBLIC, short-id=$SHORTID"
echo ""
echo "- Hysteria2:"
echo "  - server: $DOMAIN"
echo "  - port: $HY_PORT"
echo "  - password: $HY_PASS"
echo "  - sni: $DOMAIN"
echo "  - obfs: salamander"
echo ""
echo "- TUIC:"
echo "  - server: $DOMAIN"
echo "  - port: $TUIC_PORT"
echo "  - uuid: $UUID"
echo "  - password: $TUIC_PASS"
echo "  - sni: $DOMAIN"
echo "  - alpn: h3"
echo ""
echo "v2rayN 订阅:"
echo "vless://$UUID@$DOMAIN:$REALITY_PORT?security=reality&pbk=$PUBLIC&sid=$SHORTID&type=tcp&flow=xtls-rprx-vision&sni=www.microsoft.com#Reality"
echo ""
echo "sing-box 订阅:"
echo "hysteria2://$HY_PASS@$DOMAIN:$HY_PORT?sni=$DOMAIN#Hysteria2"
echo "tuic://$UUID:$TUIC_PASS@$DOMAIN:$TUIC_PORT?sni=$DOMAIN#TUIC"
echo ""
echo "=================================="
echo "Clash YAML 节点配置 (可直接复制)"
echo "=================================="
echo "# Reality"
echo "  - {name: Reality, server: $DOMAIN, port: $REALITY_PORT, type: vless, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: www.microsoft.com, client-fingerprint: chrome, skip-cert-verify: true, reality-opts: {public-key: $PUBLIC, short-id: $SHORTID}}"
echo ""
echo "# Hysteria2"
echo "  - {name: Hysteria2, type: hysteria2, server: $DOMAIN, port: $HY_PORT, password: $HY_PASS, sni: $DOMAIN, skip-cert-verify: false, up: 50, down: 500, obfs: salamander, obfs-password: $HY_PASS}"
echo "  - {name: TUIC, server: $DOMAIN, port: $TUIC_PORT, type: tuic, uuid: $UUID, password: $TUIC_PASS, sni: $DOMAIN, alpn: [h3], congestion-controller: bbr, udp: true, skip-cert-verify: false}"
echo ""
echo "=================================="