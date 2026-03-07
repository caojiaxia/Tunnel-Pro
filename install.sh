#!/bin/bash

# Tunnel-Pro 极致纵向管理版
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 1. 工具函数 ---
show_header() {
    echo -e "${BLUE}============================================"
    echo -e "      Tunnel-Pro NAT/KVM 管理终端"
    echo -e "============================================${NC}"
}

show_progress() {
    local pid=$1; local msg=$2
    echo -ne "${BLUE}>>> ${msg}... ${NC}"
    while kill -0 $pid 2>/dev/null; do echo -ne "."; sleep 1; done
    echo -e " ${GREEN}完成!${NC}"
}

# --- 2. 部署信息输出函数 (固定信息显示) ---
print_final_info() {
    echo -e "\n${YELLOW}==============================================${NC}"
    echo -e "${GREEN}部署完成！请务必检查以下设置：${NC}"
    echo -e "${WHITE}1. 请前往 Cloudflare Zero Trust 网页后台${NC}"
    echo -e "${WHITE}2. 在 Public Hostname 中设置 URL 为: ${CYAN}http://127.0.0.1:$NAT_PORT${NC}"
    echo -e "----------------------------------------------"
    echo -e "${GREEN}客户端导入链接：${NC}"
    echo -e "${BLUE}vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-KVM${NC}"
    echo -e "${YELLOW}==============================================${NC}"
}

# --- 3. 部署逻辑 ---
deploy() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    apt update -y && apt install -y nginx curl wget jq net-tools psmisc >/dev/null 2>&1
    rm -f /etc/nginx/sites-enabled/default

    local CORE=$1
    read -p "1. 输入 CF Tunnel Token: " TOKEN
    read -p "2. 输入 SNI 域名: " DOMAIN
    read -p "3. 输入伪装 Host: " HOST
    
    if [ "$CORE" == "singbox" ]; then
        read -p "4. 输入 Sing-box 监听端口: " BACKEND_PORT
    else
        BACKEND_PORT=8080
    fi
    read -p "5. 输入 Nginx 转发端口 (即 CF 后台 URL 端口): " NAT_PORT
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 安装核心
    if [ "$CORE" == "singbox" ]; then
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1 &
        show_progress $! "安装 Sing-box"
        cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF
        systemctl restart sing-box
    fi

    # 配置 Nginx
    fuser -k $NAT_PORT/tcp >/dev/null 2>&1
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen $NAT_PORT;
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

    # 强制打印结果
    print_final_info
}

# --- 4. 其他功能 ---
diagnose() {
    echo -e "${BLUE}>>> 链路状态检查:${NC}"
    echo -e "核心进程: $(pgrep -x sing-box >/dev/null && echo '运行中' || echo '未运行')"
    echo -e "Nginx状态: $(systemctl is-active nginx)"
    echo -e "隧道连接: $(systemctl is-active cloudflared)"
}

uninstall() {
    systemctl stop cloudflared nginx sing-box >/dev/null 2>&1
    rm -f /etc/nginx/conf.d/tunnel.conf /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service
    echo -e "${GREEN}已卸载。${NC}"
}

# --- 5. 纵向菜单 ---
show_header
echo -e "${BLUE}1.${NC} 部署 Xray"
echo -e "${BLUE}2.${NC} 部署 Sing-box"
echo -e "${BLUE}3.${NC} 链路诊断"
echo -e "${BLUE}4.${NC} 彻底卸载"
echo -e "${BLUE}5.${NC} 退出程序"
echo -e "--------------------------------------------"
read -p "请选择 (1-5): " opt

case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) diagnose ;;
    4) uninstall ;;
    *) exit 0 ;;
esac
