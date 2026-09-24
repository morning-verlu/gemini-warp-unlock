#!/usr/bin/env bash
###############################################################################
# xray-warp-setup.sh
#
# 一键配置： Cloudflare WARP(warp-cli, 本地 SOCKS5)
#              + Xray(VLESS + Reality + Vision) 链式出站
#              + 生成 Clash Verge / mihomo 订阅(YAML)
#              + nginx 通过 HTTP 对外提供订阅链接
#
# 适用系统： Debian 11/12/13、Ubuntu 20.04+ （以 root 运行）
# 前置条件： 已有可用的 Xray（VLESS + Reality 入站）；或加 --init 让脚本
#            在全新机器上生成一份 Xray 入站配置（仍需先自行安装好 xray 二进制）
#
# 用法：
#   ./xray-warp-setup.sh                 # 执行全部步骤
#   ./xray-warp-setup.sh --init          # 全新机器：生成 Xray Reality 入站 + 全部步骤
#   ./xray-warp-setup.sh warp            # 只安装/配置 warp-cli
#   ./xray-warp-setup.sh xray            # 只改写 xray 配置（WARP 出站 + 分流）
#   ./xray-warp-setup.sh sub             # 只生成 Clash 订阅文件
#   ./xray-warp-setup.sh nginx           # 只配置 nginx 订阅分发
#   ./xray-warp-setup.sh verify          # 只做最终验证
#
# 可覆盖的环境变量（都有默认值）：
#   NODE_DOMAIN     服务器域名（留空则自动取公网 IPv4 写进订阅）
#   WARP_PORT       warp-cli SOCKS5 监听端口            默认 40000
#   XRAY_CONF       xray 配置文件路径                   默认 /usr/local/etc/xray/config.json
#   XRAY_BIN        xray 二进制路径                     默认自动探测
#   SUB_DIR         订阅文件存放目录                   默认 /var/www/html/my-sub
#   SUB_PORT        nginx 订阅端口                      默认 8888
#   SUB_PATH        nginx 订阅 URL 路径                 默认 /my-sub
#   SUB_FILE        订阅文件名（默认随机，务必保持随机）
#   PROXY_NAME      订阅里显示的节点名称               默认 US-Reality-WARP
#   FORCE_IPV4      xray direct 出站是否强制 IPv4      默认 1（建议开启）
#   REALITY_PUB     手动指定 Reality 公钥（默认由私钥推导）
###############################################################################
set -euo pipefail

# ----------------------------- 默认变量 -----------------------------
WARP_PORT="${WARP_PORT:-40000}"
XRAY_CONF="${XRAY_CONF:-/usr/local/etc/xray/config.json}"
XRAY_BIN="${XRAY_BIN:-$(command -v xray || echo /usr/local/bin/xray)}"
SUB_DIR="${SUB_DIR:-/var/www/html/my-sub}"
SUB_PORT="${SUB_PORT:-8888}"
SUB_PATH="${SUB_PATH:-/my-sub}"
SUB_FILE="${SUB_FILE:-clash-$(openssl rand -hex 8).yaml}"
PROXY_NAME="${PROXY_NAME:-US-Reality-WARP}"
FORCE_IPV4="${FORCE_IPV4:-1}"
REALITY_PUB="${REALITY_PUB:-}"
INIT_FRESH_XRAY=0
STATE_FILE="$(mktemp -t xraywarp.XXXXXX)"
trap 'rm -f "$STATE_FILE"' EXIT

c_info()  { printf '\033[36m[INFO]\033[0m  %s\n' "$*" >&2; }
c_ok()    { printf '\033[32m[ OK ]\033[0m  %s\n' "$*" >&2; }
c_warn()  { printf '\033[33m[WARN]\033[0m  %s\n' "$*" >&2; }
c_err()   { printf '\033[31m[ERR ]\033[0m  %s\n' "$*" >&2; }

need_root() {
  [ "$(id -u)" -eq 0 ] || { c_err "请以 root 运行"; exit 1; }
}

###############################################################################
# 1. 安装并配置 warp-cli（proxy 模式）
###############################################################################
install_warp() {
  need_root
  if command -v warp-cli >/dev/null 2>&1; then
    c_ok "cloudflare-warp 已安装：$(warp-cli --version 2>/dev/null)"
    return 0
  fi
  c_info "安装 cloudflare-warp（Cloudflare 官方 apt 源）..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y gnupg curl ca-certificates lsb-release

  local codename
  codename="$(lsb_release -cs)"
  c_info "系统代号：$codename"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF
  apt-get update -y
  apt-get install -y cloudflare-warp
  c_ok "warp-cli 安装完成：$(warp-cli --version)"
}

configure_warp() {
  need_root
  command -v warp-cli >/dev/null 2>&1 || install_warp

  c_info "注册 WARP（已注册会报错，可忽略）..."
  warp-cli --accept-tos registration new >/dev/null 2>&1 || true

  c_info "设置 proxy 模式，SOCKS5 端口 $WARP_PORT ..."
  warp-cli --accept-tos mode proxy
  warp-cli --accept-tos proxy port "$WARP_PORT"
  warp-cli --accept-tos connect

  c_info "等待 WARP 连接..."
  local i
  for i in $(seq 1 15); do
    if warp-cli --accept-tos status 2>/dev/null | grep -qi connected; then break; fi
    sleep 2
  done
  warp-cli --accept-tos status || true

  c_info "验证 WARP 出口（期望 warp=on）..."
  local trace
  trace="$(curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:${WARP_PORT}" \
      https://www.cloudflare.com/cdn-cgi/trace || true)"
  echo "$trace" | grep -E '^(ip|loc|colo|warp)=' || { c_err "WARP 出口验证失败，请检查 warp-cli status"; exit 1; }
  echo "$trace" | grep -q '^warp=on' && c_ok "WARP 工作正常" || { c_err "warp != on"; exit 1; }
}

###############################################################################
# 2. 改写 Xray 配置
#    - warp 出站 = socks -> 127.0.0.1:WARP_PORT
#    - direct 出站可强制 IPv4
#    - Gemini / AI / 流媒体域名 -> warp；BT 封禁；其余 -> direct
#    幂等：重复执行只会覆盖本脚本管理的规则，不重复追加
###############################################################################
patch_xray() {
  need_root
  command -v python3 >/dev/null 2>&1 || { c_err "需要 python3"; exit 1; }
  [ -x "$XRAY_BIN" ] || { c_err "找不到 xray 二进制：$XRAY_BIN（用 XRAY_BIN=... 指定）"; exit 1; }

  # --init：配置不存在时，现场生成全新 Reality 入站所需密钥
  if [ "$INIT_FRESH_XRAY" = "1" ] && [ ! -f "$XRAY_CONF" ]; then
    c_info "全新初始化：生成 UUID / Reality 密钥对 / shortId ..."
    export XRAY_UUID="$("$XRAY_BIN" uuid)"
    local _x25519
    _x25519="$("$XRAY_BIN" x25519)"
    export XRAY_PRIV="$(echo "$_x25519" | sed -n 's/^PrivateKey: //p')"
    export XRAY_SHORTID="$(openssl rand -hex 8)"
    c_ok "UUID=$XRAY_UUID"
    c_ok "Reality 公钥（客户端用）：$(echo "$_x25519" | sed -n 's/^Password (PublicKey): //p')"
  fi

  cp "$XRAY_CONF" "${XRAY_CONF}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  c_info "已备份原配置到 ${XRAY_CONF}.bak.*"

  c_info "改写 xray 配置：$XRAY_CONF"
  XRAY_CONF="$XRAY_CONF" WARP_PORT="$WARP_PORT" FORCE_IPV4="$FORCE_IPV4" \
  INIT_FRESH_XRAY="$INIT_FRESH_XRAY" \
  python3 - <<'PY'
import json, os, uuid, secrets, base64, shlex, sys

conf      = os.environ['XRAY_CONF']
warp_port = int(os.environ['WARP_PORT'])
force_v4  = os.environ.get('FORCE_IPV4') == '1'
fresh     = os.environ.get('INIT_FRESH_XRAY') == '1'

GEMINI_DOMAINS = [
    "domain:gemini.google.com",
    "domain:generativelanguage.googleapis.com",
    "domain:aistudio.google.com",
    "domain:makersuite.google.com",
    "domain:bard.google.com",
    "domain:proactivebackend-pa.googleapis.com",
    "domain:alkalimakersuite-pa.clients6.google.com",
    "domain:cloudaicompanion.googleapis.com",
]
AI_GEO_DOMAINS = [
    "geosite:openai", "geosite:anthropic",
    "geosite:netflix", "geosite:spotify", "geosite:disney",
    "domain:ipinfo.io", "domain:whoer.net",
]

if os.path.exists(conf):
    c = json.load(open(conf, encoding='utf-8'))
else:
    if not fresh:
        sys.exit(f"找不到 {conf}；全新机器请加 --init")
    priv = os.environ.get('XRAY_PRIV') or base64.b64encode(secrets.token_bytes(32)).decode().rstrip('=')
    c = {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "tag": "vless-reality", "listen": "0.0.0.0", "port": 443, "protocol": "vless",
            "settings": {"clients": [{
                "id": os.environ.get('XRAY_UUID', str(uuid.uuid4())),
                "flow": "xtls-rprx-vision"}], "decryption": "none"},
            "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {
                "show": False, "dest": "www.apple.com:443",
                "serverNames": ["www.apple.com"],
                "privateKey": priv,
                "shortIds": [os.environ.get('XRAY_SHORTID', secrets.token_hex(4))]}}
        }],
        "outbounds": [],
        "routing": {"domainStrategy": "IPIfNonMatch", "rules": []},
    }

# 取第一个 vless + reality 入站参数（供生成订阅）
ib = next((i for i in c.get('inbounds', []) if i.get('protocol') == 'vless'), None)
if ib is None:
    sys.exit("xray 配置里没有找到 vless 入站，脚本目前只支持 VLESS + Reality")
rs = ib['streamSettings']['realitySettings']
client = ib['settings']['clients'][0]
facts = {
    'UUID': client['id'],
    'FLOW': client.get('flow', ''),
    'SNI':  rs['serverNames'][0],
    'SID':  rs['shortIds'][0],
    'PRIV': rs['privateKey'],
    'PORT': str(ib.get('port', 443)),
}

# ---- 出站 ----
obs = c.setdefault('outbounds', [])
def upsert_outbound(tag, ob):
    for i, o in enumerate(obs):
        if o.get('tag') == tag:
            obs[i] = ob
            return
    obs.append(ob)

direct_ob = {"protocol": "freedom", "tag": "direct"}
if force_v4:
    direct_ob["settings"] = {"domainStrategy": "UseIPv4"}
upsert_outbound('direct', direct_ob)
if not any(o.get('tag') == 'block' for o in obs):
    obs.append({"protocol": "blackhole", "tag": "block"})
upsert_outbound('warp', {"tag": "warp", "protocol": "socks",
                         "settings": {"servers": [{"address": "127.0.0.1", "port": warp_port}]}})

# ---- 路由规则（先剔除本脚本历史写入的托管规则，再重新插入，保证幂等）----
rout = c.setdefault('routing', {})
rules = rout.setdefault('rules', [])

def managed(rule):
    if rule.get('protocol') == ['bittorrent']:
        return True
    dom = rule.get('domain', [])
    if rule.get('outboundTag') == 'warp' and ('domain:gemini.google.com' in dom or 'geosite:openai' in dom):
        return True
    if rule.get('outboundTag') == 'direct' and rule.get('network') == 'udp,tcp':
        return True
    return False

rules = [x for x in rules if not managed(x)]
managed_rules = [
    {"type": "field", "outboundTag": "block", "protocol": ["bittorrent"]},
    {"type": "field", "outboundTag": "warp", "domain": GEMINI_DOMAINS},
    {"type": "field", "outboundTag": "warp", "domain": AI_GEO_DOMAINS},
]
# 用户自定义规则保留在中间；最后兜底直连
rules = managed_rules + rules + [{"type": "field", "outboundTag": "direct", "network": "udp,tcp"}]
rout['rules'] = rules

os.makedirs(os.path.dirname(conf), exist_ok=True)
json.dump(c, open(conf, 'w', encoding='utf-8'), indent=2, ensure_ascii=False)

for k, v in facts.items():
    print(f"export NODE_{k}={shlex.quote(str(v))}")
PY
}

# 收集入站参数并推导 Reality 公钥
collect_facts() {
  eval "$(patch_xray | tee "$STATE_FILE")"
  if [ -z "$REALITY_PUB" ]; then
    REALITY_PUB="$("$XRAY_BIN" x25519 -i "$NODE_PRIV" | sed -n 's/^Password (PublicKey): //p')"
  fi
  export REALITY_PUB
  c_ok "Reality 公钥：$REALITY_PUB"
}

restart_xray() {
  c_info "校验 xray 配置 ..."
  "$XRAY_BIN" -test -config "$XRAY_CONF"
  c_info "重启 xray ..."
  systemctl restart xray
  sleep 2
  systemctl is-active --quiet xray && c_ok "xray 运行中" || { c_err "xray 启动失败：journalctl -u xray"; exit 1; }
}

stage_xray() {
  collect_facts
  restart_xray
}

###############################################################################
# 3. 生成 Clash / mihomo 订阅
###############################################################################
write_subscription() {
  [ -f "$STATE_FILE" ] && source "$STATE_FILE"
  : "${NODE_UUID:?xray 入站信息缺失，请先执行 xray 阶段}"
  [ -n "$REALITY_PUB" ] || REALITY_PUB="$("$XRAY_BIN" x25519 -i "$NODE_PRIV" | sed -n 's/^Password (PublicKey): //p')"
  local server
  server="${NODE_DOMAIN:-${NODE_SERVER:-$(curl -4 -fsS --max-time 10 ifconfig.me)}}"

  c_info "服务器地址：$server  端口：${NODE_PORT}  订阅文件：$SUB_FILE"
  mkdir -p "$SUB_DIR"

  SUB_DIR="$SUB_DIR" SUB_FILE="$SUB_FILE" SERVER="$server" \
  NODE_PORT="$NODE_PORT" NODE_UUID="$NODE_UUID" NODE_FLOW="$NODE_FLOW" \
  NODE_SNI="$NODE_SNI" NODE_SID="$NODE_SID" REALITY_PUB="$REALITY_PUB" \
  PROXY_NAME="$PROXY_NAME" \
  python3 - <<'PY'
import os
sub_dir  = os.environ['SUB_DIR']
sub_file = os.environ['SUB_FILE']

tpl = r'''# Clash Verge / mihomo subscription (generated by xray-warp-setup.sh)
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
unified-delay: true
tcp-concurrent: true
external-controller: 127.0.0.1:9090
ipv6: true

dns:
  enable: true
  ipv6: true
  default-nameserver: [223.5.5.5, 119.29.29.29]
  nameserver:
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
  fallback:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query
  fallback-filter:
    geoip: true
    geoip-code: CN

proxies:
  - name: "@@PROXY_NAME@@"
    type: vless
    server: @@SERVER@@
    port: @@PORT@@
    uuid: @@UUID@@
    network: tcp
    tls: true
    udp: true
    flow: @@FLOW@@
    servername: @@SNI@@
    client-fingerprint: chrome
    reality-opts:
      public-key: @@PUB@@
      short-id: @@SID@@

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies: ["@@PROXY_NAME@@", "DIRECT"]

  - name: "🤖 AI 服务"
    type: select
    proxies: ["@@PROXY_NAME@@", "🚀 节点选择", "DIRECT"]

  - name: "🎬 国外流媒体"
    type: select
    proxies: ["@@PROXY_NAME@@", "🚀 节点选择", "DIRECT"]

  - name: "🐟 漏网之鱼"
    type: select
    proxies: ["@@PROXY_NAME@@", "🚀 节点选择", "DIRECT"]

rules:
  # ---------- 局域网 / 私有地址 ----------
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-KEYWORD,-lan,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve

  # ---------- 广告拦截 ----------
  - GEOSITE,category-ads-all,REJECT

  # ---------- 禁用 QUIC：强制浏览器回退 TCP(HTTP/2)，地区判定更稳定 ----------
  - AND,((NETWORK,udp),(DST-PORT,443)),REJECT

  # ---------- AI 服务（服务端对这些域名自动走 WARP）----------
  - GEOSITE,openai,🤖 AI 服务
  - GEOSITE,anthropic,🤖 AI 服务
  - GEOSITE,google-gemini,🤖 AI 服务
  - DOMAIN-SUFFIX,openai.com,🤖 AI 服务
  - DOMAIN-SUFFIX,chatgpt.com,🤖 AI 服务
  - DOMAIN-SUFFIX,oaiusercontent.com,🤖 AI 服务
  - DOMAIN-SUFFIX,oaistatic.com,🤖 AI 服务
  - DOMAIN-SUFFIX,anthropic.com,🤖 AI 服务
  - DOMAIN-SUFFIX,claude.ai,🤖 AI 服务
  - DOMAIN-SUFFIX,gemini.google.com,🤖 AI 服务
  - DOMAIN-SUFFIX,generativelanguage.googleapis.com,🤖 AI 服务
  - DOMAIN-SUFFIX,aistudio.google.com,🤖 AI 服务
  - DOMAIN-SUFFIX,makersuite.google.com,🤖 AI 服务
  - DOMAIN-SUFFIX,bard.google.com,🤖 AI 服务

  # ---------- 国外流媒体（服务端自动走 WARP）----------
  - GEOSITE,netflix,🎬 国外流媒体
  - GEOSITE,spotify,🎬 国外流媒体
  - GEOSITE,disney,🎬 国外流媒体
  - GEOSITE,youtube,🎬 国外流媒体
  - GEOSITE,hbo,🎬 国外流媒体
  - GEOSITE,hulu,🎬 国外流媒体
  - GEOSITE,primevideo,🎬 国外流媒体
  - DOMAIN-SUFFIX,ipinfo.io,🎬 国外流媒体
  - DOMAIN-SUFFIX,whoer.net,🎬 国外流媒体

  # ---------- 国内直连（注意：geosite 没有 microsoft-cn 这个分类，勿写）----------
  - GEOSITE,apple-cn,DIRECT
  - DOMAIN-SUFFIX,microsoft.cn,DIRECT
  - DOMAIN-SUFFIX,office365.cn,DIRECT
  - DOMAIN-SUFFIX,visualstudio.cn,DIRECT
  - DOMAIN-SUFFIX,azure.cn,DIRECT
  - GEOSITE,category-games-cn,DIRECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT

  # ---------- 其余全部走节点 ----------
  - MATCH,🐟 漏网之鱼
'''

repl = {
    '@@PROXY_NAME@@': os.environ['PROXY_NAME'],
    '@@SERVER@@':     os.environ['SERVER'],
    '@@PORT@@':       os.environ['NODE_PORT'],
    '@@UUID@@':       os.environ['NODE_UUID'],
    '@@FLOW@@':       os.environ.get('NODE_FLOW') or 'xtls-rprx-vision',
    '@@SNI@@':        os.environ['NODE_SNI'],
    '@@PUB@@':        os.environ['REALITY_PUB'],
    '@@SID@@':        os.environ['NODE_SID'],
}
for k, v in repl.items():
    tpl = tpl.replace(k, str(v))

path = os.path.join(sub_dir, sub_file)
with open(path, 'w', encoding='utf-8') as f:
    f.write(tpl)
print(path)
PY

  chmod 644 "${SUB_DIR}/${SUB_FILE}"
  command -v python3 >/dev/null && python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1])); print('YAML OK')" \
    "${SUB_DIR}/${SUB_FILE}" 2>/dev/null || c_warn "PyYAML 未安装，跳过 YAML 语法自检（不影响使用）"
  c_ok "订阅已生成：${SUB_DIR}/${SUB_FILE}"
}

###############################################################################
# 4. nginx 分发订阅（HTTP）
###############################################################################
setup_nginx() {
  need_root
  if ! command -v nginx >/dev/null 2>&1; then
    c_info "安装 nginx ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y nginx
  fi
  mkdir -p /var/www/html
  cat > /etc/nginx/conf.d/xray-sub.conf <<EOF
server {
    listen ${SUB_PORT};
    server_name _;

    location ${SUB_PATH}/ {
        root /var/www/html;
        default_type text/yaml;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }
}
EOF
  nginx -t
  systemctl enable --now nginx >/dev/null 2>&1 || true
  systemctl reload nginx
  c_ok "nginx 已在 ${SUB_PORT} 端口分发订阅"
}

###############################################################################
# 5. 验证
###############################################################################
verify() {
  c_info "===== 1) WARP 状态 ====="
  warp-cli --accept-tos status || true
  curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:${WARP_PORT}" \
    https://www.cloudflare.com/cdn-cgi/trace | grep -E '^(ip|loc|warp)=' || true

  c_info "===== 2) xray 状态 ====="
  "$XRAY_BIN" -test -config "$XRAY_CONF" >/dev/null && echo "xray config OK"
  systemctl is-active xray

  c_info "===== 3) Gemini 是否被路由到 WARP（HTTP 200 + warp 出口）====="
  curl -s -o /dev/null -w 'gemini.google.com/app -> HTTP %{http_code}\n' \
    --max-time 20 --socks5-hostname "127.0.0.1:${WARP_PORT}" https://gemini.google.com/app || true

  c_info "===== 4) 订阅本机拉取 ====="
  curl -s -o /dev/null -w 'subscription -> HTTP %{http_code} (%{size_download} bytes)\n' \
    "http://127.0.0.1:${SUB_PORT}${SUB_PATH}/${SUB_FILE}"

  local server
  server="${NODE_DOMAIN:-${NODE_SERVER:-$(curl -4 -fsS --max-time 10 ifconfig.me 2>/dev/null)}}"
  echo
  c_ok "订阅链接（在 Clash Verge X 中导入）："
  echo "    http://${server}:${SUB_PORT}${SUB_PATH}/${SUB_FILE}"
}

usage() { sed -n '2,40p' "$0"; }

###############################################################################
# 参数解析 & 主流程
###############################################################################
STAGE="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --init) INIT_FRESH_XRAY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    warp|xray|sub|nginx|verify|all) STAGE="$1"; shift ;;
    *) c_err "未知参数：$1"; usage; exit 1 ;;
  esac
done

case "$STAGE" in
  warp)   need_root; install_warp; configure_warp ;;
  xray)   stage_xray ;;
  sub)
    # sub 单独执行时直接从现有配置提取参数（不重启 xray）
    [ -f "$STATE_FILE" ] || true
    eval "$(XRAY_CONF="$XRAY_CONF" WARP_PORT="$WARP_PORT" FORCE_IPV4="$FORCE_IPV4" \
        INIT_FRESH_XRAY=0 python3 - <<'PY'
import json, os, shlex
c = json.load(open(os.environ['XRAY_CONF'], encoding='utf-8'))
ib = next(i for i in c['inbounds'] if i.get('protocol') == 'vless')
rs = ib['streamSettings']['realitySettings']; cl = ib['settings']['clients'][0]
for k, v in {'UUID': cl['id'], 'FLOW': cl.get('flow',''), 'SNI': rs['serverNames'][0],
             'SID': rs['shortIds'][0], 'PRIV': rs['privateKey'], 'PORT': str(ib.get('port',443))}.items():
    print(f"export NODE_{k}={shlex.quote(str(v))}")
PY
)"
    write_subscription ;;
  nginx)  setup_nginx ;;
  verify) verify ;;
  all)
    need_root
    install_warp
    configure_warp
    stage_xray
    write_subscription
    setup_nginx
    verify
    ;;
esac
