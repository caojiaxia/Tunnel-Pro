#!/bin/bash

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

UUID=""
PATH_WS=""

detect_os(){
if [[ -f /etc/redhat-release ]]; then PM="yum"
elif grep -qi ubuntu /etc/os-release; then PM="apt"
elif grep -qi debian /etc/os-release; then PM="apt"
elif grep -qi arch /etc/os-release; then PM="pacman"
else PM="apt"; fi
}

enable_bbr(){
lsmod | grep -q bbr && return
grep -q default_qdisc /etc/sysctl.conf || echo net.core.default_qdisc=fq >> /etc/sysctl.conf
grep -q tcp_congestion_control /etc/sysctl.conf || echo net.ipv4.tcp_congestion_control=bbr >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1
}

prepare_env(){
echo -e "${BLUE}>>> 安装组件...${NC}"
case $PM in
apt) apt update -y && apt install -y nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1 ;;
yum) yum install -y epel-release >/dev/null 2>&1; yum install -y nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1 ;;
pacman) pacman -Sy --noconfirm nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1 ;;
esac

enable_bbr

command -v cloudflared >/dev/null || {
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
}

install_singbox
}

install_singbox(){
command -v sing-box >/dev/null && return
wget -qO /tmp/sb.tar.gz https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz
tar -xzf /tmp/sb.tar.gz -C /tmp
mv $(find /tmp -name sing-box | head -n1) /usr/local/bin/
chmod +x /usr/local/bin/sing-box
}

config_services(){

fuser -k $NAT_PORT/tcp >/dev/null 2>&1
fuser -k $BACKEND_PORT/tcp >/dev/null 2>&1

UUID=$(cat /proc/sys/kernel/random/uuid)
PATH_WS="/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)"

mkdir -p /etc/sing-box

cat >/etc/sing-box/config.json <<EOF
{
"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,
"users":[{"uuid":"$UUID"}],
"transport":{"type":"ws","path":"$PATH_WS"}}],
"outbounds":[{"type":"direct"}]
}
EOF

cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box

MIME=$(find /etc/nginx -name mime.types | head -n1)
MIME=${MIME:-/etc/nginx/mime.types}

cat >/etc/nginx/nginx.conf <<EOF
user root;
worker_processes auto;
events { worker_connections 1024; }

http{
include $MIME;
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

server{
listen $NAT_PORT;

location $PATH_WS{
proxy_pass http://127.0.0.1:$BACKEND_PORT;
proxy_http_version 1.1;
proxy_set_header Upgrade \$http_upgrade;
proxy_set_header Connection \$connection_upgrade;
proxy_set_header Host \$host;
}

location / { return 200 "OK"; }
}
}
EOF

systemctl enable nginx
systemctl restart nginx
}

print_done(){

DOMAIN_SHOW=${DOMAIN:-$QUICK_DOMAIN}

echo
echo -e "${GREEN}部署成功${NC}"
echo "地址: https://$DOMAIN_SHOW"
echo "路径: $PATH_WS"
echo "UUID: $UUID"
echo
echo "vless://$UUID@$DOMAIN_SHOW:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&encryption=none&type=ws&sni=$DOMAIN_SHOW&host=$DOMAIN_SHOW#Tunnel-Pro"
read -p "回车返回菜单"
}

deploy_token(){

detect_os
prepare_env

read -p "Cloudflare Token: " TOKEN
read -p "域名: " DOMAIN

echo "$DOMAIN" > /etc/sing-box/.domain

read -p "后端端口(3001): " BACKEND_PORT
BACKEND_PORT=${BACKEND_PORT:-3001}

read -p "转发端口(8080): " NAT_PORT
NAT_PORT=${NAT_PORT:-8080}

config_services

cat >/etc/systemd/system/cloudflared.service <<EOF
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
systemctl enable --now cloudflared

print_done
}

deploy_quick(){

detect_os
prepare_env

rm -f /etc/sing-box/.domain

read -p "后端端口(3001): " BACKEND_PORT
BACKEND_PORT=${BACKEND_PORT:-3001}

read -p "转发端口(8080): " NAT_PORT
NAT_PORT=${NAT_PORT:-8080}

config_services

pkill cloudflared >/dev/null 2>&1
rm -f /tmp/cf_quick.log

nohup cloudflared tunnel --url http://127.0.0.1:$NAT_PORT > /tmp/cf_quick.log 2>&1 &

for i in {1..20}; do
sleep 2
QUICK_DOMAIN=$(grep -o 'https://[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log | head -n1 | sed 's/https:\/\///')
[ -n "$QUICK_DOMAIN" ] && break
done

[ -z "$QUICK_DOMAIN" ] && { echo "获取域名失败"; return; }

print_done
}

view_config(){

[ ! -f /etc/sing-box/config.json ] && { echo "未部署"; sleep 2; return; }

UUID=$(jq -r '.inbounds[0].users[0].uuid' /etc/sing-box/config.json)
PATH_WS=$(jq -r '.inbounds[0].transport.path' /etc/sing-box/config.json)

DOMAIN=$(cat /etc/sing-box/.domain 2>/dev/null)

[ -z "$DOMAIN" ] && DOMAIN=$(grep -o 'https://[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log | head -n1 | sed 's/https:\/\///')

echo
echo "域名: $DOMAIN"
echo "路径: $PATH_WS"
echo "UUID: $UUID"
echo
read -p "回车返回"
}

diagnose(){

echo "Nginx:" $(systemctl is-active nginx)
echo "Sing-box:" $(systemctl is-active sing-box)
echo "Cloudflared:" $(systemctl is-active cloudflared)

echo
ss -tulpn | grep -E 'nginx|sing-box|cloudflared'

read -p "回车返回"
}

uninstall(){

systemctl stop cloudflared nginx sing-box >/dev/null 2>&1
systemctl disable cloudflared nginx sing-box >/dev/null 2>&1

pkill cloudflared nginx sing-box >/dev/null 2>&1

rm -rf /etc/systemd/system/cloudflared.service
rm -rf /etc/systemd/system/sing-box.service
rm -rf /etc/sing-box
rm -f /tmp/cf_quick.log

echo "卸载完成"
sleep 2
}

while true
do
clear

echo "======== Tunnel-Pro ========"
echo "1. Token模式部署"
echo "2. 临时隧道部署"
echo "3. 查看节点"
echo "4. 链路诊断"
echo "5. 卸载"
echo "6. 退出"
echo "============================"

read -p "选择: " opt

case $opt in
1) deploy_token ;;
2) deploy_quick ;;
3) view_config ;;
4) diagnose ;;
5) uninstall ;;
6) exit ;;
*) echo "输入错误"; sleep 1 ;;
esac

done
