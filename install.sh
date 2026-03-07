#!/bin/bash

# Tunnel-Pro NAT 专用版 (全功能整合诊断版)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 进度反馈函数
show_progress() {
    local pid=$1
    local msg=$2
    echo -ne "${BLUE}>>> ${msg}... ${NC}"
    while kill -0 $pid 2>/dev/null; do
        echo -ne "."
        sleep 1
    done
    echo -e " ${GREEN}完成!${NC}"
}

# 1. 环境检测
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    [ -f /usr/bin/apt ] && CMD="apt" || CMD="yum"
    $CMD update -y >/dev/null 2>&1
    $CMD install -y nginx curl wget jq net-tools >/dev/null 2>&1
    
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

# 2. 部署逻辑
deploy() {
    check_env
    local CORE=$1
    read -p "请输入 NAT 映射端口: " NAT_PORT
    read -p "请输入 Tunnel Token: " TOKEN
    read -p "请输入 SNI 域名: " DOMAIN
    read -p "请输入伪装 Host: " HOST
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 安装核心
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 &
    else
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1 &
    fi
    show_progress $! "正在下载并安装 $CORE 核心"

    # 配置 Nginx
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

    # 配置 Cloudflare Tunnel
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
    
    echo -e "\n${GREEN}部署完成! 建议运行选项 6 进行连通性诊断。${NC}"
}

# 3. 诊断功能
diagnose() {
    echo -e "${BLUE}>>> 正在诊断链路...${NC}"
    echo -n "检测核心进程: "
    if pgrep -x "xray" >/dev/null || pgrep -x "sing-box" >/dev/null; then echo "正常"; else echo "异常 (未运行)"; fi
    echo -n "检测 Nginx 监听: "
    if netstat -tlpn | grep -q "127.0.0.1"; then echo "正常"; else echo "异常"; fi
    echo -n "检测 CF 隧道: "
    if systemctl is-active --quiet cloudflared; then echo "正在运行"; else echo "未启动"; fi
    echo -e "${YELLOW}查看错误日志请运行: tail -n 20 /var/log/nginx/error.log${NC}"
}

# 4. 卸载
uninstall() {
    systemctl stop cloudflared nginx xray sing-box 2>/dev/null
    rm -f /etc/nginx/conf.d/tunnel.conf /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared
    echo -e "${RED}已卸载。${NC}"
}

# 菜单
echo -e "${BLUE}=== Tunnel-Pro NAT 终端 ===${NC}"
echo "1. 部署 Xray | 2. 部署 Sing-box | 3. 查看隧道日志 | 4. 卸载 | 5. 退出 | 6. 链路诊断"
read -p "选择: " opt
case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) journalctl -u cloudflared -f ;;
    4) uninstall ;;
    6) diagnose ;;
    *) exit 0 ;;
esac
