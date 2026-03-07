#!/bin/bash

# Tunnel-Pro NAT 专用版 
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 进度反馈函数
show_progress() {
    local pid=$1; local msg=$2
    echo -ne "${BLUE}>>> ${msg}... ${NC}"
    while kill -0 $pid 2>/dev/null; do echo -ne "."; sleep 1; done
    echo -e " ${GREEN}完成!${NC}"
}

# 环境检测
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    echo -e "${BLUE}>>> 正在同步系统与环境依赖...${NC}"
    [ -f /usr/bin/apt ] && apt update -y && apt install -y nginx curl wget jq net-tools || yum install -y nginx curl wget jq net-tools
}

# 部署函数
deploy() {
    check_env
    local CORE=$1
    echo -e "${YELLOW}请按照提示输入 NAT 网络配置参数：${NC}"
    read -p "请输入 Cloudflare Tunnel Token: " TOKEN
    read -p "请输入 SNI 域名: " DOMAIN
    read -p "请输入伪装 Host: " HOST
    
    # 端口指定逻辑
    if [ "$CORE" == "singbox" ]; then
        read -p "请输入 Sing-box 监听端口 (需与 CF 隧道后端设置一致): " BACKEND_PORT
    else
        echo -e "${BLUE}>>> Xray 核心将锁定监听 8080 端口.${NC}"
        BACKEND_PORT=8080
    fi
    read -p "请输入 Nginx 转发监听的 NAT 映射端口: " NAT_PORT
    
    local UUID=$(cat /proc/sys/kernel/random/uuid)
    local PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 1. 核心安装
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 &
        show_progress $! "正在安装 Xray"
        mkdir -p /usr/local/etc/xray
        cat <<EOF > /usr/local/etc/xray/config.json
{"inbounds":[{"port":8080,"protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$PATH_WS"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
        systemctl restart xray
    else
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1 &
        show_progress $! "正在安装 Sing-box"
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
        cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF
        systemctl daemon-reload && systemctl restart sing-box
    fi

    # 2. 配置 Nginx
    echo -ne "${BLUE}>>> 正在同步 Nginx 转发规则 (转发至 $BACKEND_PORT)...${NC}"
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen 127.0.0.1:$NAT_PORT;
    location $PATH_WS {
        proxy_pass http://127.0.0.1:$BACKEND_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $HOST;
    }
}
EOF
    systemctl restart nginx && echo -e " ${GREEN}完成!${NC}"

    # 3. Cloudflare Tunnel
    cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $TOKEN --url http://127.0.0.1:$NAT_PORT
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now cloudflared
    
    echo -e "\n${GREEN}部署成功!${NC}"
    echo -e "VLESS 链接: ${BLUE}vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-NAT${NC}"
}

# 诊断功能
diagnose() {
    echo -e "${BLUE}>>> 链路诊断:${NC}"
    pgrep -x xray >/dev/null || pgrep -x sing-box >/dev/null && echo "核心状态: 正常" || echo "核心状态: 异常"
    systemctl is-active --quiet cloudflared && echo "隧道状态: 正常" || echo "隧道状态: 异常"
}

# 卸载功能
uninstall() {
    systemctl stop cloudflared nginx xray sing-box 2>/dev/null
    rm -f /etc/nginx/conf.d/tunnel.conf /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared
    echo -e "${RED}已彻底卸载。${NC}"
}

# 主菜单
echo -e "${BLUE}=== Tunnel-Pro NAT 终端 ===${NC}"
echo "1. 部署 Xray (固定8080) | 2. 部署 Sing-box (自定义端口)"
echo "3. 查看隧道日志 | 4. 卸载 | 5. 退出 | 6. 链路诊断"
read -p "选择: " opt

case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) journalctl -u cloudflared -f ;;
    4) uninstall ;;
    5) exit 0 ;;
    6) diagnose ;;
    *) echo "无效选择"; exit 1 ;;
esac
