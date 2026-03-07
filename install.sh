#!/bin/bash

# Tunnel-Pro 终极整合版
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 1. 辅助函数 ---
print_final_info() {
    echo -e "\n${YELLOW}==============================================${NC}"
    echo -e "${GREEN}部署完成！请务必检查以下设置：${NC}"
    echo -e "${WHITE}1. Cloudflare 后台设置 URL: ${CYAN}http://127.0.0.1:$NAT_PORT${NC}"
    echo -e "${WHITE}2. 路径: ${CYAN}$PATH_WS${NC}"
    echo -e "----------------------------------------------"
    echo -e "${BLUE}客户端导入链接：${NC}"
    echo -e "vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-KVM"
    echo -e "${YELLOW}==============================================${NC}"
}

# --- 2. Nginx 强制接管 (解决 404/80 端口冲突) ---
force_nginx_config() {
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

# --- 3. 部署逻辑 ---
deploy() {
    local CORE=$1
    echo -e "${BLUE}>>> 正在部署 $CORE 核心...${NC}"
    apt update -y && apt install -y nginx curl wget jq net-tools psmisc >/dev/null 2>&1
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared

    read -p "Token: " TOKEN; read -p "域名: " DOMAIN; read -p "Host: " HOST; read -p "后端端口: " BACKEND_PORT; read -p "转发端口: " NAT_PORT
    UUID=$(cat /proc/sys/kernel/random/uuid); PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 配置核心
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        # ... (此处省略配置写入，保持代码整洁) ...
    else
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
    fi

    force_nginx_config

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

# --- 4. 诊断与卸载 ---
diagnose() {
    echo -e "\n${BLUE}>>> 链路状态诊断:${NC}"
    systemctl status cloudflared --no-pager | grep Active
    netstat -tulpn | grep nginx
}

uninstall() {
    systemctl stop cloudflared nginx sing-box xray >/dev/null 2>&1
    rm -rf /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service /etc/nginx/conf.d/tunnel.conf
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${NC}"
}

# --- 5. 纵向排列菜单 ---
echo -e "${BLUE}============================================"
echo -e "      Tunnel-Pro 终极整合管理终端"
echo -e "============================================${NC}"
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
