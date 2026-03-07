#!/bin/bash

# Tunnel-Pro 极致对齐版
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

show_progress() {
    local pid=$1; local msg=$2
    echo -ne "${BLUE}>>> ${msg}... ${NC}"
    while kill -0 $pid 2>/dev/null; do echo -ne "."; sleep 1; done
    echo -e " ${GREEN}完成!${NC}"
}

check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    apt update -y && apt install -y nginx curl wget jq net-tools >/dev/null 2>&1
    rm -f /etc/nginx/sites-enabled/default
}

deploy() {
    check_env
    local CORE=$1
    echo -e "${YELLOW}--- 配置参数填写 ---${NC}"
    read -p "1. 输入 CF Tunnel Token: " TOKEN
    read -p "2. 输入你在 CF 绑定的域名 (SNI): " DOMAIN
    read -p "3. 输入伪装 Host (如 www.bing.com): " HOST
    
    # 核心端口处理
    if [ "$CORE" == "singbox" ]; then
        read -p "4. 输入 Sing-box 监听端口 (建议 10086): " BACKEND_PORT
    else
        BACKEND_PORT=8080
        echo -e "${BLUE}>>> Xray 默认监听 8080${NC}"
    fi

    # Nginx 端口处理 (这是 CF 网页后台要填的 URL 端口)
    read -p "5. 输入 Nginx 转发端口 (即 CF 后台填写的端口): " NAT_PORT
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # --- 1. 安装核心 ---
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 &
        show_progress $! "部署 Xray"
        mkdir -p /usr/local/etc/xray
        cat <<EOF > /usr/local/etc/xray/config.json
{"inbounds":[{"port":$BACKEND_PORT,"protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$PATH_WS"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
        systemctl restart xray
    else
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1 &
        show_progress $! "部署 Sing-box"
        cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF
        # 写入修复过 DNS 的 service
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
        systemctl daemon-reload && systemctl restart sing-box
    fi

    # --- 2. Nginx 强制对齐 ---
    fuser -k $NAT_PORT/tcp >/dev/null 2>&1 # 杀掉占用该端口的残留进程
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
    systemctl restart nginx || { echo -e "${RED}Nginx 启动失败，请检查端口 $NAT_PORT${NC}"; exit 1; }

    # --- 3. 隧道启动 ---
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

    # --- 4. 关键输出 (对齐指引) ---
    echo -e "\n${YELLOW}==============================================${NC}"
    echo -e "${GREEN}部署完成！请务必检查以下设置：${NC}"
    echo -e "${WHITE}1. 请前往 Cloudflare Zero Trust 网页后台${NC}"
    echo -e "${WHITE}2. 在 Public Hostname 中设置 URL 为: ${CYAN}http://127.0.0.1:$NAT_PORT${NC}"
    echo -e "----------------------------------------------"
    echo -e "${GREEN}客户端导入链接：${NC}"
    echo -e "${BLUE}vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-KVM${NC}"
    echo -e "${YELLOW}==============================================${NC}"
}

diagnose() {
    echo -e "${BLUE}>>> 链路诊断:${NC}"
    pgrep -x xray >/dev/null || pgrep -x sing-box >/dev/null && echo -e "核心: ${GREEN}运行中${NC}" || echo -e "核心: ${RED}未运行${NC}"
    netstat -tlpn | grep -q ":$(netstat -tlpn | grep nginx | awk '{print $4}' | cut -d: -f2)" && echo -e "Nginx: ${GREEN}运行中${NC}" || echo -e "Nginx: ${RED}异常${NC}"
    systemctl is-active --quiet cloudflared && echo -e "隧道: ${GREEN}已连接${NC}" || echo -e "隧道: ${RED}未连接${NC}"
}

# 菜单入口
echo -e "${BLUE}=== Tunnel-Pro NAT/KVM 管理器 ===${NC}"
echo "1. 部署 Xray | 2. 部署 Sing-box | 3. 诊断 | 4. 卸载 | 5. 退出"
read -p "选择: " opt
case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) diagnose ;;
    4) systemctl stop cloudflared nginx xray sing-box && rm -rf /etc/nginx/conf.d/tunnel.conf && echo "已卸载" ;;
    *) exit 0 ;;
esac
