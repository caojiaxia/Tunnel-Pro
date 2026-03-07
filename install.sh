#!/bin/bash

# Tunnel-Pro NAT 专用版 (端口定制版)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 进度反馈函数
show_progress() {
    local pid=$1; local msg=$2
    echo -ne "${BLUE}>>> ${msg}... ${NC}"
    while kill -0 $pid 2>/dev/null; do echo -ne "."; sleep 1; done
    echo -e " ${GREEN}完成!${NC}"
}

check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    echo -e "${BLUE}>>> 正在同步系统与环境依赖...${NC}"
    [ -f /usr/bin/apt ] && apt update -y && apt install -y nginx curl wget jq net-tools || yum install -y nginx curl wget jq net-tools
}

deploy() {
    check_env
    local CORE=$1
    read -p "请输入 Cloudflare Tunnel Token: " TOKEN
    read -p "请输入 SNI 域名: " DOMAIN
    read -p "请输入伪装 Host: " HOST
    
    # 核心监听端口设定
    if [ "$CORE" == "xray" ]; then
        local BACKEND_PORT=8080
    else
        local BACKEND_PORT=$(shuf -i 20000-60000 -n 1)
    fi
    
    local NAT_PORT=$(shuf -i 20000-60000 -n 1)
    local UUID=$(cat /proc/sys/kernel/random/uuid)
    local PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    echo -e "${BLUE}>>> 正在执行部署流程...${NC}"

    # 1. 核心安装与配置
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 &
        show_progress $! "正在安装 Xray"
        mkdir -p /usr/local/etc/xray
        cat <<EOF > /usr/local/etc/xray/config.json
{"inbounds":[{"port":$BACKEND_PORT,"protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$PATH_WS"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
        systemctl restart xray
    else
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1 &
        show_progress $! "正在安装 Sing-box"
        cat <<EOF > /etc/sing-box/config.json
{"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$BACKEND_PORT,"users":[{"uuid":"$UUID"}],"transport":{"type":"ws","path":"$PATH_WS"}}],"outbounds":[{"type":"direct"}]}
EOF
        systemctl restart sing-box
    fi

    # 2. Nginx 配置
    echo -ne "${BLUE}>>> 正在同步 Nginx 转发规则 (后端端口: $BACKEND_PORT)...${NC}"
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen 127.0.0.1:$NAT_PORT;
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
    systemctl restart nginx && echo -e " ${GREEN}完成!${NC}"

    # 3. Cloudflare Tunnel
    echo -ne "${BLUE}>>> 正在启动 Cloudflare 隧道服务...${NC}"
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
    systemctl daemon-reload && systemctl enable --now cloudflared && echo -e " ${GREEN}完成!${NC}"
    
    echo -e "\n${GREEN}部署已成功!${NC}"
    echo -e "监听端口: Xray(8080) / Sing-box(随机: $BACKEND_PORT)"
    echo -e "VLESS 链接: ${BLUE}vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-NAT${NC}"
}

diagnose() {
    echo -e "${BLUE}>>> 正在进行链路诊断...${NC}"
    echo -e "核心状态: $(pgrep -x xray || pgrep -x sing-box >/dev/null && echo '正常' || echo '异常')"
    echo -e "Nginx 监听: $(netstat -tlpn | grep -q nginx && echo '正常' || echo '异常')"
    echo -e "隧道状态: $(systemctl is-active --quiet cloudflared && echo '正常' || echo '异常')"
}

# 菜单入口
echo -e "${BLUE}=== Tunnel-Pro NAT 控制台 ===${NC}"
echo "1. 部署 Xray (端口: 8080)"
echo "2. 部署 Sing-box (随机端口)"
echo "3. 查看隧道日志 | 4. 卸载 | 6. 链路诊断 | 5. 退出"
read -p "选择: " opt
case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) journalctl -u cloudflared -f ;;
    4) uninstall ;;
    6) diagnose ;;
    *) exit 0 ;;
esac
