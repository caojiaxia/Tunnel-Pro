#!/bin/bash

# Tunnel-Pro Sing-box 纯净版 - BBR 加速集成
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 1. 辅助函数 ---
enable_bbr() {
    echo -e "${BLUE}>>> 正在启用 BBR 加速...${NC}"
    if ! lsmod | grep -q bbr; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
    echo -e "${GREEN}>>> BBR 已启用。${NC}"
}

print_final_info() {
    echo -e "\n${YELLOW}==============================================${NC}"
    echo -e "${GREEN}部署完成！BBR 加速已启用。${NC}"
    echo -e "${WHITE}1. Cloudflare 后台设置 URL: ${CYAN}http://127.0.0.1:$NAT_PORT${NC}"
    echo -e "${WHITE}2. 路径: ${CYAN}$PATH_WS${NC}"
    echo -e "----------------------------------------------"
    echo -e "${BLUE}客户端导入链接：${NC}"
    echo -e "vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-KVM"
    echo -e "${YELLOW}==============================================${NC}"
}

# --- 2. 部署逻辑 (包含 BBR 和 Sing-box) ---
deploy_singbox() {
    echo -e "${BLUE}>>> 正在部署 Sing-box 核心...${NC}"
    apt update -y && apt install -y nginx curl wget jq net-tools psmisc >/dev/null 2>&1
    
    # 开启 BBR
    enable_bbr
    
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared

    read -p "Token: " TOKEN; read -p "域名: " DOMAIN; read -p "Host: " HOST; read -p "后端端口: " BACKEND_PORT; read -p "转发端口: " NAT_PORT
    UUID=$(cat /proc/sys/kernel/random/uuid); PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1
    cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now sing-box

    # Nginx 强制接管逻辑
    systemctl stop nginx >/dev/null 2>&1
    rm -rf /etc/nginx/conf.d/* /etc/nginx/nginx.conf
    cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
events { worker_connections 1024; }
http { include /etc/nginx/conf.d/*.conf; }
EOF
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen $NAT_PORT;
    location $PATH_WS {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
    systemctl start nginx

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

# --- 3. 诊断与菜单 ---
diagnose() {
    echo -e "\n${BLUE}>>> 链路状态诊断:${NC}"
    systemctl status cloudflared --no-pager | grep Active
    netstat -tulpn | grep -E 'nginx|sing-box'
    # 检查 BBR 状态
    sysctl net.ipv4.tcp_congestion_control
}

uninstall() {
    systemctl stop cloudflared nginx sing-box >/dev/null 2>&1
    rm -rf /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service /etc/nginx/conf.d/tunnel.conf
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${NC}"
}

echo -e "${BLUE}================ Tunnel-Pro BBR增强版 ================${NC}"
echo -e "1. 部署 Sing-box (自动开启 BBR)"
echo -e "2. 链路诊断"
echo -e "3. 彻底卸载"
echo -e "4. 退出程序"
echo -e "--------------------------------------------"
read -p "请输入序号: " opt

case $opt in
    1) deploy_singbox ;;
    2) diagnose ;;
    3) uninstall ;;
    *) exit 0 ;;
esac
