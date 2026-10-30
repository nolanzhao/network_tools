#!/usr/bin/env bash

# VLESS + REALITY 多端口一键安装脚本
#
# 目标环境：Ubuntu 22.04 / 24.04，root 用户，systemd
# 部署结构：
#   - 自有域名作为 REALITY serverName / 客户端 SNI
#   - Nginx 在公网 443 提供真实 TLS 站点，并在 127.0.0.1:8443 提供回落目标
#   - 10 个 xray@<port> 实例分别监听 10 个 TCP 端口
#   - 不创建 TCP 端口范围的 DNAT/REDIRECT 规则

set -Eeuo pipefail
IFS=$' \n\t'
umask 077

readonly SCRIPT_NAME="$(basename "$0")"
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly XRAY_SERVICE_TEMPLATE="/etc/systemd/system/xray@.service"
readonly FALLBACK_DIR="/etc/xray-reality-fallback"
readonly WEB_ROOT="/var/www/reality-fallback"
readonly NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/reality-fallback"
readonly NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/reality-fallback"
readonly OUTPUT_DIR="/root/xray-reality"
readonly STATE_DIR="/etc/xray-reality-multiport"
readonly ACME_HOME="/root/.acme.sh"
readonly PORT_COUNT=10
readonly PORT_MIN=20000
readonly PORT_MAX=30000

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DOMAIN=""
EMAIL=""
PORTS_RAW=""
SERVER_IP=""
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
ASSUME_YES=false
SKIP_DNS_CHECK=false
declare -a PORTS=()

info() { printf '%b[信息]%b %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%b[警告]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%b[错误]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
step() { printf '\n%b===== %s =====%b\n' "$BLUE" "$*" "$NC"; }

usage() {
    cat <<EOF
用法：
  ${SCRIPT_NAME} [选项]

选项：
  --domain DOMAIN    自有域名，同时用作客户端地址和 REALITY SNI
  --email EMAIL      ACME 证书通知邮箱
  --ports LIST       恰好 10 个 TCP 端口，逗号或空格分隔
                     留空时从 ${PORT_MIN}-${PORT_MAX} 自动选择 10 个未占用端口
  --skip-dns-check   跳过域名 A 记录与本机公网 IPv4 的一致性检查
  -y, --yes          不显示安装前确认提示
  -h, --help         显示帮助

示例：
  ${SCRIPT_NAME} --domain lab.example.com --email admin@example.com
  ${SCRIPT_NAME} --domain lab.example.com --email admin@example.com \\
    --ports '20317,21487,21863,23962,24491,25376,26731,27683,28654,29841'
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            --domain)
                [[ $# -ge 2 ]] || die "--domain 缺少参数"
                DOMAIN="$2"
                shift 2
                ;;
            --email)
                [[ $# -ge 2 ]] || die "--email 缺少参数"
                EMAIL="$2"
                shift 2
                ;;
            --ports)
                [[ $# -ge 2 ]] || die "--ports 缺少参数"
                PORTS_RAW="$2"
                shift 2
                ;;
            --skip-dns-check)
                SKIP_DNS_CHECK=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数：$1（使用 --help 查看帮助）"
                ;;
        esac
    done
}

check_environment() {
    [[ ${EUID} -eq 0 ]] || die "请使用 root 用户运行此脚本"
    [[ -r /etc/os-release ]] || die "无法识别操作系统"

    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == "ubuntu" ]] || die "仅支持 Ubuntu，当前系统为 ${ID:-unknown}"

    case "${VERSION_ID:-}" in
        22.04|24.04) ;;
        *) warn "脚本主要在 Ubuntu 22.04 / 24.04 上使用；当前版本为 ${VERSION_ID:-unknown}" ;;
    esac

    command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd"
    [[ ! -e "${STATE_DIR}/installed.env" ]] || die \
        "检测到已完成的多端口安装：${STATE_DIR}/installed.env。为避免覆盖现有密钥和端口，本脚本不会自动重装。"
}

collect_input() {
    if [[ -z ${DOMAIN} ]]; then
        read -r -p "请输入已解析到本机的域名（例如 lab.example.com）: " DOMAIN
    fi
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"

    if [[ -z ${EMAIL} ]]; then
        read -r -p "请输入 ACME 证书通知邮箱: " EMAIL
    fi

    [[ ${DOMAIN} =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || \
        die "域名格式无效：${DOMAIN}"
    [[ ${EMAIL} =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || \
        die "邮箱格式无效：${EMAIL}"
}

install_dependencies() {
    step "安装依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        ca-certificates curl dnsutils iproute2 jq nginx openssl qrencode socat unzip uuid-runtime
}

check_web_ports() {
    local port listeners
    for port in 80 443 8443; do
        listeners="$(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)"
        [[ -z $listeners ]] && continue
        if [[ $listeners != *nginx* ]]; then
            die "TCP ${port} 已被其他程序占用：${listeners}"
        fi
    done
}

get_public_ipv4() {
    local endpoint result
    for endpoint in \
        "https://api.ipify.org" \
        "https://ifconfig.me/ip" \
        "https://icanhazip.com"; do
        result="$(curl -4fsS --max-time 8 "$endpoint" 2>/dev/null || true)"
        result="${result//$'\n'/}"
        if [[ ${result} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            SERVER_IP="$result"
            return 0
        fi
    done
    return 1
}

check_dns() {
    step "检查 DNS"
    get_public_ipv4 || die "无法获取本机公网 IPv4；可确认网络后重试"
    info "本机公网 IPv4：${SERVER_IP}"

    if [[ ${SKIP_DNS_CHECK} == true ]]; then
        warn "已跳过 DNS 一致性检查"
        return
    fi

    mapfile -t domain_ips < <(dig +short A "$DOMAIN" | sort -u)
    ((${#domain_ips[@]} > 0)) || die "${DOMAIN} 没有可用的 A 记录"

    local ip
    for ip in "${domain_ips[@]}"; do
        if [[ $ip == "$SERVER_IP" ]]; then
            info "DNS 正确：${DOMAIN} -> ${SERVER_IP}"
            return
        fi
    done

    die "${DOMAIN} 当前解析为 ${domain_ips[*]}，不是本机 ${SERVER_IP}。请修正 DNS 并等待生效。"
}

port_is_listening() {
    local port="$1"
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
}

parse_or_generate_ports() {
    step "选择 10 个监听端口"
    local token port
    declare -A seen=()

    if [[ -n ${PORTS_RAW} ]]; then
        PORTS_RAW="${PORTS_RAW//,/ }"
        read -r -a PORTS <<<"$PORTS_RAW"
        ((${#PORTS[@]} == PORT_COUNT)) || die "--ports 必须恰好包含 ${PORT_COUNT} 个端口"

        for token in "${PORTS[@]}"; do
            [[ $token =~ ^[1-9][0-9]*$ ]] || die "无效端口：${token}"
            ((token >= 1024 && token <= 65535)) || die "端口必须在 1024-65535：${token}"
            [[ -z ${seen[$token]+x} ]] || die "端口重复：${token}"
            port_is_listening "$token" && die "端口已被占用：${token}"
            seen[$token]=1
        done
    else
        while IFS= read -r port; do
            port_is_listening "$port" && continue
            PORTS+=("$port")
            ((${#PORTS[@]} == PORT_COUNT)) && break
        done < <(shuf -i "${PORT_MIN}-${PORT_MAX}" -n 100)
        ((${#PORTS[@]} == PORT_COUNT)) || die "无法找到 ${PORT_COUNT} 个空闲端口"
        mapfile -t PORTS < <(printf '%s\n' "${PORTS[@]}" | sort -n)
    fi

    info "监听端口：${PORTS[*]}"
}

confirm_install() {
    [[ ${ASSUME_YES} == true ]] && return
    printf '\n将安装以下结构：\n'
    printf '  域名 / SNI : %s\n' "$DOMAIN"
    printf '  公网 IPv4  : %s\n' "$SERVER_IP"
    printf '  TCP 端口   : %s\n' "${PORTS[*]}"
    printf '  回落目标   : 127.0.0.1:8443 (Nginx TLS)\n'
    printf '  公网网站   : https://%s/\n\n' "$DOMAIN"

    local reply
    read -r -p "确认继续？[y/N] " reply
    [[ $reply =~ ^[Yy]$ ]] || die "用户取消安装"
}

install_xray() {
    step "安装最新版 Xray-core"
    local installer
    installer="$(mktemp /tmp/xray-install.XXXXXX.sh)"
    curl -fsSL "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" -o "$installer"
    bash "$installer" install
    rm -f "$installer"
    command -v xray >/dev/null 2>&1 || die "Xray 安装失败"
    info "$(xray version | head -n 1)"
}

generate_credentials() {
    step "生成独立凭据"
    local key_output
    key_output="$(xray x25519 2>&1)"
    PRIVATE_KEY="$(awk -F': *' '/^Private[Kk]ey:/ {print $2; exit}' <<<"$key_output")"
    PUBLIC_KEY="$(awk -F': *' '/^(Password|Public[Kk]ey):/ {print $2; exit}' <<<"$key_output")"

    [[ ${#PRIVATE_KEY} -eq 43 ]] || die "无法从 xray x25519 输出中提取私钥"
    [[ ${#PUBLIC_KEY} -eq 43 ]] || die "无法从 xray x25519 输出中提取客户端公钥/Password"

    UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    SHORT_ID="$(openssl rand -hex 8)"
    info "UUID、REALITY 密钥和 Short ID 已生成"
}

prepare_webroot() {
    install -d -m 0755 "$WEB_ROOT" "${WEB_ROOT}/.well-known/acme-challenge"
    cat > "${WEB_ROOT}/index.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${DOMAIN}</title></head>
<body><h1>It works.</h1></body>
</html>
EOF
    chmod 0644 "${WEB_ROOT}/index.html"
}

write_http_nginx_config() {
    cat > "$NGINX_SITE_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEB_ROOT};

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 302 https://\$host\$request_uri;
    }
}
EOF
    ln -sfn "$NGINX_SITE_AVAILABLE" "$NGINX_SITE_ENABLED"
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx
}

issue_certificate() {
    step "申请域名证书"
    prepare_webroot
    write_http_nginx_config

    if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
        curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
    fi

    "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt
    "${ACME_HOME}/acme.sh" --issue \
        --domain "$DOMAIN" \
        --webroot "$WEB_ROOT" \
        --server letsencrypt

    install -d -m 0700 "$FALLBACK_DIR"
    "${ACME_HOME}/acme.sh" --install-cert \
        --domain "$DOMAIN" \
        --key-file "${FALLBACK_DIR}/key.pem" \
        --fullchain-file "${FALLBACK_DIR}/fullchain.pem" \
        --reloadcmd "systemctl reload nginx"

    chmod 0600 "${FALLBACK_DIR}/key.pem"
    chmod 0644 "${FALLBACK_DIR}/fullchain.pem"
}

write_final_nginx_config() {
    step "配置 Nginx TLS 回落站点"
    cat > "$NGINX_SITE_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEB_ROOT};

    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }

    location / {
        return 302 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 127.0.0.1:8443 ssl;
    server_name ${DOMAIN};
    root ${WEB_ROOT};

    ssl_certificate ${FALLBACK_DIR}/fullchain.pem;
    ssl_certificate_key ${FALLBACK_DIR}/key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    server_tokens off;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    nginx -t
    systemctl reload nginx
}

write_xray_service_template() {
    if [[ -e $XRAY_SERVICE_TEMPLATE ]]; then
        cp -a "$XRAY_SERVICE_TEMPLATE" "${XRAY_SERVICE_TEMPLATE}.bak.$(date +%Y%m%d_%H%M%S)"
    fi

    cat > "$XRAY_SERVICE_TEMPLATE" <<'EOF'
[Unit]
Description=Xray VLESS REALITY instance on port %i
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target nginx.service
Wants=network-online.target
Requires=nginx.service

[Service]
Type=simple
User=nobody
Group=nogroup
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/%i.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

write_xray_configs() {
    step "创建 10 个 Xray REALITY 实例"
    install -d -m 0755 "$XRAY_CONFIG_DIR"
    write_xray_service_template

    local port config
    for port in "${PORTS[@]}"; do
        config="${XRAY_CONFIG_DIR}/${port}.json"
        [[ ! -e $config ]] || cp -a "$config" "${config}.bak.$(date +%Y%m%d_%H%M%S)"
        cat > "$config" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
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
        "method": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "127.0.0.1:8443",
          "xver": 0,
          "serverNames": [
            "${DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
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
        "ip": ["geoip:private"],
        "outboundTag": "block"
      }
    ]
  }
}
EOF
        chmod 0640 "$config"
        chown root:nogroup "$config"
        xray run -test -config "$config"
    done
}

configure_firewall() {
    step "配置防火墙"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        ufw allow 80/tcp comment 'ACME HTTP challenge'
        ufw allow 443/tcp comment 'Nginx HTTPS'
        local port
        for port in "${PORTS[@]}"; do
            ufw allow "${port}/tcp" comment 'Xray VLESS REALITY'
        done
        info "已添加 UFW 规则"
    else
        warn "UFW 未启用；请同时在云厂商防火墙中开放 TCP 80、443 和这 10 个端口：${PORTS[*]}"
    fi
}

start_instances() {
    step "启动 Xray 实例"
    systemctl disable --now xray.service >/dev/null 2>&1 || true
    systemctl daemon-reload

    local port
    for port in "${PORTS[@]}"; do
        systemctl enable --now "xray@${port}.service"
    done

    sleep 2
    for port in "${PORTS[@]}"; do
        systemctl is-active --quiet "xray@${port}.service" || {
            systemctl status "xray@${port}.service" --no-pager || true
            die "xray@${port}.service 启动失败"
        }
    done
}

write_client_files() {
    step "生成客户端配置"
    install -d -m 0700 "$OUTPUT_DIR" "$STATE_DIR"
    local port link

    : > "${OUTPUT_DIR}/share-links.txt"
    chmod 0600 "${OUTPUT_DIR}/share-links.txt"
    for port in "${PORTS[@]}"; do
        link="vless://${UUID}@${DOMAIN}:${port}?encryption=none&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&flow=xtls-rprx-vision#VLESS-Reality-${port}"
        printf '%s\n' "$link" >> "${OUTPUT_DIR}/share-links.txt"
        qrencode -o "${OUTPUT_DIR}/qr-${port}.png" -s 8 -m 2 "$link"
    done

    jq -n \
        --arg domain "$DOMAIN" \
        --arg uuid "$UUID" \
        --arg public_key "$PUBLIC_KEY" \
        --arg short_id "$SHORT_ID" \
        --argjson ports "$(printf '%s\n' "${PORTS[@]}" | jq -R 'tonumber' | jq -s .)" \
        '{
          type: "vless",
          tag: "vless-reality",
          server: $domain,
          server_port: $ports[0],
          uuid: $uuid,
          flow: "xtls-rprx-vision",
          tls: {
            enabled: true,
            server_name: $domain,
            utls: {enabled: true, fingerprint: "chrome"},
            reality: {enabled: true, public_key: $public_key, short_id: $short_id}
          },
          available_server_ports: $ports
        }' > "${OUTPUT_DIR}/sing-box-outbound.json"

    cat > "${OUTPUT_DIR}/server-secrets.txt" <<EOF
域名 / SNI: ${DOMAIN}
公网 IPv4: ${SERVER_IP}
端口: ${PORTS[*]}
UUID: ${UUID}
REALITY Private Key（仅服务端）: ${PRIVATE_KEY}
REALITY Public Key / Password（客户端）: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}
EOF
    chmod 0600 "${OUTPUT_DIR}/server-secrets.txt" "${OUTPUT_DIR}/sing-box-outbound.json"

    cat > "${STATE_DIR}/installed.env" <<EOF
DOMAIN=${DOMAIN}
PORTS=${PORTS[*]}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    chmod 0600 "${STATE_DIR}/installed.env"
}

verify_installation() {
    step "安装后自检"
    nginx -t
    curl --noproxy '*' -fsS --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" >/dev/null

    local port
    for port in "${PORTS[@]}"; do
        xray run -test -config "${XRAY_CONFIG_DIR}/${port}.json"
        ss -H -ltn "sport = :${port}" | grep -q . || die "端口 ${port} 未监听"
    done
    ss -H -ltn "sport = :8443" | grep -q '127.0.0.1:8443' || die "Nginx 未监听 127.0.0.1:8443"
    info "Nginx、10 份 Xray 配置、服务状态和监听端口均通过检查"
}

show_result() {
    printf '\n%b安装完成%b\n' "$GREEN" "$NC"
    printf '域名 / SNI: %s\n' "$DOMAIN"
    printf '10 个 TCP 端口: %s\n' "${PORTS[*]}"
    printf '客户端配置: %s/sing-box-outbound.json\n' "$OUTPUT_DIR"
    printf '分享链接: %s/share-links.txt\n' "$OUTPUT_DIR"
    printf '二维码: %s/qr-<端口>.png\n' "$OUTPUT_DIR"
    printf '服务端密钥备份: %s/server-secrets.txt\n' "$OUTPUT_DIR"
    printf '\n常用命令：\n'
    printf "  systemctl status 'xray@*'\n"
    printf '  journalctl -u xray@%s -n 100 --no-pager\n' "${PORTS[0]}"
    printf '  xray run -test -config %s/%s.json\n' "$XRAY_CONFIG_DIR" "${PORTS[0]}"
    printf '\n请确认云厂商防火墙已开放 TCP 80、443 和上述 10 个端口。\n'
}

main() {
    parse_args "$@"
    check_environment
    collect_input
    install_dependencies
    check_web_ports
    check_dns
    parse_or_generate_ports
    confirm_install
    install_xray
    generate_credentials
    issue_certificate
    write_final_nginx_config
    write_xray_configs
    configure_firewall
    start_instances
    write_client_files
    verify_installation
    show_result
}

main "$@"
