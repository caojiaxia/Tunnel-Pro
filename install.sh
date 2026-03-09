#!/bin/bash

# Tunnel-Pro Sing-box 纯净版 - BBR 加速集成
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

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
    if [ -z "$QUICK_URL" ]; then
        echo -e "${WHITE}1. Cloudflare 后台设置 URL: ${CYAN}http://127.0.0.1:$NAT_PORT${NC}"
    else
        echo -e "${WHITE}1. 临时隧道 URL: ${CYAN}$QUICK_URL${NC}"
    fi
    echo -e "${WHITE}2. 路径: ${CYAN}$PATH_WS${NC}"
    echo -e "----------------------------------------------"
    echo -e "${BLUE}客户端导入链接：${NC}"
    # 如果是临时隧道，域名使用提取到的 URL
    local FINAL_DOMAIN=${DOMAIN:-$QUICK_DOMAIN}
    echo -e "vless://$UUID@$FINAL_DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$FINAL_DOMAIN&host=$FINAL_DOMAIN&fp=chrome#Tunnel-Pro-KVM"
    echo -e "${YELLOW}==============================================${NC}"
}

# --- 2. 部署逻辑 ---

# 提取公用的安装逻辑
prepare_env() {
    echo -e "${BLUE}>>> 正在安装必要组件...${NC}"
    apt update -y && apt install -y nginx curl wget jq net-tools psmisc >/dev/null 2>&1
    enable_bbr
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
}

# 提取公用的 Sing-box 和 Nginx 配置逻辑
config_services() {
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
}

deploy_singbox() {
    prepare_env
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

# --- 新增：临时隧道部署函数 ---
deploy_quick_tunnel() {
    prepare_env
    read -p "后端端口 (建议 3001): " BACKEND_PORT; read -p "转发端口 (建议 8080): " NAT_PORT
    config_services

    echo -e "${BLUE}>>> 正在启动临时隧道 (请稍候)...${NC}"
    # 停止旧的临时隧道
    pkill -f "cloudflared tunnel --url" >/dev/null 2>&1
    
    # 启动临时隧道并将输出重定向到日志
    nohup /usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$NAT_PORT > /tmp/cf_quick.log 2>&1 &
    
    # 等待并提取 URL
    sleep 5
    QUICK_URL=$(grep -o 'https://[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log | head -n 1)
    QUICK_DOMAIN=$(echo $QUICK_URL | sed 's/https:\/\///')

    if [ -z "$QUICK_URL" ]; then
        echo -e "${RED}错误：获取临时隧道 URL 失败，请检查网络或重试。${NC}"
    else
        print_final_info
    fi
}

# --- 3. 诊断与菜单 ---
diagnose() {
    echo -e "\n${BLUE}>>> 链路状态诊断:${NC}"
    if pgrep -f "cloudflared tunnel --url" >/dev/null; then
        echo -e "临时隧道状态: ${GREEN}运行中 (Quick Tunnel)${NC}"
        grep -o 'https://[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log | head -n 1
    else
        systemctl status cloudflared --no-pager | grep Active
    fi
    netstat -tulpn | grep -E 'nginx|sing-box'
    sysctl net.ipv4.tcp_congestion_control
}

uninstall() {
    systemctl stop cloudflared nginx sing-box >/dev/null 2>&1
    pkill -f "cloudflared tunnel --url" >/dev/null 2>&1
    systemctl disable cloudflared nginx sing-box >/dev/null 2>&1
    rm -rf /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service /etc/nginx/conf.d/tunnel.conf /tmp/cf_quick.log
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${NC}"
}

# --- 4. 主菜单 ---
while true; do
    echo -e "\n${BLUE}================ Tunnel-Pro BBR增强版 ================${NC}"
    echo -e "${GREEN}1.${NC} 部署 Sing-box (Token 模式 - 需自有域名)"
    echo -e "${GREEN}2.${NC} 部署 Sing-box (临时隧道 - 无需 Token/域名)"
    echo -e "${CYAN}3.${NC} 链路诊断"
    echo -e "${RED}4.${NC} 彻底卸载"
    echo -e "${WHITE}5.${NC} 退出程序"
    echo -e "------------------------------------------------------"
    read -p "请输入序号: " opt

    case $opt in
        1) deploy_singbox ;;
        2) deploy_quick_tunnel ;;
        3) diagnose ;;
        4) uninstall ;;
        *) exit 0 ;;
    esac
done
