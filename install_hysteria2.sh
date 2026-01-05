#!/bin/bash

# Hysteria2 一键安装脚本
# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印彩色信息
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 权限运行"
        exit 1
    fi
}

# 生成随机密码
generate_password() {
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 24 | head -n 1
}

# 生成随机端口 (30000-40000)
generate_port() {
    echo $((30000 + RANDOM % 10001))
}

# 获取服务器公网 IP
get_public_ip() {
    local ip=$(curl -s4 -m 10 ifconfig.me)
    if [ -z "$ip" ]; then
        ip=$(curl -s4 -m 10 icanhazip.com)
    fi
    if [ -z "$ip" ]; then
        ip=$(curl -s4 -m 10 api.ipify.org)
    fi
    echo "$ip"
}

# 安装依赖
install_dependencies() {
    print_info "安装必要的依赖..."
    
    if command -v apt &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt install -y curl wget qrencode socat cron iptables iptables-persistent
    elif command -v apt-get &> /dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl wget qrencode socat cron iptables iptables-persistent
    elif command -v yum &> /dev/null; then
        yum install -y curl wget qrencode socat cronie
    elif command -v dnf &> /dev/null; then
        dnf install -y curl wget qrencode socat cronie
    else
        print_error "不支持的系统类型"
        exit 1
    fi
}

# 主函数
main() {
    clear
    echo "=================================="
    echo "   Hysteria2 一键安装脚本"
    echo "=================================="
    echo ""
    
    check_root
    
    # 获取用户输入
    read -p "请输入域名: " DOMAIN
    if [ -z "$DOMAIN" ]; then
        print_error "域名不能为空"
        exit 1
    fi
    
    read -p "请输入邮箱: " EMAIL
    if [ -z "$EMAIL" ]; then
        print_error "邮箱不能为空"
        exit 1
    fi
    
    # 端口输入或随机生成
    echo ""
    read -p "请输入监听端口 (留空使用随机端口 30000-40000): " USER_PORT
    if [ -z "$USER_PORT" ]; then
        PORT=$(generate_port)
        print_info "生成随机端口: $PORT"
    else
        # 验证端口号
        if ! [[ "$USER_PORT" =~ ^[0-9]+$ ]] || [ "$USER_PORT" -lt 1 ] || [ "$USER_PORT" -gt 65535 ]; then
            print_error "端口号无效，必须在 1-65535 之间"
            exit 1
        fi
        PORT=$USER_PORT
        print_info "使用指定端口: $PORT"
    fi
    
    echo ""
    print_info "域名: $DOMAIN"
    print_info "邮箱: $EMAIL"
    print_info "端口: $PORT"
    echo ""
    
    # 安装依赖
    install_dependencies
    
    # 生成随机密码
    PASSWORD=$(generate_password)
    print_info "生成随机密码: $PASSWORD"
    
    # 安装 Hysteria2
    print_info "开始安装 Hysteria2..."
    bash <(curl -fsSL https://get.hy2.sh/)
    
    if [ $? -ne 0 ]; then
        print_error "Hysteria2 安装失败"
        exit 1
    fi
    
    print_info "Hysteria2 安装成功"
    
    # 创建配置文件
    print_info "创建配置文件..."
    mkdir -p /etc/hysteria
    
    cat > /etc/hysteria/config.yaml <<EOF
listen: :$PORT

acme:
  domains:
    - $DOMAIN
  email: $EMAIL

auth:
  type: password
  password: $PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF
    
    print_info "配置文件创建成功"
    
    # 安装 acme.sh
    print_info "安装 acme.sh..."
    if [ ! -d ~/.acme.sh ]; then
        curl https://get.acme.sh | sh -s email=$EMAIL
        
        if [ $? -ne 0 ]; then
            print_error "acme.sh 安装失败"
            exit 1
        fi
    else
        print_info "acme.sh 已安装，跳过..."
    fi
    
    # 使 acme.sh 命令立即可用
    source ~/.bashrc 2>/dev/null || true
    
    # 停止可能占用 80 端口的服务
    print_info "检查并停止可能占用 80 端口的服务..."
    systemctl stop hysteria-server 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    
    # 申请证书
    print_info "申请 SSL 证书..."
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone --keylength ec-256 --force
    
    if [ $? -ne 0 ]; then
        print_error "证书申请失败，请检查域名解析是否正确指向此服务器"
        exit 1
    fi
    
    print_info "证书申请成功"
    
    # 安装证书
    print_info "安装证书..."
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
        --key-file /etc/hysteria/private.key \
        --fullchain-file /etc/hysteria/cert.crt \
        --reloadcmd "systemctl restart hysteria-server"
    
    if [ $? -ne 0 ]; then
        print_error "证书安装失败"
        exit 1
    fi
    
    print_info "证书安装成功"
    
    # 设置证书文件权限
    chmod 644 /etc/hysteria/cert.crt
    chmod 600 /etc/hysteria/private.key
    
    # 配置防火墙
    print_info "配置防火墙规则..."
    
    if command -v ufw &> /dev/null; then
        # UFW 防火墙配置
        print_info "检测到 UFW 防火墙，配置端口规则..."
        ufw allow $PORT/tcp comment 'Hysteria2' 2>/dev/null || true
        ufw allow $PORT/udp comment 'Hysteria2' 2>/dev/null || true
        print_info "UFW 防火墙规则已添加 (TCP/UDP $PORT)"
    elif command -v firewall-cmd &> /dev/null; then
        # firewalld 防火墙配置
        print_info "检测到 firewalld 防火墙，配置端口规则..."
        firewall-cmd --permanent --add-port=$PORT/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=$PORT/udp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        print_info "firewalld 防火墙规则已添加 (TCP/UDP $PORT)"
    else
        print_warning "未检测到防火墙，请手动开放端口 $PORT (TCP/UDP)"
    fi
    
    # 启用开机自启
    print_info "设置开机自启..."
    systemctl enable hysteria-server
    
    # 启动服务
    print_info "启动 Hysteria2 服务..."
    if systemctl is-active --quiet hysteria-server; then
        print_info "服务已在运行，重启服务..."
        systemctl restart hysteria-server
    else
        print_info "初次启动服务..."
        systemctl start hysteria-server
    fi
    
    # 等待服务启动
    sleep 3
    
    # 检查服务状态
    if systemctl is-active --quiet hysteria-server; then
        print_info "Hysteria2 服务启动成功"
    else
        print_error "Hysteria2 服务启动失败"
        print_error "请检查日志: journalctl -u hysteria-server -n 50"
        exit 1
    fi
    
    # 获取公网 IP
    PUBLIC_IP=$(get_public_ip)
    
    # 生成连接链接
    HYSTERIA_LINK="hysteria2://${PASSWORD}@${PUBLIC_IP}:${PORT}?sni=${DOMAIN}&insecure=0&allowInsecure=0#HY2"
    
    # 输出结果
    echo ""
    echo "=================================="
    echo "   安装完成！"
    echo "=================================="
    echo ""
    print_info "服务器信息:"
    echo "  域名: $DOMAIN"
    echo "  邮箱: $EMAIL"
    echo "  密码: $PASSWORD"
    echo "  公网IP: $PUBLIC_IP"
    echo "  端口: $PORT"
    echo ""
    print_info "Hysteria2 连接信息:"
    echo ""
    echo "$HYSTERIA_LINK"
    echo ""
    
    # 生成二维码
    print_info "连接二维码:"
    echo ""
    qrencode -t ANSIUTF8 "$HYSTERIA_LINK"
    echo ""
    
    print_warning "客户端配置提示:"
    echo "  - SNI: $DOMAIN"
    echo ""
    
    print_info "服务管理命令:"
    echo "  启动服务: systemctl start hysteria-server"
    echo "  停止服务: systemctl stop hysteria-server"
    echo "  重启服务: systemctl restart hysteria-server"
    echo "  查看状态: systemctl status hysteria-server"
    echo "  查看日志: journalctl -u hysteria-server -f"
    echo ""
    
    print_info "配置文件位置: /etc/hysteria/config.yaml"
    print_info "证书文件位置: /etc/hysteria/cert.crt"
    print_info "私钥文件位置: /etc/hysteria/private.key"
    echo ""
    
    print_warning "重要提示:"
    echo "  - 请确保服务器安全组/防火墙已开放端口: $PORT (TCP/UDP)"
    echo "  - 证书有效期 90 天，acme.sh 会每天自动检查，剩余 60 天时自动续期"
    echo "  - 如需修改配置，请编辑 /etc/hysteria/config.yaml 后重启服务"
    echo ""
}

# 运行主函数
main
