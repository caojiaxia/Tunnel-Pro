#!/bin/bash

# Tunnel-Pro 纵向管理最终定型版
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 1. 界面与显示 ---
show_header() {
    echo -e "${BLUE}============================================"
    echo -e "      Tunnel-Pro NAT/KVM 管理终端"
    echo -e "============================================${NC}"
}

print_final_info() {
    echo -e "\n${YELLOW}==============================================${NC}"
    echo -e "${GREEN}部署完成！请务必检查以下设置：${NC}"
    echo -e "${WHITE}1. 前往 Cloudflare Zero Trust 网页后台${NC}"
    echo -e "${WHITE}2. Public Hostname 设置 URL: ${CYAN}http://127.0.0.1:$NAT_PORT${NC}"
    echo -e "----------------------------------------------"
    echo -e "${GREEN}客户端导入链接：${NC}"
    echo -e "${BLUE}vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-KVM${NC}"
    echo -e "${YELLOW}==============================================${NC}"
}

# --- 2. 核心部署逻辑 ---
deploy() {
    local CORE=$1
    echo -e "${BLUE}>>> 正在部署 $CORE 核心...${NC}"
    
    # 强制路径修复
    apt update -y && apt install -y nginx curl wget jq net-tools psmisc >/dev/null 2>&1
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared

    read -p "1. CF Tunnel Token: " TOKEN
    read -p "2. SNI 域名: " DOMAIN
    read -p "3. 伪装 Host: " HOST
    read -p "4. 输入自定义后端监听端口: " BACKEND_PORT
    read -p "5. 输入自定义 Nginx 转发端口: " NAT_PORT
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 配置核心
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        cat <<EOF > /usr/local/etc/xray/config.json
{"inbounds":[{"port":$BACKEND_PORT,"protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$PATH_WS"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
        systemctl restart xray
    else
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1
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
        systemctl daemon-reload && systemctl enable --now sing-box && systemctl restart sing-box
    fi

    # 配置 Nginx
    mkdir -p /etc/nginx/conf.d
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
    systemctl restart nginx

    # 启动隧道
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

# --- 3. 诊断与卸载 ---
diagnose() {
    echo -e "\n${BLUE}>>> 链路状态诊断:${NC}"
    systemctl status cloudflared --no-pager | grep Active
    netstat -tulpn | grep nginx
}

uninstall() {
    systemctl stop cloudflared nginx sing-box xray >/dev/null 2>&1
    rm -f /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service /etc/nginx/conf.d/tunnel.conf
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${NC}"
}

# --- 4. 纵向排列菜单 (固定显示) ---
show_header
echo -e "${BLUE}1.${NC} 部署 Xray"
echo -e "${BLUE}2.${NC} 部署 Sing-box"
echo -e "${BLUE}3.${NC} 链路诊断"
echo -e "${BLUE}4.${NC} 彻底卸载"
echo -e "${BLUE}5.${NC} 退出程序"
echo -e "--------------------------------------------"
read -p "请输入序号: " opt

case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) diagnose ;;
    4) uninstall ;;
    *) exit 0 ;;
esac
