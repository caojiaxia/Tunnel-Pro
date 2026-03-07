#!/bin/bash

# Tunnel-Pro 极致纵向管理版
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 1. 界面与辅助函数 ---
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

# --- 2. 核心功能函数 ---
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    apt update -y && apt install -y nginx curl wget jq net-tools psmisc >/dev/null 2>&1
    rm -f /etc/nginx/sites-enabled/default
}

deploy() {
    check_env
    local CORE=$1
    echo -e "${YELLOW}>>> 开始部署 $CORE...${NC}"
    read -p "1. 输入 CF Tunnel Token: " TOKEN
    read -p "2. 输入 SNI 域名: " DOMAIN
    read -p "3. 输入伪装 Host: " HOST
    
    if [ "$CORE" == "singbox" ]; then
        read -p "4. 输入 Sing-box 监听端口: " BACKEND_PORT
    else
        BACKEND_PORT=8080
    fi
    read -p "5. 输入 Nginx 转发端口: " NAT_PORT
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 安装核心 (以 Sing-box 为例的安装流)
    if [ "$CORE" == "singbox" ]; then
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1 &
        show_progress $! "安装 Sing-box 核心"
        cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF
        cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target
[Service]
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload && systemctl enable --now sing-box
    fi

    # 配置 Nginx (纵向结构)
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen $NAT_PORT;
    server_name localhost;
    location $PATH_WS {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
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

    echo -e "\n${GREEN}部署流程执行完毕！${NC}"
}

diagnose() {
    echo -e "${BLUE}>>> 链路状态检查:${NC}"
    echo -e "核心进程: $(pgrep -x sing-box >/dev/null && echo '运行中' || echo '未运行')"
    echo -e "Nginx状态: $(systemctl is-active nginx)"
    echo -e "隧道连接: $(systemctl is-active cloudflared)"
}

uninstall() {
    echo -e "${RED}正在卸载并清理残留...${NC}"
    systemctl stop cloudflared nginx sing-box >/dev/null 2>&1
    rm -f /etc/nginx/conf.d/tunnel.conf /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service
    echo -e "${GREEN}卸载已完成。${NC}"
}

# --- 3. 纵向菜单展示 ---
show_header
echo -e "${YELLOW}请选择一个操作:${NC}"
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
