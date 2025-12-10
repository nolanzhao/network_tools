#!/bin/bash

# TUIC 服务端一键安装脚本
# 适用于 Ubuntu 24.04.3 LTS
# 使用官方原生 tuic-server

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 此脚本需要 root 权限运行${NC}"
   echo "请使用以下方式运行:"
   echo "  sudo bash $0"
   exit 1
fi

# 显示欢迎信息并获取域名
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}TUIC 服务端一键安装脚本${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}请输入您的域名:${NC}"
echo "示例: tuic.example.com"
echo ""
read -p "域名: " DOMAIN

# 验证域名是否为空
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}错误: 域名不能为空${NC}"
    exit 1
fi

# 验证域名格式
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    echo -e "${RED}错误: 域名格式不正确${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}使用域名: ${DOMAIN}${NC}"
echo ""

# 获取邮箱地址
echo -e "${YELLOW}请输入您的邮箱地址 (用于证书申请):${NC}"
echo "示例: your@email.com"
echo ""
read -p "邮箱: " EMAIL

# 验证邮箱是否为空
if [ -z "$EMAIL" ]; then
    echo -e "${RED}错误: 邮箱不能为空${NC}"
    exit 1
fi

# 验证邮箱格式
if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo -e "${RED}错误: 邮箱格式不正确${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}使用邮箱: ${EMAIL}${NC}"
echo ""

# 检查系统版本
check_system() {
    echo -e "${GREEN}[1/8] 检查系统版本...${NC}"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            echo -e "${YELLOW}警告: 当前系统不是 Ubuntu，脚本可能无法正常工作${NC}"
        fi
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${GREEN}[2/8] 安装必要依赖...${NC}"
    apt-get update
    apt-get install -y curl wget jq openssl socat cron dnsutils
}

# 获取最新版本并下载 TUIC
download_tuic() {
    echo -e "${GREEN}[3/8] 下载 TUIC 服务端...${NC}"
    
    # 使用固定版本和下载地址
    LATEST_VERSION="1.0.0"
    TUIC_ARCH="x86_64-unknown-linux-gnu"
    
    echo -e "${GREEN}版本: ${LATEST_VERSION}${NC}"
    echo -e "${GREEN}架构: ${TUIC_ARCH}${NC}"
    
    # 固定下载链接
    DOWNLOAD_URL="https://github.com/tuic-protocol/tuic/releases/download/tuic-server-1.0.0/tuic-server-1.0.0-x86_64-unknown-linux-gnu"
    echo -e "${GREEN}下载地址: ${DOWNLOAD_URL}${NC}"
    
    echo -e "${GREEN}正在下载...${NC}"
    
    # 尝试下载，如果失败则使用镜像
    if ! wget -O /usr/local/bin/tuic-server "${DOWNLOAD_URL}" 2>/dev/null; then
        echo -e "${YELLOW}GitHub 下载失败，尝试使用代理镜像...${NC}"
        MIRROR_URL="https://ghproxy.com/${DOWNLOAD_URL}"
        echo -e "${GREEN}镜像地址: ${MIRROR_URL}${NC}"
        
        if ! wget -O /usr/local/bin/tuic-server "${MIRROR_URL}"; then
            echo -e "${RED}下载失败！${NC}"
            echo -e "${YELLOW}请检查网络连接或手动下载${NC}"
            echo -e "${YELLOW}下载地址: ${DOWNLOAD_URL}${NC}"
            exit 1
        fi
    fi
    
    chmod +x /usr/local/bin/tuic-server
    echo -e "${GREEN}TUIC 服务端安装完成${NC}"
}

# 安装 acme.sh
install_acme() {
    echo -e "${GREEN}[4/8] 安装 acme.sh...${NC}"
    
    # 检查是否已作为普通用户安装
    if [ -d "$HOME/.acme.sh" ] && [ "$HOME" != "/root" ]; then
        echo -e "${YELLOW}检测到非 root 用户的 acme.sh 安装，正在卸载...${NC}"
        $HOME/.acme.sh/acme.sh --uninstall 2>/dev/null || true
    fi
    
    # 作为 root 安装
    if [ ! -d "/root/.acme.sh" ]; then
        echo -e "${GREEN}正在为 root 用户安装 acme.sh...${NC}"
        curl https://get.acme.sh | sh -s email=$EMAIL
        
        # 加载 acme.sh 环境
        . /root/.acme.sh/acme.sh.env
    else
        echo -e "${YELLOW}acme.sh 已安装${NC}"
        # 确保环境变量加载
        [ -f /root/.acme.sh/acme.sh.env ] && . /root/.acme.sh/acme.sh.env
    fi
    
    # 设置默认 CA 为 Let's Encrypt（避免 ZeroSSL 注册问题）
    /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    echo -e "${GREEN}已设置使用 Let's Encrypt CA${NC}"
}

# 申请证书
request_certificate() {
    echo -e "${GREEN}[5/8] 申请 SSL 证书...${NC}"
    
    CERT_DIR="/etc/tuic"
    mkdir -p $CERT_DIR
    
    # 检查证书是否已存在
    if [ -f "$CERT_DIR/cert.crt" ] && [ -f "$CERT_DIR/private.key" ]; then
        echo -e "${GREEN}✓ 检测到已有证书${NC}"
        echo -e "${YELLOW}证书路径: $CERT_DIR/cert.crt${NC}"
        echo -e "${YELLOW}私钥路径: $CERT_DIR/private.key${NC}"
        return 0
    fi
    
    # 验证域名解析
    echo ""
    echo -e "${YELLOW}验证域名解析...${NC}"
    
    # 优先获取 IPv4 地址
    SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || curl -4 -s ip.sb)
    
    # 如果没有 IPv4，尝试获取 IPv6
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(curl -6 -s ifconfig.me || curl -6 -s icanhazip.com)
        IP_VERSION="IPv6"
    else
        IP_VERSION="IPv4"
    fi
    
    RESOLVED_IP=$(dig +short $DOMAIN @8.8.8.8 A | tail -n1)
    
    # 如果没有 A 记录，尝试 AAAA 记录
    if [ -z "$RESOLVED_IP" ]; then
        RESOLVED_IP=$(dig +short $DOMAIN @8.8.8.8 AAAA | tail -n1)
    fi
    
    echo "服务器 IP ($IP_VERSION): $SERVER_IP"
    echo "域名解析 IP: $RESOLVED_IP"
    
    if [ -z "$RESOLVED_IP" ]; then
        echo -e "${RED}错误: 域名无法解析，请检查 DNS 设置${NC}"
        echo -e "${YELLOW}请在域名控制面板添加 A 记录，指向服务器 IP: $SERVER_IP${NC}"
        exit 1
    fi
    
    if [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
        echo -e "${YELLOW}警告: 域名解析 IP 与服务器 IP 不一致！${NC}"
        echo -e "${YELLOW}这可能导致证书申请失败${NC}"
        echo ""
        read -p "是否继续? (y/n): " continue_choice
        if [ "$continue_choice" != "y" ] && [ "$continue_choice" != "Y" ]; then
            exit 1
        fi
    else
        echo -e "${GREEN}✓ 域名解析验证通过${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}请选择证书验证方式:${NC}"
    echo "1) HTTP-01 验证 (自动，需要开放 80 端口) - 推荐"
    echo "2) DNS-01 验证 (手动添加 DNS TXT 记录)"
    echo ""
    read -p "请选择 [1-2, 默认1]: " validation_choice
    validation_choice=${validation_choice:-1}
    
    case $validation_choice in
        1)
            # HTTP-01 验证
            echo ""
            echo -e "${GREEN}使用 HTTP-01 验证方式申请证书...${NC}"
            echo -e "${YELLOW}确保 80 端口未被占用${NC}"
            echo ""
            
            # 临时开放 80 端口
            if command -v ufw &> /dev/null; then
                ufw allow 80/tcp
            fi
            
            # 申请证书
            /root/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256
            
            # 安装证书（首次安装不设置 reload 命令）
            /root/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
                --key-file $CERT_DIR/private.key \
                --fullchain-file $CERT_DIR/cert.crt
            
            # 关闭 80 端口
            if command -v ufw &> /dev/null; then
                ufw delete allow 80/tcp
            fi
            ;;
        2)
            # DNS-01 验证
            echo ""
            echo -e "${GREEN}使用 DNS-01 验证方式申请证书...${NC}"
            
            # 生成 DNS 记录
            /root/.acme.sh/acme.sh --issue -d $DOMAIN --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please --keylength ec-256
            
            echo ""
            echo -e "${YELLOW}请按照上面的提示，在您的 DNS 服务商处添加 TXT 记录${NC}"
            echo -e "${YELLOW}添加完成后，等待 DNS 生效 (通常 1-10 分钟)${NC}"
            echo ""
            read -p "添加完成并等待生效后，按回车键继续..."
            
            # 完成验证
            /root/.acme.sh/acme.sh --renew -d $DOMAIN --yes-I-know-dns-manual-mode-enough-go-ahead-please --ecc
            
            # 安装证书（首次安装不设置 reload 命令）
            /root/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
                --key-file $CERT_DIR/private.key \
                --fullchain-file $CERT_DIR/cert.crt
            ;;
        *)
            echo -e "${RED}无效的选项${NC}"
            exit 1
            ;;
    esac
    
    echo -e "${GREEN}✓ 证书申请完成${NC}"
    echo -e "${GREEN}✓ 证书将自动续期${NC}"
    
    # 设置证书自动续期时的重载命令
    /root/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
        --key-file $CERT_DIR/private.key \
        --fullchain-file $CERT_DIR/cert.crt \
        --reloadcmd "systemctl restart tuic-server" 2>/dev/null || true
}
# 生成随机密码
generate_password() {
    openssl rand -base64 16
}

# 生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# 创建配置文件
create_config() {
    echo -e "${GREEN}[6/8] 创建配置文件...${NC}"
    
    CONFIG_FILE="/etc/tuic/config.json"
    CERT_DIR="/etc/tuic"
    
    # 生成随机端口 (10000-60000)
    PORT=$((RANDOM % 50000 + 10000))
    
    # 生成随机密码和 UUID
    PASSWORD=$(generate_password)
    UUID=$(generate_uuid)
    
    cat > $CONFIG_FILE << EOF
{
    "server": "[::]:${PORT}",
    "users": {
        "${UUID}": "${PASSWORD}"
    },
    "certificate": "/etc/tuic/cert.crt",
    "private_key": "/etc/tuic/private.key",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "log_level": "info"
}
EOF
    
    echo -e "${GREEN}配置文件创建完成: ${CONFIG_FILE}${NC}"
    
    # 获取服务器 IP（优先 IPv4）
    SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || curl -4 -s ip.sb || echo "YOUR_SERVER_IP")
    
    # URL 编码密码（处理特殊字符如 + / =）
    PASSWORD_ENCODED=$(echo -n "$PASSWORD" | jq -sRr @uri)
    
    # 保存连接信息
    cat > /etc/tuic/client-info.txt << EOF
===========================================
TUIC 服务端安装完成
===========================================

服务器信息:
服务器地址: ${DOMAIN}
服务器 IP: ${SERVER_IP}
端口: ${PORT}
UUID: ${UUID}
密码: ${PASSWORD}
ALPN: h3
拥塞控制: bbr

客户端配置示例 (tuic-client):
注意: 请将 "ip" 字段替换为实际服务器 IP 地址

{
  "relay": {
    "server": "${DOMAIN}:${PORT}",
    "uuid": "${UUID}",
    "password": "${PASSWORD}",
    "ip": "${SERVER_IP}",
    "congestion_control": "bbr",
    "udp_relay_mode": "native",
    "alpn": ["h3"],
    "zero_rtt_handshake": false,
    "disable_sni": false
  },
  "local": {
    "server": "127.0.0.1:1080"
  },
  "log_level": "info"
}

V2rayN / Shadowrocket URL:
tuic://${UUID}%3A${PASSWORD_ENCODED}@${DOMAIN}:${PORT}?sni=${DOMAIN}&alpn=h3&insecure=0&allowInsecure=0&congestion_control=bbr#TUIC

===========================================
EOF

    # 生成客户端配置文件示例
    cat > /etc/tuic/client-config.json.example << EOF
{
  "relay": {
    "server": "${DOMAIN}:${PORT}",
    "uuid": "${UUID}",
    "password": "${PASSWORD}",
    "ip": "${SERVER_IP}",
    "congestion_control": "bbr",
    "udp_relay_mode": "native",
    "alpn": ["h3"],
    "zero_rtt_handshake": false,
    "disable_sni": false
  },
  "local": {
    "server": "127.0.0.1:1080"
  },
  "log_level": "info"
}
EOF
    
    echo -e "${GREEN}客户端配置示例文件已生成: /etc/tuic/client-config.json.example${NC}"
    
    # 保存变量供后续使用
    echo "$PORT" > /tmp/tuic_port
    echo "$DOMAIN" > /tmp/tuic_domain
}

# 创建 systemd 服务
create_systemd_service() {
    echo -e "${GREEN}[7/8] 创建 systemd 服务...${NC}"
    
    cat > /etc/systemd/system/tuic-server.service << EOF
[Unit]
Description=TUIC Server
Documentation=https://github.com/tuic-protocol/tuic
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    echo -e "${GREEN}systemd 服务创建完成${NC}"
}

# 配置防火墙
configure_firewall() {
    echo -e "${GREEN}[8/8] 配置防火墙...${NC}"
    
    PORT=$(cat /tmp/tuic_port)
    
    if command -v ufw &> /dev/null; then
        ufw allow $PORT/udp
        echo -e "${GREEN}UFW 防火墙规则已添加${NC}"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=$PORT/udp
        firewall-cmd --reload
        echo -e "${GREEN}firewalld 防火墙规则已添加${NC}"
    else
        echo -e "${YELLOW}未检测到防火墙，请手动开放 UDP 端口 $PORT${NC}"
    fi
}

# 启动服务
start_service() {
    echo -e "${GREEN}[9/9] 启动 TUIC 服务...${NC}"
    
    systemctl enable tuic-server
    systemctl start tuic-server
    
    sleep 2
    
    if systemctl is-active --quiet tuic-server; then
        echo -e "${GREEN}✓ TUIC 服务启动成功!${NC}"
    else
        echo -e "${RED}TUIC 服务启动失败，请查看日志: journalctl -u tuic-server -f${NC}"
        exit 1
    fi
}

# 显示安装信息
show_info() {
    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}TUIC 服务端安装完成!${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    cat /etc/tuic/client-info.txt
    echo ""
    echo -e "${YELLOW}配置文件保存位置:${NC}"
    echo -e "  连接信息: /etc/tuic/client-info.txt"
    echo -e "  客户端配置: /etc/tuic/client-config.json.example"
    echo ""
    echo -e "${YELLOW}服务管理命令:${NC}"
    echo -e "  启动服务: systemctl start tuic-server"
    echo -e "  停止服务: systemctl stop tuic-server"
    echo -e "  重启服务: systemctl restart tuic-server"
    echo -e "  查看状态: systemctl status tuic-server"
    echo -e "  查看日志: journalctl -u tuic-server -f"
    echo ""
    
    # 清理临时文件
    rm -f /tmp/tuic_port /tmp/tuic_domain
}

# 主函数
main() {
    check_system
    install_dependencies
    download_tuic
    install_acme
    request_certificate
    create_config
    create_systemd_service
    configure_firewall
    start_service
    show_info
}

# 执行主函数
main
