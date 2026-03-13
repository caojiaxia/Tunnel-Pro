#!/bin/bash

# Tunnel-Pro
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

UUID=""
PATH_WS=""

# --- 1. 核心辅助函数 ---
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS="CentOS"; PM="yum"
    elif grep -qi "debian" /etc/issue || grep -qi "debian" /etc/os-release; then
        OS="Debian"; PM="apt"
    elif grep -qi "ubuntu" /etc/issue || grep -qi "ubuntu" /etc/os-release; then
        OS="Ubuntu"; PM="apt"
    elif grep -qi "arch" /etc/os-release; then
        OS="Arch"; PM="pacman"
    else
        OS="Unknown"; PM="apt"
    fi
}

enable_bbr() {
    if ! lsmod | grep -q bbr; then
        echo -e "${BLUE}>>> 正在开启 BBR 加速...${NC}"
        grep -q "default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        grep -q "tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

# --- 2. 部署与配置逻辑 ---
prepare_env() {
    echo -e "${BLUE}>>> 安装必要组件...${NC}"

    if [[ "$PM" == "apt" ]]; then
        apt update -y && apt install -y nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    elif [[ "$PM" == "yum" ]]; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    elif [[ "$PM" == "pacman" ]]; then
        pacman -Sy --noconfirm nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    fi

    enable_bbr

    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
}

install_singbox() {

    if command -v sing-box >/dev/null 2>&1; then
        return
    fi

    echo -e "${BLUE}>>> 安装 sing-box...${NC}"

    wget -O /tmp/sb.tar.gz https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-amd64.tar.gz >/dev/null 2>&1
    tar -xzf /tmp/sb.tar.gz -C /tmp >/dev/null 2>&1

    SB_BIN=$(find /tmp -name sing-box | head -n 1)

    mv $SB_BIN /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
}

config_services() {

    fuser -k $NAT_PORT/tcp >/dev/null 2>&1
    fuser -k $BACKEND_PORT/tcp >/dev/null 2>&1

    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)"

    install_singbox

    mkdir -p /etc/sing-box/

cat <<EOF > /etc/sing-box/config.json
{
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": $BACKEND_PORT,
    "users": [{
      "uuid": "$UUID"
    }],
    "transport": {
      "type": "ws",
      "path": "$PATH_WS"
    }
  }],
  "outbounds": [{
    "type": "direct"
  }]
}
EOF

cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now sing-box

    systemctl stop nginx >/dev/null 2>&1

    rm -rf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*

    MIME_PATH=$(find /etc/nginx -name mime.types | head -n 1)
    MIME_PATH=${MIME_PATH:-/etc/nginx/mime.types}

cat <<EOF > /etc/nginx/nginx.conf
user root;
worker_processes auto;

events {
    worker_connections 1024;
}

http {

    include $MIME_PATH;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    server {

        listen $NAT_PORT;

        location $PATH_WS {

            proxy_redirect off;
            proxy_pass http://127.0.0.1:$BACKEND_PORT;

            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
        }

        location / {
            return 200 "OK";
        }

    }

}
EOF

    systemctl enable nginx
    systemctl restart nginx
}

# --- 3. 查看节点 ---
view_config() {

    if [ ! -f /etc/sing-box/config.json ]; then
        echo -e "${RED}错误：未发现配置文件，请先部署节点。${NC}"
        sleep 2
        return
    fi

    CONF_UUID=$(jq -r '.inbounds[0].users[0].uuid' /etc/sing-box/config.json)
    CONF_PATH=$(jq -r '.inbounds[0].transport.path' /etc/sing-box/config.json)

    CONF_DOMAIN=""

    if [ -f /etc/sing-box/.domain ]; then
        CONF_DOMAIN=$(cat /etc/sing-box/.domain)

    elif [ -f /tmp/cf_quick.log ]; then
        CONF_DOMAIN=$(grep -oP '(?<=https://)[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log | head -n 1)
    fi

    DISPLAY_DOMAIN=${CONF_DOMAIN:-"YOUR_DOMAIN"}

    echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC}  ${GREEN}当前节点配置信息：${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"

    echo -e "${YELLOW}│${NC}  域名: ${CYAN}$DISPLAY_DOMAIN${NC}"
    echo -e "${YELLOW}│${NC}  路径: ${CYAN}$CONF_PATH${NC}"
    echo -e "${YELLOW}│${NC}  UUID: ${CYAN}$CONF_UUID${NC}"

    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  ${BLUE}一键导入链接：${NC}"

    echo -e "${YELLOW}│${NC}  ${WHITE}vless://$CONF_UUID@$DISPLAY_DOMAIN:443?path=$(echo $CONF_PATH | sed 's/\//%2F/g')&security=tls&encryption=none&type=ws&sni=$DISPLAY_DOMAIN&host=$DISPLAY_DOMAIN&fp=chrome#Tunnel-Pro${NC}"

    [ -z "$CONF_DOMAIN" ] && echo -e "${YELLOW}│${NC}  ${RED}注意：请手动替换 YOUR_DOMAIN${NC}"

    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"

    read -p "按回车键返回主菜单..."
}

# --- 诊断 ---
diagnose() {

    clear
    echo -e "${BLUE}=== 链路诊断系统 ===${NC}"

    systemctl is-active nginx >/dev/null 2>&1 && echo -e "Nginx:    ${GREEN}● 运行中${NC}" || echo -e "Nginx:    ${RED}○ 异常${NC}"
    systemctl is-active sing-box >/dev/null 2>&1 && echo -e "Sing-box: ${GREEN}● 运行中${NC}" || echo -e "Sing-box: ${RED}○ 异常${NC}"

    echo -e "TCP 端口占用状况："

    ss -tulpn | grep -E 'nginx|sing-box|cloudflared'

    read -p "按回车键返回主菜单..."
}

# --- 主菜单 ---
while true
do
clear

echo -e "${CYAN}┌─────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│${NC}           ${WHITE}BoGe-Tunnel-Pro 控制面板${NC}           ${CYAN}│${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────┤${NC}"

echo -e "${CYAN}│${NC}  ${GREEN}1.${NC} 部署 Token 模式${NC}"
echo -e "${CYAN}│${NC}  ${GREEN}2.${NC} 部署 临时隧道模式${NC}"
echo -e "${CYAN}│${NC}  ${BLUE}3.${NC} 查看当前节点信息${NC}"
echo -e "${CYAN}│${NC}  ${YELLOW}4.${NC} 链路诊断${NC}"
echo -e "${CYAN}│${NC}  ${WHITE}5.${NC} 退出脚本${NC}"

echo -e "${CYAN}└─────────────────────────────────────────────────────┘${NC}"

read -p "请选择序号: " opt

case $opt in
1) deploy_token ;;
2) deploy_quick ;;
3) view_config ;;
4) diagnose ;;
5) exit ;;
*)
echo "输入错误"
sleep 1
;;
esac

done
