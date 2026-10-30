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
    # Xray has used several labels over time:
    #   Private key / Public key
    #   PrivateKey / Password
    #   PrivateKey / Password (PublicKey)
    # Match the label prefix so a cosmetic label change does not break installation.
    PRIVATE_KEY="$(awk -F':[[:space:]]*' '
        tolower($1) ~ /^private[[:space:]]*key/ {print $2; exit}
    ' <<<"$key_output")"
    PUBLIC_KEY="$(awk -F':[[:space:]]*' '
        tolower($1) ~ /^(password|public[[:space:]]*key)/ {print $2; exit}
    ' <<<"$key_output")"

    [[ ${#PRIVATE_KEY} -eq 43 ]] || die "无法从 xray x25519 输出中提取私钥"
    [[ ${#PUBLIC_KEY} -eq 43 ]] || die "无法从 xray x25519 输出中提取客户端公钥/Password"

    UUID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
    SHORT_ID="$(openssl rand -hex 8)"
    info "UUID、REALITY 密钥和 Short ID 已生成"
}

prepare_webroot() {
    # List every level explicitly: with the script-wide umask 077, an implicit
    # intermediate .well-known directory would otherwise be created as 0700,
    # preventing the unprivileged Nginx worker from traversing it.
    install -d -m 0755 \
        "$WEB_ROOT" \
        "${WEB_ROOT}/.well-known" \
        "${WEB_ROOT}/.well-known/acme-challenge"
    cat > "${WEB_ROOT}/index.html" <<'REALITY_FALLBACK_HTML'
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>__REALITY_DOMAIN__</title>
<link rel="icon" href="data:,">
<style>html,body{margin:0;height:100%;overflow:hidden;background:#4aa8e8}canvas{display:block;image-rendering:pixelated}</style>
</head>
<body>
<canvas id="c" role="img" aria-label="像素风海岛动画：飞机、游艇、海豚、鲸鱼、飞鸟和沙滩"></canvas>
<script>
const{sin,cos,abs,min,max,round,floor,PI,random}=Math
const C={k:'#1b2a41',w:'#fff',g:'#c9d6df',b:'#5b7ea6',r:'#e8504a',o:'#f5a623',y:'#ffd75e',n:'#7a4a2a',N:'#4f2f1c',l:'#3fa34d',L:'#2a7a3b',s:'#f3d9a0',c:'#6fd0e8',d:'#39567a',D:'#2a3f5f',e:'#a9bfd1',f:'#6f92b5',F:'#4f6f91',a:'#46505c'}
const mk=(w,h)=>{const c=document.createElement('canvas');c.width=w;c.height=h;return c}
const S=t=>{const r=t.split('|'),c=mk(max(...r.map(l=>l.length)),r.length),x=c.getContext('2d');r.forEach((l,j)=>[...l].forEach((p,i)=>{if(C[p]){x.fillStyle=C[p];x.fillRect(i,j,1,1)}}));return c}

const PLANE=S('....................rr|...................rrr|..................rrrr|.......cc........rrrrr|....wwwccwwwwwwwwwwwrr|..wwwwwwwwwwwwwwwwwwww|..rrrrrrrrrrrrrrrrrrrr|..gwwwwwwwwwwwwwwwwgg|....gggrrrrrrgggg|.......rrrrrr|........rrr')
const YACHT=S('...........k|..........rk|........kkkkkk|.......wwcccccww|.....gwwwwwwwwwwww|...gwcwwcwwcwwcwwwww|.ggwwwwwwwwwwwwwwwwwwww|bbbwwwwwwwwwwwwwwwwwwwww|.bbbbbbbbbbbbbbbbbbbbbb|..rrrrrrrrrrrrrrrrrrrr')
const SAIL=S('...r|...w|..ww|.www|wwww|...n|bbbbbb')
const DOLPHIN=S('........F|.......FF|....ffffffffff|F.fffffffffffkff|FFffffeeeeeeee|F...ff.eeeee')
const WHALE=S('...........ddddddddddd|......ddddddddddddddddddddd|...dddkdddddddddddddddddddddd|.ddddddddddddddddddddddddddddddd.D|eeeeeeeeeeeedddddddddddddddddddddD|.eeeeeeeeeeeeeedddddddddddddddd|...eeeeeeeeeee')
const TAIL=S('dd.......dd|ddd.....ddd|.ddddddddd|...ddddd|....ddd|....ddd|....ddd|....ddd')
const CLOUDS=[S('......wwwwww|...wwwwwwwwwww.www|.wwwwwwwwwwwwwwwwwww|wwwwwwwwwwwwwwwwwwwwww|ggwwwgggwwwwggggwwwggg'),S('....wwww|.wwwwwwwwww|wwwwwwwwwwwww|gggwwggggwggg')]
const BIRD=['a...a|.a.a|..a','|aa.aa|..a'].map(S),GULL=['w...w|.w.w|..w','|ww.ww|..w'].map(S)
const CROWN=S('.....lll...lll|...llLLLl.lLLLll|.lllL..lLlLl..Lll|ll.....LlnlL....ll|l....lllLnLll....l|....ll..L.L..ll|...l....L.L....l')
const HUT=S('......nnnnnn|....nnNNNNNNnn|..nnNNNNNNNNNNnn|nnNNNNNNNNNNNNNNnn|..sssssssssssss|..ssNNNsssskkkss|..ssNNNsssskkkss|..ssNNNsssssssss')
const UMBRELLA=S('.....rrwwrr|...rrrwwwrrr|.rrrrwwwwwrrrr|.......n|.......n|.......n|.......n|.......n')
const CRAB=S('r.....r|rr.r.rr|.rrrrr|r.r.r.r')
const BALL=S('.rr|rwwy|ywwr|.yy')

const hex=h=>[1,3,5].map(i=>parseInt(h.slice(i,i+2),16)),DAY=['#4aa8e8','#c5ecf7']
// 昼夜关键帧：位置、天顶色、地平线色、场景色罩 rgb+a
const KEYS=[[0,...DAY,0,0,0,0],[.5,...DAY,0,0,0,0],[.6,'#4b4a9c','#ff9d6e',120,50,60,.28],[.68,'#141a4d','#4a4a8a',20,25,80,.5],[.85,'#0b1033','#27386e',15,20,70,.58],[.94,'#5570c8','#ffc7a0',90,70,110,.25],[1,...DAY,0,0,0,0]].map(k=>[k[0],hex(k[1]),hex(k[2]),k.slice(3)])
const mix=(a,b,u)=>a.map((v,i)=>v+(b[i]-v)*u),rgb=a=>`rgb(${a.map(round)})`

const cv=document.getElementById('c'),x=cv.getContext('2d'),scene=mk(1,1),g=scene.getContext('2d')
let W,H,hy,cx,iy,rx,ry,far,isle,stars,glints
const d=(s,px,py,f)=>{px=round(px);py=round(py);if(f){g.save();g.translate(px+s.width,py);g.scale(-1,1);g.drawImage(s,0,0);g.restore()}else g.drawImage(s,px,py)}
const p=(col,px,py,w=1,h=1)=>{g.fillStyle=col;g.fillRect(round(px),round(py),w,h)}
const disc=(o,px,py,r,col)=>{o.fillStyle=col;for(let j=-r;j<=r;j++){const w=round((r*r-j*j)**.5);o.fillRect(round(px)-w,round(py)+j,w*2+1,1)}}
const R=a=>1+.16*sin(2*a+.6)+.13*sin(3*a+2.4)+.07*sin(5*a+1.1)+.035*sin(8*a+4)
const inB=(dx,dy,A,B,ph=0,k=1)=>(dx/A)**2+(dy/B)**2<(1+(R(Math.atan2(dy/B,dx/A)+ph)-1)*k)**2
const blob=(o,ex,ey,A,B,col,ph,k)=>{o.fillStyle=col;const m=1.4;for(let j=-B*m|0;j<=B*m;j++)for(let i=-A*m|0;i<=A*m;i++)if(inB(i,j,A,B,ph,k))o.fillRect(ex+i,ey+j,1,1)}

function layout(){
  const s=max(1,floor(min(innerWidth/180,innerHeight/150)))
  W=Math.ceil(innerWidth/s);H=Math.ceil(innerHeight/s)
  cv.width=scene.width=W;cv.height=scene.height=H;g.imageSmoothingEnabled=false
  cv.style.width=W*s+'px';cv.style.height=H*s+'px'
  hy=round(H*.46);iy=round(hy+(H-hy)*.38);cx=round(W*.5);rx=round(min(W*.36,78));ry=16
  stars=Array.from({length:W*hy/110|0},()=>[random()*W,random()*hy,random()*7])
  glints=Array.from({length:W*(H-hy)/170|0},()=>[random()*W,hy+2+random()**1.4*(H-hy),random()*7])
  // 远山 + 海面：静态层
  far=mk(W,H);let o=far.getContext('2d')
  o.fillStyle='#8fb9d0'
  for(let i=0;i<W;i++){const h=max(0,6*sin(i*.03+1)+4*sin(i*.083)+2*sin(i*.21)+1);o.fillRect(i,hy-round(h),1,round(h))}
  const SEA=['#4cc4dc','#39aed2','#2a97c8','#2083bc','#1a6fab','#155d9a']
  SEA.forEach((col,i)=>{
    const y0=hy+round((H-hy)*i/SEA.length),y1=hy+round((H-hy)*(i+1)/SEA.length)
    o.fillStyle=col;o.fillRect(0,y0,W,y1-y0)
    if(i)for(let k=0;k<W;k+=2){o.fillStyle=SEA[i-1];o.fillRect(k,y0,1,1)}
  })
  // 岛：静态层
  isle=mk(W,H);o=isle.getContext('2d')
  blob(o,cx,iy,rx+8,ry+5,'#5fd3d6');blob(o,cx,iy,rx+4,ry+2,'#8be3d8')
  blob(o,cx,iy,rx,ry,'#d9b67a');blob(o,cx,iy-1,rx-1,ry-2,C.s)
  blob(o,cx-2,iy-6,round(rx*.62),9,C.L,2,.5);blob(o,cx-2,iy-8,round(rx*.6),8,C.l,2,.5)
  blob(o,cx+round(rx*.12),iy-11,round(rx*.36),9,C.l,4,.5);blob(o,cx+round(rx*.12),iy-13,round(rx*.26),5,'#57b85f',4,.5)
  for(let i=0;i<90;i++){
    const a=random()*2*PI,u=random()**.5
    const px=round(cx+cos(a)*u*rx*.92*R(a)),py=round(iy+sin(a)*u*ry*.86*R(a)),grass=inB(px-cx+2,py-iy+8,rx*.58,8,2,.5)
    o.fillStyle=grass?C.L:'#e3c48a';o.fillRect(px,py,1,1)
  }
}

function palm(bx,by,h,lean,t){
  for(let i=0;i<h;i++)p(i%3?C.n:C.N,bx+lean*(i/h)**2*6,by-i,2,1)
  const tx=bx+lean*6,ty=by-h
  p(C.N,tx-1,ty+1,2,2);p(C.N,tx+2,ty+1,2,2)
  d(CROWN,tx-8+round(sin(t*1.4+bx)),ty-3)
}

function frame(t){
  const c=(t/120+.12)%1
  let i=0;while(KEYS[i+1][0]<c)i++
  const A=KEYS[i],B=KEYS[i+1],u=(c-A[0])/(B[0]-A[0]),top=mix(A[1],B[1],u),bot=mix(A[2],B[2],u),tint=mix(A[3],B[3],u),night=max(0,(tint[3]-.3)/.28)
  // 天空：分带 + 抖动
  const n=12,bh=(hy+1)/n
  for(let j=0;j<n;j++){
    const y0=round(j*bh),y1=round((j+1)*bh)
    x.fillStyle=rgb(mix(top,bot,j/(n-1)));x.fillRect(0,y0,W,y1-y0)
    if(j<n-1){x.fillStyle=rgb(mix(top,bot,(j+1)/(n-1)));for(let k=j%2;k<W;k+=2)x.fillRect(k,y1-1,1,1)}
  }
  if(night>0)for(const[a,b,ph]of stars){x.globalAlpha=night*(.5+.5*sin(t*2+ph));x.fillStyle=C.w;x.fillRect(a|0,b|0,1,1)}
  x.globalAlpha=1
  const su=((c>.9?c-1:c)+.1)/.72,mu=(c-.64)/.28
  let reflect=-1,refCol
  if(su>=0&&su<=1){
    const sx=W*(.12+.76*su),sy=hy+6-sin(su*PI)*(hy-14),low=sin(su*PI)<.28
    x.globalAlpha=.35;disc(x,sx,sy,10,low?'#ff9d5c':'#fff7c9');x.globalAlpha=1
    disc(x,sx,sy,7,low?'#ffb35c':'#ffe97a')
    reflect=sx;refCol=low?'#ffb35c':'#fff3b0'
  }else if(mu>=0&&mu<=1){
    const mx=W*(.12+.76*mu),my=hy+6-sin(mu*PI)*(hy-14)
    disc(x,mx,my,6,'#eef2ff');x.fillStyle='#c6cfe6';x.fillRect(round(mx)-2,round(my)-2,2,2);x.fillRect(round(mx)+2,round(my)+1,2,1);x.fillRect(round(mx)-1,round(my)+3,1,1)
    reflect=mx;refCol='#c6cfe6'
  }

  g.clearRect(0,0,W,H)
  // 云
  ;[[0,.12,1.3],[1,.34,.8],[0,.56,.6],[1,.2,1.8],[1,.72,.45]].forEach(([k,yf,sp],j)=>d(CLOUDS[k],(j*83+t*sp)%(W+40)-30,hy*yf))
  d(far,0,0)
  // 海面
  for(const[a,b,ph]of glints){
    const v=sin(t*1.6+ph*3),depth=(b-hy)/(H-hy)
    if(v>.15)p(depth<.25?'#a8ecf2':'#7fd4ea',a+sin(t*.5+ph)*4,b,1+round(depth*5),1)
  }
  if(reflect>=0&&reflect<W)for(let j=hy+1;j<H;j+=2)if(sin(j*1.7+t*3)>-.3)p(refCol,reflect-2-3*sin(j+t*2),j,3+round((j-hy)/(H-hy)*9),1)
  d(SAIL,(W*.8-t*1.1)%(W+20)+(t*1.1>W*.8?W+20:0)-10,hy-4+round(sin(t)*.6))
  // 鲸鱼：出水、喷气、摆尾
  {
    const T=14,m=floor(t/T),q=t/T%1,wl=hy+14,wx=m*97.3%1*(W-50)+6-q*14
    g.save();g.beginPath();g.rect(0,0,W,wl);g.clip()
    if(q<.42)d(WHALE,wx,wl-sin(q/.42*PI)*6)
    if(q>.5&&q<.78)d(TAIL,wx+20,wl-sin((q-.5)/.28*PI)*9)
    g.restore()
    if(q<.42)for(let k=0;k<17;k+=2)if(sin(k+t*5)>-.4)p(C.w,wx+7+k*1.5,wl,2,1)
    if(q>.5&&q<.78)for(let k=0;k<5;k++)if(sin(k*2+t*6)>-.3)p(C.w,wx+20+k*3,wl,2,1)
    if(q>.1&&q<.3)for(let k=0;k<10;k++){
      const a=(t*1.4+k/10)%1,sp=k%2*2-1
      p(a>.6?'#cfeefa':C.w,wx+11+sp*a*a*(k%5+2),wl-6-a*15+a*a*5)
    }
  }
  d(isle,0,0)
  // 岸边浪花
  for(let a=0;a<2*PI;a+=.014){
    const b=1.5+sin(t*1.2)*.8
    if(sin(a*34+t*2)>-.25)p(C.w,cx+cos(a)*(rx*R(a)+b+.5),iy+sin(a)*(ry*R(a)+b*.6))
  }
  // 岛上物件
  palm(cx-round(rx*.34),iy-8,28,-1,t)
  palm(cx-round(rx*.08),iy-13,24,1,t+2)
  const hx=cx+round(rx*.14),hty=iy-15
  d(HUT,hx,hty)
  for(let k=0;k<4;k++){const a=(t*.35+k/4)%1;p(C.g,hx+13+sin(a*7+k)*2,hty-2-a*14)}
  palm(cx-round(rx*.62),iy-1,24,-1.4,t+1)
  palm(cx+round(rx*.66),iy,25,1.4,t+3)
  d(UMBRELLA,cx+round(rx*.2),iy-2)
  p(C.y,cx+round(rx*.34),iy+4,9,3);p(C.w,cx+round(rx*.34),iy+5,9,1)
  d(CRAB,cx-round(rx*.4)+sin(t*.45)*9,iy+7)
  const ball=abs(sin(t*2.6))*7,bx=cx-round(rx*.12)
  p('#d9b67a',bx,iy+9,4,1);d(BALL,bx,iy+5-ball)
  // 飞鸟
  const fx=(t*12)%(W+90)-50,fy=hy*.42+sin(t*.3)*6
  for(let k=0;k<5;k++)d(BIRD[floor(t*4+k*.7)%2],fx+k*8,fy+abs(k-2)*4)
  for(let k=0;k<3;k++){const a=t*.5+k*2.1;d(GULL[floor(t*3+k)%2],cx+cos(a)*rx*.65,iy-46+sin(a)*7+k*3,cos(a)>0)}
  // 飞机
  const px=W+20-(t*16)%(W+60),py=hy*.2+sin(t*.8)*2
  d(PLANE,px,py)
  p(t*40%2<1?C.k:C.g,px+1,py+3,1,6)
  // 游艇
  const L=W+80,y=(t*9)%(2*L),dir=y<L?1:-1,yx=(dir>0?y:2*L-y)-40,base=iy+ry+(H-iy-ry)*.5
  const yb=round(base+sin(t*1.5))
  d(YACHT,yx,yb-10,dir<0)
  for(let k=0;k<16;k++)if(sin(k*1.3+t*7)>-.2)p(C.w,yx+(dir>0?-k*2:24+k*2),yb+k%3-1,2,1)
  p(C.w,yx+(dir>0?24:-2),yb-2+round(sin(t*5)),2,1)
  // 海豚
  {
    const wl=H-10,sp=14,T=4
    for(let k=0;k<3;k++){
      const q=(t/T+k*.27)%1,hx=(t*sp)%(W+90)-45+k*17,b=.5
      if(q<b){
        const v=q/b,h=9
        const ang=-Math.atan2(cos(v*PI)*h*PI,sp*T*b)
        g.save();g.beginPath();g.rect(0,0,W,wl);g.clip()
        g.translate(round(hx),round(wl-sin(v*PI)*h));g.rotate(ang);g.drawImage(DOLPHIN,-8,-3);g.restore()
      }
      for(const[s0,sx]of[[0,hx-3],[b,hx+3]]){
        const a=(q-s0+1)%1/.12
        if(a<1)for(let m=-2;m<=2;m++)p(C.w,sx+m*(1+a*3),wl-abs(m%2?5:3)*sin(a*PI))
      }
    }
  }
  // 夜色罩只盖场景，不压星空
  if(tint[3]>0){g.globalCompositeOperation='source-atop';g.fillStyle=`rgba(${tint.slice(0,3).map(round)},${tint[3]})`;g.fillRect(0,0,W,H);g.globalCompositeOperation='source-over'}
  x.drawImage(scene,0,0)
  if(night>0){x.globalAlpha=min(1,night*1.5);x.fillStyle=C.y;x.fillRect(hx+11,hty+5,3,2);x.globalAlpha=1}
}

layout()
if(matchMedia('(prefers-reduced-motion: reduce)').matches){
  frame(10);addEventListener('resize',()=>{layout();frame(10)})
}else{
  let last=-99
  const loop=now=>{requestAnimationFrame(loop);if(now-last<50)return;last=now;frame(now/1000+10)}
  requestAnimationFrame(loop);addEventListener('resize',()=>{layout();last=-99})
}
</script>
</body>
</html>
REALITY_FALLBACK_HTML
    sed -i "s/__REALITY_DOMAIN__/${DOMAIN}/g" "${WEB_ROOT}/index.html"
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

    local challenge_probe challenge_url challenge_response
    challenge_probe="xray-acme-probe-$(openssl rand -hex 8)"
    challenge_url="http://${DOMAIN}/.well-known/acme-challenge/${challenge_probe}"
    printf '%s\n' "$challenge_probe" > "${WEB_ROOT}/.well-known/acme-challenge/${challenge_probe}"
    chmod 0644 "${WEB_ROOT}/.well-known/acme-challenge/${challenge_probe}"
    challenge_response="$(curl --noproxy '*' -fsS \
        --resolve "${DOMAIN}:80:127.0.0.1" "$challenge_url")"
    rm -f "${WEB_ROOT}/.well-known/acme-challenge/${challenge_probe}"
    [[ $challenge_response == "$challenge_probe" ]] || \
        die "Nginx ACME challenge 路径自检失败：${challenge_url}"
    info "Nginx ACME challenge 路径自检通过"

    if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
        curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
    fi

    "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt
    # The script's default umask is 077 for protecting generated credentials.
    # ACME HTTP-01 files must be readable by the unprivileged Nginx worker.
    (
        umask 022
        "${ACME_HOME}/acme.sh" --issue \
            --domain "$DOMAIN" \
            --webroot "$WEB_ROOT" \
            --server letsencrypt
    )

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

configure_web_firewall() {
    step "配置 Web 防火墙"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp comment 'ACME HTTP challenge'
        ufw allow 443/tcp comment 'Nginx HTTPS'
        info "已写入 UFW 规则（不会自动启用原本 inactive 的 UFW）"
        ufw status verbose
    else
        warn "未安装 UFW；请在云厂商防火墙中开放 TCP 80 和 443"
    fi
}

configure_xray_firewall() {
    step "配置 Xray 防火墙"
    if command -v ufw >/dev/null 2>&1; then
        local port
        for port in "${PORTS[@]}"; do
            ufw allow "${port}/tcp" comment 'Xray VLESS REALITY'
        done
        info "已写入 10 个 Xray TCP 端口的 UFW 规则"
        ufw status verbose
    else
        warn "未安装 UFW；请在云厂商防火墙中开放这 10 个 TCP 端口：${PORTS[*]}"
    fi
}

show_web_listeners() {
    step "检查 Web 监听端口"
    ss -lntp | grep -E ':(80|443)\b' || die "未检测到 TCP 80/443 监听端口"
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
    configure_web_firewall
    issue_certificate
    write_final_nginx_config
    show_web_listeners
    write_xray_configs
    configure_xray_firewall
    start_instances
    write_client_files
    verify_installation
    show_result
}

main "$@"
