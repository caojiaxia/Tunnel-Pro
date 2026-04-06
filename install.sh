#!/bin/bash

# --- 0. 颜色定义 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'

# --- 1. 核心辅助函数定义 ---
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS="CentOS"; PM="yum"
    elif grep -qi "debian" /etc/os-release; then
        OS="Debian"; PM="apt"
    elif grep -qi "ubuntu" /etc/os-release; then
        OS="Ubuntu"; PM="apt"
    elif grep -qi "arch" /etc/os-release; then
        OS="Arch"; PM="pacman"
    elif grep -qi "alpine" /etc/os-release; then
        OS="Alpine"; PM="apk"
    else
        OS="Unknown"; PM="apt"
    fi

    # 架构检测，确保全系统兼容
    local ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="arm" ;;
        *)       ARCH="amd64" ;;
    esac
}

enable_bbr() {
    if ! lsmod | grep -q bbr; then
        echo -e "${BLUE}>>> 正在尝试开启 BBR 加速...${NC}"
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi
}

# --- 2. 部署与配置逻辑 ---
prepare_env() {
    echo -e "${BLUE}>>> 安装必要组件...${NC}"
    # --- 这里保持你的原样，没问题 ---
    if [[ "$PM" == "apt" ]]; then
        apt update -y && apt install -y nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    elif [[ "$PM" == "yum" ]]; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    elif [[ "$PM" == "pacman" ]]; then
        pacman -Sy --noconfirm nginx curl wget jq net-tools psmisc tar >/dev/null 2>&1
    elif [[ "$PM" == "apk" ]]; then
        apk update && apk add bash nginx curl wget jq net-tools psmisc tar libc6-compat openrc grep >/dev/null 2>&1
    fi
    enable_bbr

    # 修正 1：你的原本写法在没有运行 detect_os 的情况下，${ARCH} 是空的，会导致下载 404
    # 确保 ARCH 变量有值
    [ -z "$ARCH" ] && local ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

    curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared

    echo -e "${BLUE}>>> 正在部署 Sing-box 核心...${NC}"
    if [[ "$OS" == "Alpine" ]]; then
        local SB_VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
        curl -L "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-${ARCH}.tar.gz" -o sb.tar.gz
        tar -zxvf sb.tar.gz >/dev/null 2>&1
        # 修正 2：这里加个路径通配符保护，防止解压目录名不符合预期
        cp sing-box-*/sing-box /usr/bin/sing-box 2>/dev/null || cp sing-box/sing-box /usr/bin/sing-box 2>/dev/null
        chmod +x /usr/bin/sing-box
        rm -rf sb.tar.gz sing-box-*
    else
        # 修正 3：官方脚本在某些非 x86 环境下会因为识别不到 ARCH 而静默失败
        # 建议这里不要加 >/dev/null 2>&1，否则安装失败了你完全不知道原因
        bash -c "$(curl -L https://sing-box.app/install.sh)"
    fi
}
config_services() {
    fuser -k $NAT_PORT/tcp >/dev/null 2>&1
    fuser -k $BACKEND_PORT/tcp >/dev/null 2>&1

    # --- UUID & PATH 持久化逻辑 ---
    local OLD_UUID=""
    local OLD_PATH=""
    if [ -f /etc/sing-box/config.json ]; then
        OLD_UUID=$(jq -r '.inbounds[0].users[0].uuid' /etc/sing-box/config.json 2>/dev/null)
        OLD_PATH=$(jq -r '.inbounds[0].transport.path' /etc/sing-box/config.json 2>/dev/null)
    fi

    UUID=${OLD_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    [[ "$UUID" == "null" || -z "$UUID" ]] && UUID=$(cat /proc/sys/kernel/random/uuid)

    PATH_WS=${OLD_PATH:-"/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"}
    [[ "$PATH_WS" == "null" || -z "$PATH_WS" ]] && PATH_WS="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"

    # 配置生成
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

    # 自动识别路径
    SB_PATH=$(command -v sing-box)
    [ -z "$SB_PATH" ] && SB_PATH="/usr/bin/sing-box"

    # Sing-box 服务管理 (根据 OS 类型切换)
    if [[ "$OS" == "Alpine" ]]; then
        cat <<EOF > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Core Service"
command="$SB_PATH"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
        rc-service sing-box restart >/dev/null 2>&1
    else
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
    fi

    # Nginx 停止与清理
    if [[ "$OS" == "Alpine" ]]; then
        rc-service nginx stop >/dev/null 2>&1
    else
        systemctl stop nginx >/dev/null 2>&1
    fi

    rm -rf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*
    MIME_PATH=$(find /etc/nginx -name mime.types | head -n 1)
    [ -z "$MIME_PATH" ] && MIME_PATH="/etc/nginx/mime.types"

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

    # Nginx 重启
    if [[ "$OS" == "Alpine" ]]; then
        rc-service nginx restart >/dev/null 2>&1
    else
        systemctl restart nginx >/dev/null 2>&1
    fi
}

# --- 3. 增强功能：智能查看节点信息 ---
view_config() {
    if [ ! -f /etc/sing-box/config.json ]; then
        echo -e "${RED}错误：未发现配置文件，请先部署节点。${NC}"
        sleep 2
        return
    fi

    local CONF_UUID=$(jq -r '.inbounds[0].users[0].uuid' /etc/sing-box/config.json)
    local CONF_PATH=$(jq -r '.inbounds[0].transport.path' /etc/sing-box/config.json)
    
    local CONF_DOMAIN=""
    if [ -f /etc/sing-box/.domain ]; then
        CONF_DOMAIN=$(cat /etc/sing-box/.domain)
    elif [ -f /tmp/cf_quick.log ]; then
        # 基于已安装的 GNU grep 使用 -oP 提取
        CONF_DOMAIN=$(grep -oP '(?<=https://)[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_quick.log | head -n 1)
    fi

    local DISPLAY_DOMAIN=${CONF_DOMAIN:-"YOUR_DOMAIN"}

    echo -e "\n${YELLOW}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC}  ${GREEN}当前节点配置信息：${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  域名: ${CYAN}$DISPLAY_DOMAIN${NC}"
    echo -e "${YELLOW}│${NC}  路径: ${CYAN}$CONF_PATH${NC}"
    echo -e "${YELLOW}│${NC}  UUID: ${CYAN}$CONF_UUID${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  ${BLUE}一键导入链接：${NC}"
    echo -e "${YELLOW}│${NC}  ${WHITE}vless://$CONF_UUID@$DISPLAY_DOMAIN:443?path=$(echo $CONF_PATH | sed 's/\//%2F/g')&security=tls&encryption=none&type=ws&sni=$DISPLAY_DOMAIN&host=$DISPLAY_DOMAIN&fp=chrome#Tunnel-Pro${NC}"
    [ -z "$CONF_DOMAIN" ] && echo -e "${YELLOW}│${NC}  ${RED}注意：由于是全新运行，请手动替换链接中的 YOUR_DOMAIN${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
    read -p "按回车键返回主菜单..."
}

# --- 4. 菜单功能函数 ---
deploy_token() {
    detect_os && prepare_env
    echo -e "${CYAN}请输入您的 Cloudflare Tunnel 信息：${NC}"
    read -p "Token: " TOKEN
    read -p "域名 (example.com): " DOMAIN
    echo "$DOMAIN" > /etc/sing-box/.domain
    
    read -p "后端端口 (默认3001): " BACKEND_PORT; BACKEND_PORT=${BACKEND_PORT:-3001}
    read -p "转发端口 (默认8080): " NAT_PORT; NAT_PORT=${NAT_PORT:-8080}
    config_services

    if [[ "$OS" == "Alpine" ]]; then
        cat <<EOF > /etc/init.d/cloudflared
#!/sbin/openrc-run
name="cloudflared"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate run --token $TOKEN"
command_background="yes"
pidfile="/run/cloudflared.pid"
depend() {
    after network
}
EOF
        chmod +x /etc/init.d/cloudflared
        rc-update add cloudflared default >/dev/null 2>&1
        rc-service cloudflared restart >/dev/null 2>&1
    else
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
    fi
    print_done
}

deploy_quick() {
    detect_os && prepare_env
    rm -f /etc/sing-box/.domain
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
    echo -e "${YELLOW}│${NC}  ${GREEN}部署成功！配置详情如下：${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  地址: ${CYAN}https://$FINAL_DOMAIN${NC}"
    echo -e "${YELLOW}│${NC}  路径: ${CYAN}$PATH_WS${NC}"
    echo -e "${YELLOW}│${NC}  UUID: ${CYAN}$UUID${NC}"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${YELLOW}│${NC}  ${BLUE}VLESS 节点链接：${NC}"
    echo -e "${YELLOW}│${NC}  ${WHITE}vless://$UUID@$FINAL_DOMAIN:443?path=$(echo $PATH_WS | sed 's/\//%2F/g')&security=tls&encryption=none&type=ws&sni=$FINAL_DOMAIN&host=$FINAL_DOMAIN&fp=chrome#Tunnel-Pro${NC}"
    echo -e "${YELLOW}└─────────────────────────────────────────────────────┘${NC}"
    read -p "按回车键返回主菜单..."
}

diagnose() {
    clear
    echo -e "${BLUE}=== 链路诊断系统 ===${NC}"
    if [[ "$OS" == "Alpine" ]]; then
        rc-service nginx status >/dev/null 2>&1 && echo -e "Nginx:    ${GREEN}● 运行中${NC}" || echo -e "Nginx:    ${RED}○ 异常${NC}" 
        rc-service sing-box status >/dev/null 2>&1 && echo -e "Sing-box: ${GREEN}● 运行中${NC}" || echo -e "Sing-box: ${RED}○ 异常${NC}" 
        rc-service cloudflared status >/dev/null 2>&1 && echo -e "Tunnel:   ${GREEN}● 运行中${NC}" || echo -e "Tunnel:   ${RED}○ 异常${NC}" 
    else
        systemctl is-active nginx >/dev/null 2>&1 && echo -e "Nginx:    ${GREEN}● 运行中${NC}" || echo -e "Nginx:    ${RED}○ 异常${NC}" 
        systemctl is-active sing-box >/dev/null 2>&1 && echo -e "Sing-box: ${GREEN}● 运行中${NC}" || echo -e "Sing-box: ${RED}○ 异常${NC}" 
        systemctl is-active cloudflared >/dev/null 2>&1 && echo -e "Tunnel:   ${GREEN}● 运行中${NC}" || echo -e "Tunnel:   ${RED}○ 异常${NC}" 
    fi
    echo -e "TCP 端口占用状况："
    netstat -tulpn | grep -E 'nginx|sing-box|cloudflared'
    read -p "按回车键返回主菜单..."
}

uninstall() { 
    echo -e "${RED}正在清理所有服务和配置...${NC}" 
    detect_os
    if [[ "$OS" == "Alpine" ]]; then
        rc-service cloudflared stop >/dev/null 2>&1
        rc-service nginx stop >/dev/null 2>&1
        rc-service sing-box stop >/dev/null 2>&1
        rc-update del cloudflared default >/dev/null 2>&1
        rc-update del nginx default >/dev/null 2>&1
        rc-update del sing-box default >/dev/null 2>&1
        rm -f /etc/init.d/cloudflared /etc/init.d/sing-box
    else
        systemctl stop cloudflared nginx sing-box >/dev/null 2>&1 
        systemctl disable cloudflared nginx sing-box >/dev/null 2>&1 
        rm -rf /etc/systemd/system/cloudflared.service /etc/systemd/system/sing-box.service 
    fi
    pkill -9 cloudflared nginx sing-box >/dev/null 2>&1 
    rm -rf /etc/nginx/conf.d/tunnel.conf /etc/sing-box/ /tmp/cf_quick.log 
    echo -e "${GREEN}卸载完成。${NC}" 
    sleep 2 
}

# --- 5. 主菜单循环 ---
while true; do
    clear
    echo -e "${CYAN}┌─────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}           ${WHITE}BoGe-Tunnel-Pro 控制面板 (全系统兼容) ${NC}          ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}1.${NC} 部署 Token 模式 (自有域名/永久)${NC}                ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}2.${NC} 部署 临时隧道模式 (无需域名/即开即用)${NC}            ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${BLUE}3.${NC} 查看当前节点信息${NC}                             ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${YELLOW}4.${NC} 链路诊断 (排查连接问题)${NC}                        ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${RED}5.${NC} 彻底卸载 (清空环境)${NC}                            ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}  ${WHITE}6.${NC} 退出脚本${NC}                                     ${CYAN}│${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────┘${NC}"
    echo -n -e "${CYAN}请选择序号 [1-6]: ${NC}"
    read opt
    case $opt in
        1) deploy_token ;;
        2) deploy_quick ;;
        3) detect_os && view_config ;; 
        4) detect_os && diagnose ;;
        5) uninstall ;;
        6) clear; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择！${NC}"; sleep 1 ;;
    esac
done
