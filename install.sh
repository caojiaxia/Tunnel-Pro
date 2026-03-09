#!/bin/bash

# Tunnel-Pro v7 Ultimate Color Edition

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
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
echo -e "${RED}Unsupported OS${NC}"
exit
fi

}

install_base(){

echo -e "${BLUE}Installing base packages...${NC}"

if [ "$PM" = "apt" ]; then
apt update -y
apt install -y curl wget nginx jq qrencode openssl net-tools
else
yum install -y epel-release
yum install -y curl wget nginx jq qrencode openssl net-tools
fi

}

enable_bbr(){

echo -e "${BLUE}Enabling BBR...${NC}"

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

sysctl -p

echo -e "${GREEN}BBR Enabled${NC}"

}

install_singbox(){

echo -e "${BLUE}Installing Sing-box...${NC}"

bash -c "$(curl -fsSL https://sing-box.app/install.sh)"

mkdir -p $CONFIG_DIR

}

install_cloudflared(){

echo -e "${BLUE}Installing Cloudflared...${NC}"

wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared

chmod +x /usr/local/bin/cloudflared

}

install_warp(){

echo -e "${BLUE}Installing WARP...${NC}"

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

echo -e "${BLUE}Configuring Nginx...${NC}"

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

echo -e "${GREEN}Nginx configured${NC}"

}

install_ws(){

load_info

if [ -z "$UUID" ]; then
generate_uuid
random_path
read -p "输入域名: " DOMAIN
save_info
fi

echo -e "${BLUE}Deploying WS Node...${NC}"

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

echo -e "${GREEN}WS Node Installed${NC}"

}

install_xhttp(){

load_info

echo -e "${BLUE}Deploying XHTTP Node...${NC}"

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

echo -e "${GREEN}XHTTP Node Installed${NC}"

}

show_nodes(){

load_info

WS_ENCODE=$(echo $WS_PATH | sed 's/\//%2F/g')
XHTTP_ENCODE=$(echo $XHTTP_PATH | sed 's/\//%2F/g')

WS_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=ws&security=tls&host=$DOMAIN&path=$WS_ENCODE&sni=$DOMAIN#WS"
XHTTP_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=xhttp&security=tls&path=$XHTTP_ENCODE&sni=$DOMAIN#XHTTP"

echo
echo -e "${GREEN}WS Node:${NC}"
echo $WS_LINK
qrencode -t ANSIUTF8 "$WS_LINK"

echo
echo -e "${GREEN}XHTTP Node:${NC}"
echo $XHTTP_LINK
qrencode -t ANSIUTF8 "$XHTTP_LINK"

}

menu(){

clear

echo -e "${CYAN}"
echo "=========================================="
echo "        BOGE Tunnel-Pro Ultimate"
echo "=========================================="
echo -e "${NC}"

echo -e "${GREEN}1.${NC} 安装 WS 节点"
echo -e "${GREEN}2.${NC} 安装 XHTTP 节点"

echo -e "${BLUE}-----------------------------${NC}"

echo -e "${GREEN}3.${NC} 启动 Token Tunnel"
echo -e "${GREEN}4.${NC} 启动 Quick Tunnel"

echo -e "${BLUE}-----------------------------${NC}"

echo -e "${GREEN}5.${NC} 安装 WARP"
echo -e "${GREEN}6.${NC} 启用 BBR"

echo -e "${BLUE}-----------------------------${NC}"

echo -e "${GREEN}7.${NC} 查看节点 (二维码)"
echo -e "${GREEN}8.${NC} Cloudflare 优选 IP"
echo -e "${GREEN}9.${NC} 生成订阅"

echo -e "${BLUE}-----------------------------${NC}"

echo -e "${YELLOW}10.${NC} 链路检测"

echo -e "${RED}11.${NC} 卸载"

echo -e "${GREEN}0.${NC} 退出"
echo

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
