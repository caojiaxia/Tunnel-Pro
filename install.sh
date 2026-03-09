#!/usr/bin/env bash

############################################################
#  Xray + Cloudflare Tunnel Ultimate Script
#  功能：
#  - 自动安装 Xray
#  - VLESS + XHTTP + TLS
#  - Cloudflare Tunnel
#  - 临时隧道
#  - Cloudflare 优选 IP
#  - WARP IPv4 出口
#  - 节点二维码
#  - 随机路径
#  - BBR优化
#  - 端口检测
#  - 菜单循环
############################################################

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

XRAY_PORT=10000
CONFIG_PATH="/usr/local/etc/xray/config.json"
UUID=$(cat /proc/sys/kernel/random/uuid)

RANDOM_PATH=$(cat /dev/urandom | tr -dc a-z0-9 | head -c 8)

DOMAIN=""
TUNNEL_NAME="xray-tunnel"

############################################################
# 系统检测
############################################################

detect_os() {

if [[ -f /etc/debian_version ]]; then
    OS="debian"
elif [[ -f /etc/redhat-release ]]; then
    OS="centos"
else
    echo -e "${RED}不支持的系统${PLAIN}"
    exit
fi

}

############################################################
# 安装依赖
############################################################

install_base() {

echo -e "${GREEN}安装基础依赖...${PLAIN}"

if [[ $OS == "debian" ]]; then
apt update
apt install -y curl wget unzip qrencode lsof
else
yum install -y curl wget unzip qrencode lsof
fi

}

############################################################
# 端口检测
############################################################

check_port() {

if lsof -i:$XRAY_PORT >/dev/null 2>&1; then
echo -e "${RED}端口 $XRAY_PORT 已被占用${PLAIN}"
exit
fi

}

############################################################
# 安装 Xray
############################################################

install_xray() {

echo -e "${GREEN}安装 Xray...${PLAIN}"

wget -O xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip

unzip -o xray.zip

install -m 755 xray /usr/local/bin/xray

mkdir -p /usr/local/etc/xray

}

############################################################
# 生成配置
############################################################

generate_config() {

echo -e "${GREEN}生成 Xray 配置${PLAIN}"

cat > $CONFIG_PATH <<EOF
{
 "inbounds":[
  {
   "port":$XRAY_PORT,
   "protocol":"vless",
   "settings":{
    "clients":[
     {
      "id":"$UUID"
     }
    ],
    "decryption":"none"
   },
   "streamSettings":{
    "network":"xhttp",
    "security":"none",
    "xhttpSettings":{
     "path":"/$RANDOM_PATH"
    }
   }
  }
 ],
 "outbounds":[
  {
   "protocol":"freedom"
  }
 ]
}
EOF

}

############################################################
# 启动 Xray
############################################################

start_xray() {

pkill xray

nohup xray -config $CONFIG_PATH >/dev/null 2>&1 &

echo -e "${GREEN}Xray 已启动${PLAIN}"

}

############################################################
# 安装 Cloudflare Tunnel
############################################################

install_tunnel() {

echo -e "${GREEN}安装 Cloudflare Tunnel${PLAIN}"

wget -O cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64

chmod +x cloudflared

mv cloudflared /usr/local/bin/

}

############################################################
# 启动临时隧道
############################################################

start_temp_tunnel() {

echo -e "${GREEN}启动临时 Tunnel${PLAIN}"

cloudflared tunnel --url http://localhost:$XRAY_PORT > tunnel.log 2>&1 &

sleep 5

DOMAIN=$(grep trycloudflare tunnel.log | head -n1 | awk '{print $NF}')

echo -e "${GREEN}Tunnel地址: $DOMAIN${PLAIN}"

}

############################################################
# Tunnel 状态检测
############################################################

check_tunnel() {

if pgrep cloudflared >/dev/null; then
echo -e "${GREEN}Tunnel运行中${PLAIN}"
else
echo -e "${RED}Tunnel未运行${PLAIN}"
fi

}

############################################################
# WARP IPv4
############################################################

install_warp() {

echo -e "${GREEN}安装WARP${PLAIN}"

bash <(curl -fsSL https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh)

}

############################################################
# BBR优化
############################################################

enable_bbr() {

echo -e "${GREEN}开启BBR${PLAIN}"

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

sysctl -p

}

############################################################
# 节点URL
############################################################

show_node() {

NODE="vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=xhttp&path=%2F$RANDOM_PATH#$DOMAIN"

echo -e "${GREEN}节点:${PLAIN}"

echo $NODE

echo

qrencode -t ANSIUTF8 "$NODE"

}

############################################################
# Cloudflare 优选IP
############################################################

cf_best_ip() {

echo -e "${GREEN}扫描 Cloudflare 优选IP${PLAIN}"

bash <(curl -s https://raw.githubusercontent.com/XIU2/CloudflareSpeedTest/master/install.sh)

}

############################################################
# 菜单
############################################################

menu() {

clear

echo -e "${GREEN}"
echo "================================="
echo " Xray Tunnel Ultimate Script"
echo "================================="
echo "1. 安装Xray"
echo "2. 生成配置"
echo "3. 启动Xray"
echo "4. 安装Cloudflare Tunnel"
echo "5. 启动临时Tunnel"
echo "6. 查看Tunnel状态"
echo "7. 显示节点"
echo "8. 安装WARP IPv4"
echo "9. Cloudflare优选IP"
echo "10. 开启BBR"
echo "0. 退出"
echo "================================="
echo -e "${PLAIN}"

read -p "请选择: " num

case "$num" in

1)
detect_os
install_base
install_xray
;;

2)
check_port
generate_config
;;

3)
start_xray
;;

4)
install_tunnel
;;

5)
start_temp_tunnel
;;

6)
check_tunnel
;;

7)
show_node
;;

8)
install_warp
;;

9)
cf_best_ip
;;

10)
enable_bbr
;;

0)
exit
;;

esac

}

############################################################
# 循环菜单
############################################################

while true
do
menu
read -p "按回车继续..."
done
