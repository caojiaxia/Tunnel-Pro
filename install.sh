#!/bin/bash

# Tunnel-Pro 核心整合版 (不再遗漏任何参数与链接)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 1. 进度反馈函数
show_progress() {
    local pid=$1; local msg=$2
    echo -ne "${BLUE}>>> ${msg}... ${NC}"
    while kill -0 $pid 2>/dev/null; do echo -ne "."; sleep 1; done
    echo -e " ${GREEN}完成!${NC}"
}

# 2. 环境清理与预检
check_env() {
    [[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 权限运行!${NC}" && exit 1
    echo -e "${BLUE}>>> 正在同步环境依赖并清理旧配置...${NC}"
    [ -f /usr/bin/apt ] && apt update -y && apt install -y nginx curl wget jq net-tools || yum install -y nginx curl wget jq net-tools
    # 核心修复：移除 Nginx 默认站点防止冲突
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/conf.d/default.conf
}

# 3. 部署逻辑
deploy() {
    check_env
    local CORE=$1
    echo -e "${YELLOW}--- 请输入配置参数 ---${NC}"
    read -p "请输入 Cloudflare Tunnel Token: " TOKEN
    read -p "请输入 SNI 域名 (如: cloud.yourdomain.com): " DOMAIN
    read -p "请输入伪装 Host (如: www.bing.com): " HOST
    
    if [ "$CORE" == "singbox" ]; then
        read -p "请输入 Sing-box 监听端口 (需与 CF 后台一致): " BACKEND_PORT
    else
        echo -e "${BLUE}>>> Xray 将监听固定端口: 8080${NC}"
        BACKEND_PORT=8080
    fi
    read -p "请输入 Nginx 监听的 NAT 映射端口: " NAT_PORT
    
    UUID=$(cat /proc/sys/kernel/random/uuid)
    PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # --- 步骤 1: 安装与配置核心 ---
    if [ "$CORE" == "xray" ]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 &
        show_progress $! "正在安装 Xray"
        mkdir -p /usr/local/etc/xray
        cat <<EOF > /usr/local/etc/xray/config.json
{"inbounds":[{"port":8080,"protocol":"vless","settings":{"clients":[{"id":"$UUID"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$PATH_WS"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
        systemctl restart xray >/dev/null 2>&1
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
        systemctl daemon-reload && systemctl restart sing-box >/dev/null 2>&1
    fi

    # --- 步骤 2: 配置 Nginx 反代 ---
    echo -ne "${BLUE}>>> 正在配置 Nginx 转发到端口 $BACKEND_PORT...${NC}"
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
    systemctl restart nginx >/dev/null 2>&1 && echo -e " ${GREEN}完成!${NC}" || { echo -e " ${RED}Nginx 启动失败，请检查端口 $NAT_PORT 是否被占用${NC}"; exit 1; }

    # --- 步骤 3: 启动 Cloudflare Tunnel ---
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
    systemctl daemon-reload && systemctl enable --now cloudflared >/dev/null 2>&1
    
    # --- 最终节点输出 (承上启下的关键) ---
    echo -e "\n${YELLOW}==============================================${NC}"
    echo -e "${GREEN}部署成功! 运行信息如下：${NC}"
    echo -e "核心类型: $CORE"
    echo -e "后端监听: $BACKEND_PORT"
    echo -e "NAT 监听: $NAT_PORT"
    echo -e "UUID: $UUID"
    echo -e "路径: $PATH_WS"
    echo -e "\n${YELLOW}请将下方链接导入客户端：${NC}"
    echo -e "${BLUE}vless://$UUID@$DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&type=ws&sni=$DOMAIN&host=$HOST&fp=chrome#Tunnel-Pro-NAT${NC}"
    echo -e "${YELLOW}==============================================${NC}"
}

# 4. 辅助功能
diagnose() {
    echo -e "${BLUE}>>> 正在进行链路诊断...${NC}"
    pgrep -x xray >/dev/null || pgrep -x sing-box >/dev/null && echo -e "核心状态: ${GREEN}正常${NC}" || echo -e "核心状态: ${RED}异常${NC}"
    systemctl is-active --quiet nginx && echo -e "Nginx 状态: ${GREEN}正常${NC}" || echo -e "Nginx 状态: ${RED}异常${NC}"
    systemctl is-active --quiet cloudflared && echo -e "隧道状态: ${GREEN}正常${NC}" || echo -e "隧道状态: ${RED}异常${NC}"
}

uninstall() {
    systemctl stop cloudflared nginx xray sing-box 2>/dev/null
    rm -f /etc/nginx/conf.d/tunnel.conf /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared
    echo -e "${RED}已彻底卸载。${NC}"
}

# --- 菜单区 ---
echo -e "${BLUE}=== Tunnel-Pro NAT 极致管理终端 ===${NC}"
echo "1. 部署 Xray (8080) | 2. 部署 Sing-box (手动端口) | 3. 查看日志 | 4. 卸载 | 5. 退出 | 6. 链路诊断"
read -p "选择: " opt
case $opt in
    1) deploy "xray" ;;
    2) deploy "singbox" ;;
    3) journalctl -u cloudflared -f ;;
    4) uninstall ;;
    6) diagnose ;;
    *) exit 0 ;;
esac
