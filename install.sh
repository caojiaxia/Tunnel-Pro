#!/bin/bash

# Tunnel-Pro 全系统增强修复版
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

# --- 1. 辅助函数 ---
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
    echo -e "${BLUE}>>> 检测到系统: $OS | 包管理器: $PM${NC}"
}

enable_bbr() {
    echo -e "${BLUE}>>> 正在启用 BBR 加速...${NC}"
    if ! lsmod | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

print_final_info() {
    echo -e "\n${YELLOW}==============================================${NC}"
    echo -e "${GREEN}部署完成！${NC}"
    if [ -z "$QUICK_URL" ]; then
        echo -e "${WHITE}1. Cloudflare 设置 URL: ${CYAN}http://127.0.0.1:$NAT_PORT${NC}"
    else
        echo -e "${WHITE}1. 临时隧道 URL: ${CYAN}$QUICK_URL${NC}"
    fi
    echo -e "${WHITE}2. 路径: ${CYAN}$PATH_WS${NC}"
    echo -e "----------------------------------------------"
    local FINAL_DOMAIN=${DOMAIN:-$QUICK_DOMAIN}
    echo -e "${BLUE}客户端链接：${NC}"
    echo -e "vless://$UUID@$FINAL_DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$FINAL_DOMAIN&host=$FINAL_DOMAIN&fp=chrome#Tunnel-Pro"
    echo -e "${YELLOW}==============================================${NC}"
}

# --- 2. 部署逻辑 ---

prepare_env() {
    echo -e "${BLUE}>>> 正在同步组件...${NC}"
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

config_services() {
    # 端口清理
    fuser -k $NAT_PORT/tcp >/dev/null 2>&1
    fuser -k $BACKEND_PORT/tcp >/dev/null 2>&1

    UUID=$(cat /proc/sys/kernel/random/uuid); PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1
    
    mkdir -p /etc/sing-box/
    cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF

    SB_PATH=$(command -v sing-box)
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=$SB_PATH run -c /etc/sing-box/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now sing-box

    # --- Nginx 修复逻辑 ---
    systemctl stop nginx >/dev/null 2>&1
    # 清理可能导致冲突的默认配置
    rm -rf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*
    
    # 自动寻找 mime.types 路径
    MIME_PATH="/etc/nginx/mime.types"
    [ ! -f $MIME_PATH ] && MIME_PATH=$(find /etc -name mime.types | head -n 1)

    cat <<EOF > /etc/nginx/nginx.conf
user root;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
    include $MIME_PATH;
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 65;
    include /etc/nginx/conf.d/*.conf;
}
EOF

    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen $NAT_PORT;
    server_name _;
    location $PATH_WS {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
    if ! systemctl restart nginx; then
        echo -e "${RED}Nginx 启动失败，正在尝试强制修复...${NC}"
        pkill -9 nginx
        systemctl restart nginx
    fi
}

deploy_singbox() {
    detect_os && prepare_env
    read -p "Token: " TOKEN; read -p "域名: " DOMAIN; read -p "Host: " HOST; read -p "后端端口: " BACKEND_PORT; read -p "转发端口: " NAT_PORT
    config_services
    cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $TOKEN
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now cloudflared
    print_final_info
}

deploy_quick_tunnel() {
    detect_os && prepare_env
    read -p "后端端口: " BACKEND_PORT; read -p "转发端口: " NAT_PORT
    config_services
    echo -e "${BLUE}>>> 正在请求 Cloudflare 临时隧道...${NC}"
    pkill -f "cloudflared tunnel" >/dev/null 2>&1
    rm -f /tmp/cf_quick.log
    nohup /usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$NAT_PORT > /tmp/cf_quick.log 2>&1 &
    
    # 增加等待时间并循环检查
    for i in {1..10}; do
        sleep 2
        QUICK_URL=$(grep -o 'https://[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log | head -n 1)
        [ -n "$QUICK_URL" ] && break
    done

    if [ -z "$QUICK_URL" ]; then
        echo -e "${RED}失败！日志最后几行：${NC}"
        tail -n 5 /tmp/cf_quick.log
    else
        QUICK_DOMAIN=$(echo $QUICK_URL | sed 's/https:\/\///')
        print_final_info
    fi
}

diagnose() {
    echo -e "\n${BLUE}>>> 诊断:${NC}"
    systemctl is-active nginx >/dev/null 2>&1 && echo -e "Nginx: ${GREEN}正常${NC}" || echo -e "Nginx: ${RED}异常${NC}"
    systemctl is-active sing-box >/dev/null 2>&1 && echo -e "Sing-box: ${GREEN}正常${NC}" || echo -e "Sing-box: ${RED}异常${NC}"
    netstat -tulpn | grep -E 'nginx|sing-box'
}

uninstall() {
    systemctl stop cloudflared nginx sing-box >/dev/null 2>&1
    pkill -f "cloudflared" >/dev/null 2>&1
    rm -rf /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service /etc/nginx/conf.d/tunnel.conf /etc/sing-box/
    echo -e "${GREEN}卸载完成${NC}"
}

while true; do
    echo -e "\n${BLUE}================ Tunnel-Pro 修复增强版 ================${NC}"
    echo -e "1. 部署 (Token 模式)\n2. 部署 (临时隧道)\n3. 链路诊断\n4. 彻底卸载\n5. 退出"
    read -p "选择: " opt
    case $opt in
        1) deploy_singbox ;;
        2) deploy_quick_tunnel ;;
        3) diagnose ;;
        4) uninstall ;;
        *) exit 0 ;;
    esac
done
