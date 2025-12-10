#!/bin/bash

# VLESS + Reality 协议自动化安装脚本 (修复版)
# 适用于 Ubuntu 24.04
# 完全原生安装，不使用图形化界面
# 日期: 2024

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 打印信息函数
print_info() {
    echo -e "${GREEN}[信息]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

print_error() {
    echo -e "${RED}[错误]${NC} $1"
}

print_step() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本必须以 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

# 检查系统版本
check_system() {
    if [[ ! -f /etc/os-release ]]; then
        print_error "无法确定系统版本"
        exit 1
    fi
    
    . /etc/os-release
    print_info "检测到系统: $PRETTY_NAME"
    
    if [[ "$ID" != "ubuntu" ]]; then
        print_warning "此脚本设计用于 Ubuntu，当前系统为 $ID，可能会有兼容性问题"
        read -p "是否继续? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# 安装依赖
install_dependencies() {
    print_step "步骤 1: 安装系统依赖"
    
    print_info "更新软件包列表..."
    apt update -qq
    
    print_info "安装必要的工具..."
    apt install -y curl wget unzip jq qrencode uuid-runtime > /dev/null 2>&1
    
    print_info "依赖安装完成 ✓"
}

# 安装 Xray-core
install_xray() {
    print_step "步骤 2: 安装 Xray-core"
    
    print_info "下载并安装 Xray-core..."
    
    # 使用官方安装脚本
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # 验证安装
    if command -v xray &> /dev/null; then
        XRAY_VERSION=$(xray version 2>&1 | head -n 1)
        print_info "安装成功: $XRAY_VERSION ✓"
    else
        print_error "Xray 安装失败"
        exit 1
    fi
}

# 生成密钥对
generate_keys() {
    print_step "步骤 3: 生成 Reality 密钥对"
    
    # 创建临时文件
    local temp_file="/tmp/xray_keys_$.txt"
    
    print_info "正在生成密钥对..."
    xray x25519 > "$temp_file" 2>&1
    
    # 显示原始输出用于调试
    if [[ -f "$temp_file" ]]; then
        print_info "密钥生成输出:"
        cat "$temp_file"
        echo ""
    fi
    
    # 新版 Xray 输出格式: PrivateKey: xxx 和 PublicKey: xxx (没有空格)
    # 或者 Password: xxx (这是公钥的另一个叫法)
    
    # 提取 PrivateKey (私钥)
    PRIVATE_KEY=$(grep "^PrivateKey:" "$temp_file" | cut -d: -f2 | tr -d ' ')
    
    # 提取 PublicKey (公钥) - 新版叫 Password
    PUBLIC_KEY=$(grep "^Password:" "$temp_file" | cut -d: -f2 | tr -d ' ')
    
    # 如果没找到，尝试旧格式
    if [[ -z "$PRIVATE_KEY" ]]; then
        PRIVATE_KEY=$(grep -i "private" "$temp_file" | grep -oE '[A-Za-z0-9_-]{43}' | head -1)
    fi
    
    if [[ -z "$PUBLIC_KEY" ]]; then
        PUBLIC_KEY=$(grep -i "public\|password" "$temp_file" | grep -oE '[A-Za-z0-9_-]{43}' | head -1)
    fi
    
    # 清理临时文件
    rm -f "$temp_file"
    
    # 验证密钥
    if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
        print_error "密钥生成失败！"
        print_error "私钥: '$PRIVATE_KEY'"
        print_error "公钥: '$PUBLIC_KEY'"
        print_error "请手动运行 'xray x25519' 查看输出"
        exit 1
    fi
    
    # 验证密钥长度（Reality 密钥应该是 43 个字符）
    if [[ ${#PRIVATE_KEY} -ne 43 ]] || [[ ${#PUBLIC_KEY} -ne 43 ]]; then
        print_error "密钥长度不正确！私钥: ${#PRIVATE_KEY}, 公钥: ${#PUBLIC_KEY}"
        exit 1
    fi
    
    print_info "私钥 (PrivateKey): $PRIVATE_KEY"
    print_info "公钥 (Password): $PUBLIC_KEY"
    print_info "密钥对生成成功 ✓"
}

# 生成短 ID
generate_short_ids() {
    print_step "步骤 4: 生成 Short ID"
    
    # 生成 8 位随机十六进制字符串
    SHORT_ID=$(openssl rand -hex 8)
    
    print_info "Short ID: $SHORT_ID"
    print_info "Short ID 生成成功 ✓"
}

# 生成 UUID
generate_uuid() {
    print_step "步骤 5: 生成用户 UUID"
    
    # 优先使用 uuidgen
    if command -v uuidgen &> /dev/null; then
        UUID=$(uuidgen)
    else
        # 备用方法
        UUID=$(cat /proc/sys/kernel/random/uuid)
    fi
    
    print_info "UUID: $UUID"
    print_info "UUID 生成成功 ✓"
}

# 获取服务器信息
get_server_info() {
    print_step "步骤 6: 获取服务器信息"
    
    print_info "正在获取服务器公网 IP..."
    
    # 尝试多个 IP 查询服务
    SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org)
    
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s --max-time 5 https://ifconfig.me)
    fi
    
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s --max-time 5 http://checkip.amazonaws.com)
    fi
    
    if [[ -z "$SERVER_IP" ]]; then
        print_error "无法获取服务器 IP，请手动输入"
        read -p "请输入服务器公网 IP: " SERVER_IP
    fi
    
    # 设置监听端口（默认 443）
    PORT=443
    
    # 设置 SNI（回落域名，使用知名网站）
    SNI="www.tesla.com"
    
    print_info "服务器 IP: $SERVER_IP"
    print_info "监听端口: $PORT"
    print_info "回落域名 (SNI): $SNI"
    print_info "服务器信息获取成功 ✓"
}

# 创建配置文件
create_config() {
    print_step "步骤 7: 创建 Xray 配置文件"
    
    # 确保配置目录存在
    mkdir -p /usr/local/etc/xray
    
    # 备份原配置文件（如果存在）
    if [[ -f /usr/local/etc/xray/config.json ]]; then
        local backup_file="/usr/local/etc/xray/config.json.bak.$(date +%Y%m%d_%H%M%S)"
        cp /usr/local/etc/xray/config.json "$backup_file"
        print_info "原配置文件已备份到: $backup_file"
    fi
    
    print_info "正在生成配置文件..."
    
    # 创建新配置文件
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

    # 验证配置文件中的密钥
    local config_private_key=$(cat /usr/local/etc/xray/config.json | grep -oP '"privateKey":\s*"\K[^"]+')
    
    if [[ "$config_private_key" != "$PRIVATE_KEY" ]]; then
        print_error "配置文件中的私钥不匹配！"
        print_error "期望: $PRIVATE_KEY"
        print_error "实际: $config_private_key"
        exit 1
    fi
    
    print_info "配置文件创建成功 ✓"
    print_info "配置文件位置: /usr/local/etc/xray/config.json"
}

# 配置防火墙
configure_firewall() {
    print_step "步骤 8: 配置防火墙"
    
    local firewall_configured=false
    
    # 检查并配置 UFW
    if command -v ufw &> /dev/null; then
        print_info "检测到 UFW 防火墙"
        
        # 检查 UFW 是否启用
        if ufw status | grep -q "Status: active"; then
            ufw allow ${PORT}/tcp > /dev/null 2>&1
            print_info "UFW 规则已添加: 允许端口 ${PORT}/tcp ✓"
            firewall_configured=true
        else
            print_warning "UFW 未启用，跳过配置"
        fi
    fi
    
    # 检查并配置 iptables
    if command -v iptables &> /dev/null && [[ "$firewall_configured" == false ]]; then
        print_info "配置 iptables 防火墙"
        
        # 检查规则是否已存在
        if ! iptables -C INPUT -p tcp --dport ${PORT} -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
            print_info "iptables 规则已添加: 允许端口 ${PORT}/tcp ✓"
            
            # 尝试保存规则
            if command -v netfilter-persistent &> /dev/null; then
                netfilter-persistent save > /dev/null 2>&1
                print_info "防火墙规则已持久化"
            fi
        else
            print_info "iptables 规则已存在"
        fi
        firewall_configured=true
    fi
    
    if [[ "$firewall_configured" == false ]]; then
        print_warning "未检测到防火墙，请确保端口 ${PORT} 可以被外部访问"
    fi
}

# 启动 Xray 服务
start_xray() {
    print_step "步骤 9: 启动 Xray 服务"
    
    print_info "启用 Xray 服务开机自启..."
    systemctl enable xray > /dev/null 2>&1
    
    print_info "启动 Xray 服务..."
    systemctl restart xray
    
    # 等待服务启动
    sleep 2
    
    # 检查服务状态
    if systemctl is-active --quiet xray; then
        print_info "Xray 服务运行正常 ✓"
    else
        print_error "Xray 服务启动失败！"
        print_error "查看详细错误信息:"
        systemctl status xray --no-pager
        exit 1
    fi
}

# 生成客户端配置
generate_client_config() {
    print_step "步骤 10: 生成客户端配置"
    
    # 生成 VLESS 链接
    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-Reality-Server"
    
    # 创建输出目录
    OUTPUT_DIR="/root/xray-config"
    mkdir -p ${OUTPUT_DIR}
    
    print_info "保存配置文件到: ${OUTPUT_DIR}"
    
    # 保存所有密钥信息到单独的文件
    cat > ${OUTPUT_DIR}/keys.txt <<EOF
================================================
              密钥信息 (请妥善保管)
================================================

私钥 (Private Key): ${PRIVATE_KEY}
公钥 (Public Key): ${PUBLIC_KEY}
UUID: ${UUID}
Short ID: ${SHORT_ID}

================================================
EOF

    # 保存完整配置信息到文件
    cat > ${OUTPUT_DIR}/client-config.txt <<EOF
================================================
         VLESS + Reality 客户端配置信息
================================================

【基本信息】
服务器地址: ${SERVER_IP}
端口: ${PORT}
用户 ID (UUID): ${UUID}
传输协议: tcp
流控模式: xtls-rprx-vision

【Reality 协议设置】
传输层安全: reality
服务器名称 (SNI): ${SNI}
公钥 (Public Key): ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
指纹 (Fingerprint): chrome

================================================
         VLESS 分享链接 (一键导入)
================================================

${VLESS_LINK}

================================================
         客户端 JSON 配置 (手动配置用)
================================================

{
  "outbounds": [
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_IP}",
            "port": ${PORT},
            "users": [
              {
                "id": "${UUID}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "${SNI}",
          "publicKey": "${PUBLIC_KEY}",
          "shortId": "${SHORT_ID}",
          "spiderX": ""
        }
      },
      "tag": "proxy"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}

================================================
         推荐客户端软件
================================================

Windows:  v2rayN, Nekoray, Hiddify
macOS:    V2rayU, Qv2ray, Hiddify
Android:  v2rayNG, NekoBox, Hiddify
iOS:      Shadowrocket, Stash, Sing-Box

下载地址:
- v2rayN: https://github.com/2dust/v2rayN/releases
- v2rayNG: https://github.com/2dust/v2rayNG/releases
- Nekoray: https://github.com/MatsuriDayo/nekoray/releases

================================================
         服务管理命令
================================================

启动服务:   systemctl start xray
停止服务:   systemctl stop xray
重启服务:   systemctl restart xray
查看状态:   systemctl status xray
查看日志:   journalctl -u xray -f
测试配置:   xray run -test -config /usr/local/etc/xray/config.json

配置文件:   /usr/local/etc/xray/config.json
日志文件:   journalctl -u xray

================================================
         重要提示
================================================

1. 请妥善保管此配置文件和密钥信息
2. 建议定期更换 UUID 和密钥
3. 如需添加用户，修改配置文件中的 clients 数组
4. 修改配置后记得重启服务: systemctl restart xray

配置文件保存位置:
- 完整配置: ${OUTPUT_DIR}/client-config.txt
- 密钥信息: ${OUTPUT_DIR}/keys.txt
- 分享链接: ${OUTPUT_DIR}/share-link.txt

================================================
EOF

    # 单独保存分享链接
    cat > ${OUTPUT_DIR}/share-link.txt <<EOF
VLESS 分享链接:
${VLESS_LINK}

扫描下方二维码导入配置:
EOF

    # 生成二维码
    if command -v qrencode &> /dev/null; then
        qrencode -t ANSIUTF8 "${VLESS_LINK}" >> ${OUTPUT_DIR}/share-link.txt
        print_info "二维码已生成 ✓"
    fi
    
    print_info "客户端配置生成成功 ✓"
}

# 显示配置信息
display_config() {
    print_step "安装完成！"
    
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    安装成功完成！                          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    cat ${OUTPUT_DIR}/client-config.txt
    
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  配置文件已保存到: ${OUTPUT_DIR}${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# 主函数
main() {
    clear
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         VLESS + Reality 协议自动化安装脚本                 ║${NC}"
    echo -e "${BLUE}║              原生安装 - 无图形界面依赖                     ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    check_system
    install_dependencies
    install_xray
    generate_keys
    generate_short_ids
    generate_uuid
    get_server_info
    create_config
    configure_firewall
    start_xray
    generate_client_config
    display_config
    
    echo ""
    print_info "感谢使用本脚本！"
    print_info "如有问题，请检查: journalctl -u xray -f"
    echo ""
}

# 执行主函数
main
