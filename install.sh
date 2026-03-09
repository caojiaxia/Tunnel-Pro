#!/bin/bash

# ==========================================================
# Tunnel-Pro v7 Ultimate 
# ==========================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CONFIG_DIR="/etc/sing-box"
INFO_FILE="/etc/tunnel-pro.info"
SUB_DIR="/var/www/html"
SUB_PATH="/sub/$(openssl rand -hex 4)"

WS_PORT=3001
XHTTP_PORT=3002
NGINX_PORT=8080

# --- 基础环境检测 ---

detect_os(){
    if [ -f /etc/debian_version ]; then
        PM="apt"
    elif [ -f /etc/redhat-release ]; then
        PM="yum"
    else
        echo -e "${RED}错误: 不支持的操作系统${NC}"
        exit 1
    fi
}

install_base(){
    echo -e "${BLUE}正在同步系统环境...${NC}"
    if [ "$PM" = "apt" ]; then
        apt update -y && apt install -y curl wget nginx jq qrencode openssl net-tools socat
    else
        yum install -y epel-release
        yum install -y curl wget nginx jq qrencode openssl net-tools socat
    fi
    mkdir -p $SUB_DIR
}

# --- 核心功能实现 ---

enable_bbr(){
    echo -e "${BLUE}优化内核参数 (BBR)...${NC}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    echo -e "${GREEN}BBR 已开启！${NC}"
}

install_singbox(){
    if ! command -v sing-box &> /dev/null; then
        echo -e "${BLUE}正在安装 Sing-box 核心...${NC}"
        bash -c "$(curl -fsSL https://sing-box.app/install.sh)"
    fi
    mkdir -p $CONFIG_DIR
}

install_cloudflared(){
    if ! command -v cloudflared &> /dev/null; then
        echo -e "${BLUE}下载 Cloudflared 二进制文件...${NC}"
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
    fi
}

# --- 配置管理 ---

save_info(){
    cat > $INFO_FILE <<EOF
UUID=$UUID
DOMAIN=$DOMAIN
WS_PATH=$WS_PATH
XHTTP_PATH=$XHTTP_PATH
SUB_URL_PATH=$SUB_URL_PATH
EOF
}

load_info(){
    [ -f $INFO_FILE ] && source $INFO_FILE
}

config_nginx(){
    echo -e "${BLUE}更新 Nginx 路由规则...${NC}"
    cat > /etc/nginx/conf.d/tunnel.conf <<EOF
server {
    listen $NGINX_PORT;
    server_name $DOMAIN;

    location $WS_PATH {
        proxy_pass http://127.0.0.1:$WS_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location $XHTTP_PATH {
        proxy_pass http://127.0.0.1:$XHTTP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location / {
        root /var/www/html;
        index index.html;
    }
}
EOF
    systemctl restart nginx
    systemctl enable nginx
}

# --- 节点安装 ---

install_ws(){
    load_info
    [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
    [ -z "$WS_PATH" ] && WS_PATH="/ws-$(openssl rand -hex 4)"
    [ -z "$DOMAIN" ] && read -p "请输入解析到本机的域名: " DOMAIN
    save_info

    echo -e "${BLUE}部署 VLESS-WS 节点...${NC}"
    cat > $CONFIG_DIR/ws.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": $WS_PORT,
    "users": [{"uuid": "$UUID"}],
    "transport": {"type": "ws", "path": "$WS_PATH"}
  }],
  "outbounds": [{"type": "direct"}]
}
EOF
    create_service "singbox-ws" "$CONFIG_DIR/ws.json"
    config_nginx
    echo -e "${GREEN}VLESS-WS 安装完成${NC}"
}

install_xhttp(){
    load_info
    [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
    [ -z "$XHTTP_PATH" ] && XHTTP_PATH="/xh-$(openssl rand -hex 4)"
    [ -z "$DOMAIN" ] && read -p "请输入解析到本机的域名: " DOMAIN
    save_info

    echo -e "${BLUE}部署 VLESS-XHTTP 节点...${NC}"
    cat > $CONFIG_DIR/xhttp.json <<EOF
{
  "log": {"level": "info"},
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": $XHTTP_PORT,
    "users": [{"uuid": "$UUID"}],
    "transport": {"type": "xhttp", "path": "$XHTTP_PATH", "mode": "auto"}
  }],
  "outbounds": [{"type": "direct"}]
}
EOF
    create_service "singbox-xhttp" "$CONFIG_DIR/xhttp.json"
    config_nginx
    echo -e "${GREEN}VLESS-XHTTP 安装完成${NC}"
}

create_service(){
    cat > /etc/systemd/system/$1.service <<EOF
[Unit]
Description=$1 Service
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c $2
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable $1 && systemctl restart $1
}

# --- Cloudflare Tunnels ---

start_token_tunnel(){
    read -p "请输入您的 Cloudflare Tunnel Token: " CF_TOKEN
    if [ -z "$CF_TOKEN" ]; then
        echo -e "${RED}Token 不能为空${NC}"
        return
    fi
    cat > /etc/systemd/system/cf-tunnel.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token $CF_TOKEN
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable cf-tunnel && systemctl restart cf-tunnel
    echo -e "${GREEN}Cloudflare Token Tunnel 已启动${NC}"
}

start_quick_tunnel(){
    echo -e "${YELLOW}正在启动临时 Tunnel (Quick Tunnel)...${NC}"
    nohup /usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$NGINX_PORT > /tmp/cf_tunnel.log 2>&1 &
    sleep 5
    QUICK_URL=$(grep -o 'https://[-0-9a-z.]*\.trycloudflare\.com' /tmp/cf_tunnel.log | head -n 1)
    echo -e "${CYAN}临时访问地址: ${GREEN}$QUICK_URL${NC}"
    echo -e "${YELLOW}注意: 重启后失效，仅用于紧急测试${NC}"
}

# --- 辅助工具 ---

generate_subscription(){
    load_info
    if [ -z "$UUID" ]; then echo -e "${RED}请先安装节点${NC}"; return; fi
    
    WS_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=ws&security=tls&sni=$DOMAIN&path=$(echo $WS_PATH | sed 's/\//%2F/g')#WS_Node"
    XHTTP_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=xhttp&security=tls&sni=$DOMAIN&path=$(echo $XHTTP_PATH | sed 's/\//%2F/g')#XHTTP_Node"
    
    SUB_CONTENT=$(echo -e "$WS_LINK\n$XHTTP_LINK" | base64 -w 0)
    
    [ -z "$SUB_URL_PATH" ] && SUB_URL_PATH="/sub-$(openssl rand -hex 6)"
    save_info
    
    mkdir -p $SUB_DIR/$(dirname $SUB_URL_PATH)
    echo "$SUB_CONTENT" > "$SUB_DIR$SUB_URL_PATH"
    
    echo -e "${GREEN}订阅已生成！${NC}"
    echo -e "${CYAN}订阅链接: ${WHITE}http://$DOMAIN:8080$SUB_URL_PATH${NC}"
}

diagnose(){
    echo -e "${BLUE}--- 系统诊断报告 ---${NC}"
    echo -n "Nginx 状态: " && systemctl is-active nginx
    echo -n "Sing-box WS: " && systemctl is-active singbox-ws
    echo -n "Sing-box XHTTP: " && systemctl is-active singbox-xhttp
    echo -n "BBR 状态: " && sysctl net.ipv4.tcp_congestion_control
    echo -e "${BLUE}监听端口:${NC}"
    netstat -tlpn | grep -E 'sing-box|nginx'
}

uninstall_all(){
    read -p "确定要卸载所有组件吗？(y/n): " confirm
    if [ "$confirm" = "y" ]; then
        systemctl stop singbox-ws singbox-xhttp nginx cf-tunnel
        systemctl disable singbox-ws singbox-xhttp nginx cf-tunnel
        rm -rf $CONFIG_DIR $INFO_FILE /etc/nginx/conf.d/tunnel.conf /usr/local/bin/cloudflared
        echo -e "${GREEN}全部卸载完成${NC}"
    fi
}

show_nodes(){
    load_info
    if [ -z "$UUID" ]; then echo -e "${RED}未发现已安装节点${NC}"; return; fi
    
    WS_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=ws&security=tls&sni=$DOMAIN&path=$(echo $WS_PATH | sed 's/\//%2F/g')#WS_$DOMAIN"
    echo -e "${GREEN}VLESS-WS 链接:${NC}\n$WS_LINK"
    qrencode -t ANSIUTF8 "$WS_LINK"
    
    XHTTP_LINK="vless://$UUID@$DOMAIN:443?encryption=none&type=xhttp&security=tls&sni=$DOMAIN&path=$(echo $XHTTP_PATH | sed 's/\//%2F/g')#XH_$DOMAIN"
    echo -e "${GREEN}VLESS-XHTTP 链接:${NC}\n$XHTTP_LINK"
    qrencode -t ANSIUTF8 "$XHTTP_LINK"
}

# --- 菜单界面 ---

menu(){
    clear
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${CYAN}      Tunnel-Pro v7 Ultimate Edition      ${NC}"
    echo -e "${CYAN}==========================================${NC}"
    echo -e "${GREEN}1.${NC} 安装/更新 VLESS-WS 节点"
    echo -e "${GREEN}2.${NC} 安装/更新 VLESS-XHTTP 节点"
    echo -e "${BLUE}------------------------------------------${NC}"
    echo -e "${GREEN}3.${NC} 配置 Cloudflare Tunnel (Token 模式)"
    echo -e "${GREEN}4.${NC} 启动 Quick Tunnel (临时测试)"
    echo -e "${BLUE}------------------------------------------${NC}"
    echo -e "${GREEN}5.${NC} 开启 BBR 加速"
    echo -e "${GREEN}6.${NC} 查看节点二维码/链接"
    echo -e "${GREEN}7.${NC} 生成/更新 订阅链接"
    echo -e "${YELLOW}8.${NC} 系统链路诊断"
    echo -e "${RED}9.${NC} 一键彻底卸载"
    echo -e "${GREEN}0.${NC} 退出脚本"
    echo
    read -p "选择操作 [0-9]: " num

    case $num in
        1) install_ws ;;
        2) install_xhttp ;;
        3) start_token_tunnel ;;
        4) start_quick_tunnel ;;
        5) enable_bbr ;;
        6) show_nodes ;;
        7) generate_subscription ;;
        8) diagnose ;;
        9) uninstall_all ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效输入${NC}" ; sleep 1 ; menu ;;
    esac
}

# --- 启动流 ---
detect_os
install_base
install_singbox
install_cloudflared
while true; do menu; done
