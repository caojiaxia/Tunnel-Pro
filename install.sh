#!/bin/bash

# Tunnel-Pro NAT 专用版
# 维护：原生 Linux / 无需 Docker / 双核心 / NAT 防护

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 1. 环境检测与 BBR
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    if [ -f /usr/bin/apt ]; then CMD_INSTALL="apt install -y"; CMD_UPDATE="apt update"
    elif [ -f /usr/bin/yum ]; then CMD_INSTALL="yum install -y"; CMD_UPDATE="yum makecache"
    else echo "不支持的系统"; exit 1; fi
    
    $CMD_UPDATE >/dev/null 2>&1
    $CMD_INSTALL nginx curl wget jq >/dev/null 2>&1
    
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}BBR 已开启。${NC}"
    fi
}

# 2. 核心部署
deploy() {
    check_env
    local CORE=$1
    read -p "请输入 NAT 映射的公网端口: " NAT_PORT
    read -p "请输入 Cloudflare Tunnel Token: " TOKEN
    read -p "请输入 SNI 域名 (CF 绑定域名): " DOMAIN
    read -p "请输入伪装 Host 域名 (如 www.bing.com): " HOST
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # Nginx 反代配置
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen 127.0.0.1:$NAT_PORT;
    location $PATH_WS {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10086;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $HOST;
    }
}
EOF
    systemctl restart nginx

    # 部署核心
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    else
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1
    fi

    # 部署 Cloudflared 隧道
    wget -qO /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared
    
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
    
    echo -e "\n${GREEN}部署完成!${NC}"
    echo -e "VLESS 链接: ${BLUE}vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-NAT${NC}"
}

# 3. 卸载功能
uninstall() {
    systemctl stop cloudflared nginx xray sing-box 2>/dev/null
    rm -f /etc/nginx/conf.d/tunnel.conf /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared
    echo -e "${RED}已彻底卸载。${NC}"
}

# 菜单
echo -e "${BLUE}=== Tunnel-Pro NAT 终端 ===${NC}"
echo "1. 部署 Xray | 2. 部署 Sing-box | 3. 查看隧道日志 | 4. 一键卸载 | 5. 退出"
read -p "选择: " opt
case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) journalctl -u cloudflared -f ;;
    4) uninstall ;;
    *) exit 0 ;;
esac
