#!/bin/bash

# Tunnel-Pro 独立项目版
# 功能：Xray/Sing-box 双核、Nginx 随机端口反代、自动 BBR、全流程卸载
# 维护：直接在 GitHub 网页编辑此文件即可更新

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 1. 环境自检
check_sys() {
    [ -f /usr/bin/apt ] && CMD="apt" || CMD="yum"
    $CMD update -y >/dev/null 2>&1
    $CMD install -y nginx curl wget jq >/dev/null 2>&1
}

# 2. BBR 加速与反馈
enable_bbr() {
    echo -e "${BLUE}>>> 正在检测 BBR 加速...${NC}"
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}BBR 已成功启用！${NC}"
    else
        echo -e "${GREEN}BBR 已处于运行状态。${NC}"
    fi
}

# 3. 核心部署逻辑
deploy() {
    check_sys
    enable_bbr
    local CORE=$1
    local PORT=$(shuf -i 20000-60000 -n 1)
    read -p "请输入 Tunnel Token: " TOKEN
    read -p "请输入域名 (Domain): " DOMAIN
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # Nginx 反代配置 (防探测)
    cat <<EOF > /etc/nginx/conf.d/tunnel.conf
server {
    listen 127.0.0.1:$PORT;
    location $PATH_WS {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_pass http://127.0.0.1:10086;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF
    systemctl restart nginx

    # 部署核心
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        # [此处可根据你的需求替换 Xray 配置]
    else
        bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1
    fi

    # 部署 Cloudflared (核心链路)
    wget -qO /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared
    cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $TOKEN --url http://127.0.0.1:$PORT
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now cloudflared

    echo -e "\n${GREEN}部署成功！${NC} 随机端口: $PORT | 路径: $PATH_WS"
    echo -e "${BLUE}链接: vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&fp=chrome#Tunnel-Pro${NC}"
}

# 4. 卸载与日志
uninstall() {
    systemctl stop cloudflared nginx xray sing-box 2>/dev/null
    rm -rf /etc/nginx/conf.d/tunnel.conf /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared
    echo -e "${RED}已卸载所有相关服务！${NC}"
}

# 菜单系统
echo -e "${YELLOW}Tunnel-Pro 终端控制台${NC}"
echo "1. 部署 Xray | 2. 部署 Sing-box | 3. 查看日志 | 4. 一键卸载 | 5. 退出"
read -p "选择: " opt
case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) journalctl -u cloudflared -f ;;
    4) uninstall ;;
    *) exit 0 ;;
esac
