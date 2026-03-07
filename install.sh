#!/bin/bash

# Tunnel-Pro 最终整合版
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- 1. 打印部署信息 ---
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

# --- 2. 诊断逻辑 ---
diagnose() {
    echo -e "\n${BLUE}>>> 链路状态诊断:${NC}"
    echo -e "Sing-box/Xray: $(pgrep -x sing-box >/dev/null || pgrep -x xray >/dev/null && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}")"
    echo -e "Nginx: $(systemctl is-active nginx >/dev/null && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}")"
    echo -e "Cloudflared: $(systemctl is-active cloudflared >/dev/null && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行(检查路径或Token)${NC}")"
    echo -e "若隧道失败，请运行: ${YELLOW}journalctl -u cloudflared -n 20 --no-pager${NC}"
}

# --- 3. 卸载逻辑 ---
uninstall() {
    echo -e "${RED}>>> 正在彻底卸载组件...${NC}"
    systemctl stop cloudflared nginx sing-box xray >/dev/null 2>&1
    systemctl disable cloudflared nginx sing-box xray >/dev/null 2>&1
    rm -f /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service
    rm -f /etc/nginx/conf.d/tunnel.conf
    systemctl daemon-reload
    echo -e "${GREEN}卸载完成。${NC}"
}

# --- 4. 部署逻辑 ---
deploy() {
    local CORE=$1
    echo -e "${BLUE}>>> 正在部署 $CORE 核心...${NC}"
    read -p "1. 输入 CF Tunnel Token: " TOKEN
    read -p "2. 输入 SNI 域名: " DOMAIN
    read -p "3. 输入伪装 Host: " HOST
    read -p "4. 输入后端监听端口: " BACKEND_PORT
    read -p "5. 输入 Nginx 转发端口: " NAT_PORT
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 安装/配置核心
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
        systemctl daemon-reload
        systemctl enable --now sing-box && systemctl restart sing-box
    fi

    # 配置 Nginx (确保包含配置目录)
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

    # 自动获取 cloudflared 路径 (防止 203/EXEC 报错)
    CLOUDFLARED_PATH=$(which cloudflared)
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

# --- 5. 主程序菜单 ---
show_header() {
    echo -e "${BLUE}============================================"
    echo -e "      Tunnel-Pro 永久管理终端"
    echo -e "============================================${NC}"
}

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
