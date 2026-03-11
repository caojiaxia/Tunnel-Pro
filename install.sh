#!/bin/bash

# Tunnel-Pro 
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

# --- 1. 核心辅助函数 ---
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS="CentOS"; PM="yum"
    elif grep -qi "debian" /etc/issue || grep -qi "debian" /etc/os-release; then
        OS="Debian"; PM="apt"
    elif grep -qi "ubuntu" /etc/issue || grep -qi "ubuntu" /etc/os-release; then
        OS="Ubuntu"; PM="apt"
    elif grep -qi "arch" /etc/os-release; then
        OS="Arch"; PM="pacman"
    else
        OS="Unknown"; PM="apt"
    fi
}

enable_bbr() {
    if ! lsmod | grep -q bbr; then
        echo -e "${BLUE}>>> 正在开启 BBR 加速...${NC}"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

# --- 2. 部署与配置逻辑 ---
prepare_env() {
    echo -e "${BLUE}>>> 安装必要组件...${NC}"
    if [[ "$PM" == "apt" ]]; then
        apt update -y && apt install -y nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    elif [[ "$PM" == "yum" ]]; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    elif [[ "$PM" == "pacman" ]]; then
        pacman -Sy --noconfirm nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    fi
    enable_bbr
    curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
}

config_services() {
    fuser -k $NAT_PORT/tcp >/dev/null 2>&1
    fuser -k $BACKEND_PORT/tcp >/dev/null 2>&1
    UUID=$(cat /proc/sys/kernel/random/uuid); PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    bash -c "$(curl -L https://sing-box.app/install.sh)" >/dev/null 2>&1
    
    mkdir -p /etc/sing-box/
    cat <<EOF > /etc/sing-box/config.json
{
  "inbounds": [{
    "type": "vless", "listen": "127.0.0.1", "listen_port": $BACKEND_PORT,
    "users": [{ "uuid": "$UUID" }],
    "transport": { "type": "ws", "path": "$PATH_WS" }
  }],
  "outbounds": [{ "type": "direct" }]
}
EOF
    SB_PATH=$(command -v sing-box)
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=$SB_PATH run -c /etc/sing-box/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now sing-box

    systemctl stop nginx >/dev/null 2>&1
    rm -rf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*
    MIME_PATH=$(find /etc/nginx -name mime.types | head -n 1)
    cat <<EOF > /etc/nginx/nginx.conf
user root;
worker_processes auto;
events { worker_connections 1024; }
http {
    include $MIME_PATH;
    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
    server {
        listen $NAT_PORT;
        location $PATH_WS {
            proxy_redirect off;
            proxy_pass http://127.0.0.1:$BACKEND_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
        }
        location / { return 200 "OK"; }
    }
}
EOF
    systemctl restart nginx
}

# --- 3. 新增功能：查看节点信息 ---
view_config() {
    if [ ! -f /etc/sing-box/config.json ]; then
        echo -e "${RED}错误：未发现配置文件，请先部署节点。${NC}"
        sleep 2
        return
    fi

    # 提取信息
    local CONF_UUID=$(jq -r '.inbounds[0].users[0].uuid' /etc/sing-box/config.json)
    local CONF_PATH=$(jq -r '.inbounds[0].transport.path' /etc/sing-box/config.json)
    
    # 从 cloudflared 服务或日志中尝试获取域名
    local CONF_DOMAIN=""
    if [ -f /etc/systemd/system/cloudflared.service ]; then
        # 尝试从 Token 模式备份或当前运行状态推断 (Token模式通常需要手动记录或从CF后台看，这里尝试从之前的 done 信息读取)
        # 脚本本身不存储域名，我们尝试从 nginx 配置中提取 HOST
        CONF_DOMAIN=$(grep -oP '(?<=https://)[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log 2>/dev/null | head -n 1)
        [ -z "$CONF_DOMAIN" ] && echo -e "${YELLOW}提示：Token模式域名请参照您的 Cloudflare 后台设置。${NC}"
    fi

    echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC}  ${GREEN}当前节点配置信息：${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  UUID: ${CYAN}$CONF_UUID${NC}"
    echo -e "${YELLOW}│${NC}  路径: ${CYAN}$CONF_PATH${NC}"
    [ -n "$CONF_DOMAIN" ] && echo -e "${YELLOW}│${NC}  临时域名: ${CYAN}$CONF_DOMAIN${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  ${BLUE}通用 VLESS 链接格式 (需自行填入域名)：${NC}"
    echo -e "${YELLOW}│${NC}  ${WHITE}vless://$CONF_UUID@YOUR_DOMAIN:443?path=$(echo $CONF_PATH | sed 's/\//%2F/g')&security=tls&encryption=none&type=ws&sni=YOUR_DOMAIN&host=YOUR_DOMAIN&fp=chrome#Tunnel-Pro${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
    read -p "按回车键返回主菜单..."
}

# --- 4. 菜单功能函数 (保留) ---
deploy_token() {
    detect_os && prepare_env
    echo -e "${CYAN}请输入您的 Cloudflare Tunnel 信息：${NC}"
    read -p "Token: " TOKEN
    read -p "域名 (example.com): " DOMAIN
    read -p "后端端口 (默认3001): " BACKEND_PORT; BACKEND_PORT=${BACKEND_PORT:-3001}
    read -p "转发端口 (默认8080): " NAT_PORT; NAT_PORT=${NAT_PORT:-8080}
    config_services
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
    print_done
}

deploy_quick() {
    detect_os && prepare_env
    read -p "后端端口 (默认3001): " BACKEND_PORT; BACKEND_PORT=${BACKEND_PORT:-3001}
    read -p "转发端口 (默认8080): " NAT_PORT; NAT_PORT=${NAT_PORT:-8080}
    config_services
    echo -e "${BLUE}>>> 正在申请临时域名...${NC}"
    pkill -f "cloudflared" >/dev/null 2>&1
    rm -f /tmp/cf_quick.log
    nohup /usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$NAT_PORT > /tmp/cf_quick.log 2>&1 &
    
    for i in {1..15}; do
        sleep 2
        QUICK_URL=$(grep -o 'https://[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log | head -n 1)
        [ -n "$QUICK_URL" ] && break
    done

    if [ -z "$QUICK_URL" ]; then
        echo -e "${RED}失败！无法获取临时域名。${NC}"
    else
        QUICK_DOMAIN=$(echo $QUICK_URL | sed 's/https:\/\///')
        print_done
    fi
}

print_done() {
    local FINAL_DOMAIN=${DOMAIN:-$QUICK_DOMAIN}
    echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC}  ${GREEN}部署成功！配置详情如下：${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  地址: ${CYAN}https://$FINAL_DOMAIN${NC}"
    echo -e "${YELLOW}│${NC}  路径: ${CYAN}$PATH_WS${NC}"
    echo -e "${YELLOW}│${NC}  UUID: ${CYAN}$UUID${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  ${BLUE}VLESS 节点链接：${NC}"
    echo -e "${YELLOW}│${NC}  ${WHITE}vless://$UUID@$FINAL_DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&encryption=none&type=ws&sni=$FINAL_DOMAIN&host=$FINAL_DOMAIN&fp=chrome#Tunnel-Pro${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
    read -p "按回车键返回主菜单..."
}

diagnose() {
    clear
    echo -e "${BLUE}=== 链路诊断系统 ===${NC}"
    systemctl is-active nginx >/dev/null 2>&1 && echo -e "Nginx:    ${GREEN}● 运行中${NC}" || echo -e "Nginx:    ${RED}○ 异常${NC}"
    systemctl is-active sing-box >/dev/null 2>&1 && echo -e "Sing-box: ${GREEN}● 运行中${NC}" || echo -e "Sing-box: ${RED}○ 异常${NC}"
    echo -e "TCP 端口占用状况："
    netstat -tulpn | grep -E 'nginx|sing-box|cloudflared'
    read -p "按回车键返回主菜单..."
}

uninstall() {
    echo -e "${RED}正在清理所有服务和配置...${NC}"
    systemctl stop cloudflared nginx sing-box >/dev/null 2>&1
    systemctl disable cloudflared nginx sing-box >/dev/null 2>&1
    pkill -9 cloudflared nginx sing-box >/dev/null 2>&1
    rm -rf /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service /etc/nginx/conf.d/tunnel.conf /etc/sing-box/ /tmp/cf_quick.log
    echo -e "${GREEN}卸载完成。${NC}"
    sleep 2
}

# --- 5. 主循环菜单 ---
while true; do
    clear
    echo -e "${CYAN}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}           ${WHITE}Tunnel-Pro 控制面板 (全系统兼容) ${NC}          ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}1.${NC} 部署 Token 模式 (自有域名/永久)${NC}               ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}2.${NC} 部署 临时隧道模式 (无需域名/即开即用)${NC}           ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${BLUE}3.${NC} 查看当前节点信息${NC}                            ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}4.${NC} 链路诊断 (排查连接问题)${NC}                       ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${RED}5.${NC} 彻底卸载 (清空环境)${NC}                           ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${WHITE}6.${NC} 退出脚本${NC}                                     ${CYAN}│${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────┘${NC}"
    echo -n -e "${CYAN}请选择序号 [1-6]: ${NC}"
    read opt

    case $opt in
        1) deploy_token ;;
        2) deploy_quick ;;
        3) view_config ;;
        4) diagnose ;;
        5) uninstall ;;
        6) clear; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择！${NC}"; sleep 1 ;;
    esac
done
