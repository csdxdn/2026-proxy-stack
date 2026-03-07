#!/usr/bin/env bash
set -e

# ----------------------------
# 交互式输入 VPS 域名
# ----------------------------
read -p "请输入你的 VPS 域名（例如 vm.csdxdn.top）: " DOMAIN

if ! ping -c1 $DOMAIN &>/dev/null; then
    echo "域名解析失败，请确保域名指向当前 VPS IP！"
    exit 1
fi

REALITY_PORT=443
HYSTERIA_PORT=8443
TUIC_PORT=8444

echo "检测系统类型..."
if [[ -f /etc/debian_version ]]; then
    OS="debian"
    apt update -y
    apt install -y curl wget socat openssl uuid-runtime lsb-release software-properties-common
elif [[ -f /etc/centos-release ]]; then
    OS="centos"
    yum install -y epel-release curl wget socat openssl uuid socat
else
    echo "不支持的系统！"
    exit 1
fi

# ----------------------------
# 安装 Xray
# ----------------------------
echo "正在安装 Xray..."
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)

UUID=$(uuidgen)
KEYS=$(xray x25519)
PRIVATE=$(echo "$KEYS" | grep Private | awk '{print $3}')
PUBLIC=$(echo "$KEYS" | grep Public | awk '{print $3}')
SHORTID=$(openssl rand -hex 8)

mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {
      "port":$REALITY_PORT,
      "protocol":"vless",
      "listen":"0.0.0.0",
      "settings":{"clients":[{"id":"$UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},
      "streamSettings":{
        "network":"tcp",
        "security":"reality",
        "realitySettings":{
          "show":false,
          "dest":"www.cloudflare.com:443",
          "xver":0,
          "serverNames":["$DOMAIN"],
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

# ----------------------------
# 安装 Hysteria2
# ----------------------------
echo "正在安装 Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/)
HY_PASS=$(openssl rand -hex 8)

# 尝试 Let’s Encrypt 自动获取证书
echo "尝试使用 Let's Encrypt 获取证书..."
LE_CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
if ! curl -sI https://$DOMAIN &>/dev/null; then
    echo "Let's Encrypt 获取失败，使用自签名证书"
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -days 3650 \
    -subj "/CN=$DOMAIN"
    CERT_FILE="/etc/hysteria/server.crt"
    KEY_FILE="/etc/hysteria/server.key"
else
    CERT_FILE="$LE_CERT_DIR/fullchain.pem"
    KEY_FILE="$LE_CERT_DIR/privkey.pem"
fi

cat > /etc/hysteria/config.yaml <<EOF
listen: :$HYSTERIA_PORT
tls:
  cert: $CERT_FILE
  key: $KEY_FILE
auth:
  type: password
  password: $HY_PASS
masquerade:
  type: proxy
  proxy:
    url: https://www.cloudflare.com
EOF

systemctl restart hysteria-server
systemctl enable hysteria-server

# ----------------------------
# 安装 TUIC
# ----------------------------
mkdir -p /etc/tuic
TUIC_PASS=$(openssl rand -hex 8)
cat > /etc/tuic/config.json <<EOF
{
  "server": "[::]:$TUIC_PORT",
  "users": {"$UUID": "$TUIC_PASS"},
  "certificate": "$CERT_FILE",
  "private_key": "$KEY_FILE",
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

# ----------------------------
# 生成 Clash 订阅
# ----------------------------
SUB_FILE="/var/www/html/sub.yaml"
mkdir -p /var/www/html
cat > $SUB_FILE <<EOF
proxies:
- {name: VLESS-REALITY, server: $DOMAIN, port: $REALITY_PORT, type: vless, uuid: $UUID, network: tcp, tls: true, udp: true, flow: xtls-rprx-vision, servername: $DOMAIN, client-fingerprint: chrome, reality-opts: {public-key: $PUBLIC, short-id: $SHORTID}}
- {name: Hysteria2, type: hysteria2, server: $DOMAIN, port: $HYSTERIA_PORT, password: $HY_PASS, sni: $DOMAIN, skip-cert-verify: true}
- {name: TUIC, type: tuic, server: $DOMAIN, port: $TUIC_PORT, uuid: $UUID, password: $TUIC_PASS, alpn: [h3], skip-cert-verify: true}
EOF

# 提供订阅 HTTP 服务
nohup socat TCP-LISTEN:80,fork FILE:$SUB_FILE &>/dev/null &

echo ""
echo "=========== 部署完成 ==========="
echo "Clash 订阅地址: http://$DOMAIN/sub.yaml"
echo "VLESS-REALITY, Hysteria2, TUIC 已部署并自动开机自启"