#!/bin/bash

# Tunnel-Pro v7 Ultimate

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

CONFIG_DIR="/etc/sing-box"
INFO_FILE="/etc/tunnel-pro.info"
SUB_DIR="/var/www/html"

WS_PORT=3001
XHTTP_PORT=3002
NGINX_PORT=8080

detect_os(){

if [ -f /etc/debian_version ]; then
PM="apt"
elif [ -f /etc/redhat-release ]; then
PM="yum"
else
echo "Unsupported OS"
exit
fi

}

install_base(){

if [ "$PM" = "apt" ]; then
apt update -y
apt install -y curl wget nginx jq qrencode openssl net-tools
else
yum install -y epel-release
yum install -y curl wget nginx jq qrencode openssl net-tools
fi

}

enable_bbr(){

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

sysctl -p

echo -e "${GREEN}BBR Enabled${NC}"

}

install_singbox(){

bash -c "$(curl -fsSL https://sing-box.app/install.sh)"

mkdir -p $CONFIG_DIR

}

install_cloudflared(){

wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared

chmod +x /usr/local/bin/cloudflared

}

install_warp(){

bash <(curl -fsSL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh) install

}

random_path(){

WS_PATH="/$(openssl rand -hex 4)"
XHTTP_PATH="/$(openssl rand -hex 4)"

}

generate_uuid(){

UUID=$(cat /proc/sys/kernel/random/uuid)

}

save_info(){

cat > $INFO_FILE <<EOF
UUID=$UUID
DOMAIN=$DOMAIN
WS_PATH=$WS_PATH
XHTTP_PATH=$XHTTP_PATH
EOF

}

load_info(){

[ -f $INFO_FILE ] && source $INFO_FILE

}

config_nginx(){

rm -rf /etc/nginx/conf.d/*

cat > /etc/nginx/conf.d/tunnel.conf <<EOF
server {

listen $NGINX_PORT;

location $WS_PATH {

proxy_pass http://127.0.0.1:$WS_PORT;

proxy_http_version 1.1;

proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection "upgrade";
proxy_set_header Host \$host;

}

location $XHTTP_PATH {

proxy_pass http://127.0.0.1:$XHTTP_PORT;

proxy_http_version 1.1;

proxy_set_header Host \$host;

}

location / {

root /var/www/html;

}

}
EOF

systemctl restart nginx
systemctl enable nginx

}

install_ws(){

load_info

if [ -z "$UUID" ]; then
generate_uuid
random_path
read -p "输入域名: " DOMAIN
save_info
fi

cat > $CONFIG_DIR/ws.json <<EOF
{
"log":{"level":"info"},
"inbounds":[
{
"type":"vless",
"listen":"127.0.0.1",
"listen_port":$WS_PORT,
"users":[{"uuid":"$UUID"}],
"transport":{"type":"ws","path":"$WS_PATH"}
}
],
"outbounds":[{"type":"direct"}]
}
EOF

cat > /etc/systemd/system/singbox-ws.service <<EOF
[Unit]
Description=Singbox WS
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_DIR/ws.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable singbox-ws
systemctl restart singbox-ws

config_nginx

}

install_xhttp(){

load_info

cat > $CONFIG_DIR/xhttp.json <<EOF
{
"log":{"level":"info"},
"inbounds":[
{
"type":"vless",
"listen":"127.0.0.1",
"listen_port":$XHTTP_PORT,
"users":[{"uuid":"$UUID"}],
"transport":{"type":"xhttp","path":"$XHTTP_PATH","mode":"auto"}
}
],
"outbounds":[{"type":"direct"}]
}
EOF

cat > /etc/systemd/system/singbox-xhttp.service <<EOF
[Unit]
Description=Singbox XHTTP
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_DIR/xhttp.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable singbox-xhttp
systemctl restart singbox-xhttp

config_nginx

}

start_token_tunnel(){

read -p "Tunnel Token: " TOKEN

cat > /etc/systemd/system/cloudflared-token.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $TOKEN
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared-token
systemctl restart cloudflared-token

}

start_quick_tunnel(){

cat > /etc/systemd/system/cloudflared-quick.service <<EOF
[Unit]
Description=Quick Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$NGINX_PORT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloudflared-quick
systemctl restart cloudflared-quick

echo "查看地址:"
echo "journalctl -u cloudflared-quick -f"

}

generate_subscription(){

load_info

mkdir -p $SUB_DIR

WS_ENCODE=$(echo $WS_PATH | sed 's/\//%2F/g')
XHTTP_ENCODE=$(echo $XHTTP_PATH | sed 's/\//%2F/g')

WS_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=ws&security=tls&host=$DOMAIN&path=$WS_ENCODE&sni=$DOMAIN#WS"
XHTTP_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=xhttp&security=tls&path=$XHTTP_ENCODE&sni=$DOMAIN#XHTTP"

echo "$WS_LINK" > $SUB_DIR/sub.txt
echo "$XHTTP_LINK" >> $SUB_DIR/sub.txt

echo "订阅地址:"
echo "http://$DOMAIN/sub.txt"

}

cf_best_ip(){

IPS=("1.1.1.1" "104.16.1.1" "104.17.1.1")

for ip in "${IPS[@]}"; do
ping -c 3 $ip | grep avg
done

}

show_nodes(){

load_info

WS_ENCODE=$(echo $WS_PATH | sed 's/\//%2F/g')
XHTTP_ENCODE=$(echo $XHTTP_PATH | sed 's/\//%2F/g')

WS_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=ws&security=tls&host=$DOMAIN&path=$WS_ENCODE&sni=$DOMAIN#WS"
XHTTP_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=xhttp&security=tls&path=$XHTTP_ENCODE&sni=$DOMAIN#XHTTP"

echo
echo "WS节点:"
echo $WS_LINK
qrencode -t ANSIUTF8 "$WS_LINK"

echo
echo "XHTTP节点:"
echo $XHTTP_LINK
qrencode -t ANSIUTF8 "$XHTTP_LINK"

}

diagnose(){

systemctl status singbox-ws --no-pager | grep Active
systemctl status singbox-xhttp --no-pager | grep Active
systemctl status nginx --no-pager | grep Active
systemctl status cloudflared-token --no-pager | grep Active
systemctl status cloudflared-quick --no-pager | grep Active

ss -tulpn | grep -E '3001|3002|8080'

}

uninstall_all(){

systemctl stop singbox-ws singbox-xhttp nginx cloudflared-token cloudflared-quick

rm -rf /etc/systemd/system/singbox*
rm -rf /etc/systemd/system/cloudflared*
rm -rf /etc/nginx/conf.d/tunnel.conf
rm -rf $CONFIG_DIR
rm -rf $INFO_FILE

systemctl daemon-reload

echo "卸载完成"

}

menu(){

clear

echo "=============================="
echo "      Tunnel-Pro"
echo "=============================="

echo "1 安装 WS 节点"
echo "2 安装 XHTTP 节点"
echo "3 启动 Token Tunnel"
echo "4 启动 Quick Tunnel"
echo "5 安装 WARP"
echo "6 启用 BBR"
echo "7 查看节点"
echo "8 Cloudflare 优选IP"
echo "9 生成订阅"
echo "10 链路检测"
echo "11 卸载"
echo "0 退出"

read -p "选择: " num

case $num in

1) install_ws ;;
2) install_xhttp ;;
3) start_token_tunnel ;;
4) start_quick_tunnel ;;
5) install_warp ;;
6) enable_bbr ;;
7) show_nodes ;;
8) cf_best_ip ;;
9) generate_subscription ;;
10) diagnose ;;
11) uninstall_all ;;
0) exit ;;

esac

}

detect_os
install_base
install_singbox
install_cloudflared
menu
