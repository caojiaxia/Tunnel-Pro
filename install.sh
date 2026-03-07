#!/bin/bash

# 颜色定义
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 1. 核心工具函数 ---
show_header() {
    echo -e "${BLUE}============================================"
    echo -e "      Tunnel-Pro NAT/KVM 管理终端"
    echo -e "============================================${NC}"
}

# 部署信息打印函数 (确保信息不丢失)
print_final_info() {
    echo -e "\n${YELLOW}==============================================${NC}"
    echo -e "${GREEN}部署流程结束。请务必检查以下配置：${NC}"
    echo -e "1. 前往 Cloudflare Zero Trust 网页后台"
    echo -e "2. Public Hostname 设置 URL 为: ${CYAN}http://127.0.0.1:$NAT_PORT${NC}"
    echo -e "----------------------------------------------"
    echo -e "${GREEN}客户端导入链接：${NC}"
    echo -e "${BLUE}vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-KVM${NC}"
    echo -e "${YELLOW}==============================================${NC}"
}

# --- 2. 部署逻辑 ---
deploy() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    
    # 1. 补全环境
    apt update -y && apt install -y nginx curl wget jq net-tools psmisc >/dev/null 2>&1
    
    # 2. 自动安装/修复 Cloudflared 路径 (解决 203/EXEC 报错)
    if ! command -v cloudflared &> /dev/null; then
        echo -e "${BLUE}>>> 正在安装 Cloudflared...${NC}"
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
        dpkg -i cloudflared-linux-amd64.deb >/dev/null 2>&1
    fi
    CLOUDFLARED_PATH=$(which cloudflared)

    # 3. 收集参数
    read -p "1. CF Tunnel Token: " TOKEN
    read -p "2. SNI 域名: " DOMAIN
    read -p "3. 伪装 Host: " HOST
    read -p "4. 后端监听端口 (singbox): " BACKEND_PORT
    read -p "5. Nginx 转发端口 (需与CF后台一致): " NAT_PORT
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 4. 配置 Sing-box
    cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # 5. 配置 Nginx (强制包含配置)
    mkdir -p /etc/nginx/conf.d/
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen $NAT_PORT;
    server_name localhost;
    location $PATH_WS {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_set_header Host $HOST;
    }
}
EOF
    # 确保 nginx.conf 包含 conf.d 目录 (如果已包含则跳过)
    grep -q "include /etc/nginx/conf.d/*.conf;" /etc/nginx/nginx.conf || echo "include /etc/nginx/conf.d/*.conf;" >> /etc/nginx/nginx.conf

    # 6. 配置并启动服务
    systemctl daemon-reload
    systemctl enable --now sing-box nginx
    
    cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=$CLOUDFLARED_PATH tunnel --no-autoupdate run --token $TOKEN
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now cloudflared

    print_final_info
}

# --- 3. 菜单 ---
show_header
echo -e "${BLUE}1.${NC} 部署 Sing-box"
echo -e "${BLUE}2.${NC} 链路诊断"
echo -e "${BLUE}3.${NC} 卸载"
echo -e "--------------------------------------------"
read -p "请选择: " opt
case $opt in
    1) deploy ;;
    2) diagnose ;;
    3) uninstall ;;
esac
