#!/bin/bash

# Tunnel-Pro  Xray & Sing-box 双核心管理
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 部署逻辑独立化 ---
deploy_core() {
    local CORE=$1
    echo -e "${BLUE}>>> 正在部署/更新 $CORE 核心...${NC}"
    read -p "Token: " TOKEN; read -p "域名: " DOMAIN; read -p "Host: " HOST; read -p "后端端口: " BACKEND_PORT; read -p "转发端口: " NAT_PORT
    UUID=$(cat /proc/sys/kernel/random/uuid); PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        mkdir -p /usr/local/etc/xray
        cat <<EOF > /usr/local/etc/xray/config.json
{"inbounds":[{"port":$BACKEND_PORT,"protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$PATH_WS"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
        systemctl restart xray
    else
        # 保护性部署：如果已存在则跳过安装，仅更新配置
        if [ ! -f "/usr/bin/sing-box" ]; then
            bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1
        fi
        cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF
        systemctl restart sing-box
    fi

    # 统一重置 Nginx 和 Tunnel
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server { listen $NAT_PORT; location $PATH_WS { proxy_pass http://127.0.0.1:$BACKEND_PORT; proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host \$host; } }
EOF
    systemctl restart nginx
    
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
    systemctl daemon-reload && systemctl restart cloudflared
    echo -e "${GREEN}>>> $CORE 部署完成，Nginx 转发已更新。${NC}"
}

# --- 菜单系统 ---
echo -e "${BLUE}================ Tunnel-Pro ================${NC}"
echo -e "1. 部署/修复 Xray (重置 Xray 配置)"
echo -e "2. 部署/修复 Sing-box (重置 Sing-box 配置)"
echo -e "3. 链路诊断"
echo -e "4. 彻底卸载"
echo -e "5. 退出"
echo -e "---------------------------------------------------"
read -p "请输入序号: " opt

case $opt in
    1) deploy_core "xray" ;;
    2) deploy_core "singbox" ;;
    3) diagnose ;; # 此处调用你之前的诊断函数
    4) uninstall ;; # 此处调用你之前的卸载函数
    *) exit 0 ;;
esac
