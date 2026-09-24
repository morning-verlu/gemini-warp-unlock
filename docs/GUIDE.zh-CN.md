# Xray + Cloudflare WARP + Clash 通用部署文档

> 目标：在一台 Linux VPS 上，把 **Xray（VLESS + Reality）** 与 **Cloudflare WARP 官方客户端（warp-cli）** 组合使用，
> 给本地的 **Clash Verge X（mihomo 内核）** 提供一个可导入的 **HTTP 订阅链接**，并配好国内外分流规则。
> 重点解决：OpenAI / Gemini / Claude / Netflix 等服务因 **VPS 机房 IP 信誉差 / IPv6 地理定位不准 / 账号地区** 导致的不可用问题。
>
> 配套脚本：`xray-warp-setup.sh`（本文档所有操作的自动化版本，幂等，可重复执行）

---

## 目录

1. [架构与原理](#1-架构与原理)
2. [前置条件](#2-前置条件)
3. [快速开始（一键脚本）](#3-快速开始一键脚本)
4. [手动部署详解](#4-手动部署详解)
   - [4.1 安装并配置 warp-cli](#41-安装并配置-warp-cli)
   - [4.2 改造 Xray 配置（核心）](#42-改造-xray-配置核心)
   - [4.3 全新机器从零安装 Xray（可选）](#43-全新机器从零安装-xray可选)
   - [4.4 重启 Xray 与链路验证](#44-重启-xray-与链路验证)
   - [4.5 生成 Clash 订阅文件](#45-生成-clash-订阅文件)
   - [4.6 用 nginx 对外提供 HTTP 订阅链接](#46-用-nginx-对外提供-http-订阅链接)
   - [4.7 客户端导入](#47-客户端导入)
5. [分流规则说明（服务端 vs 客户端）](#5-分流规则说明服务端-vs-客户端)
6. [Gemini / AI 地区限制专题](#6-gemini--ai-地区限制专题)
7. [验证清单](#7-验证清单)
8. [常见问题与排错](#8-常见问题与排错)
9. [备份、回滚与日常维护](#9-备份回滚与日常维护)
10. [安全建议](#10-安全建议)
11. [附录](#11-附录)

---

## 1. 架构与原理

### 1.1 最终链路

```
┌─────────────────────┐        VLESS + Reality + Vision (TCP 443)
│  本地设备            │ ───────────────────────────────────────────────┐
│  Clash Verge X      │                                                 │
│  (mihomo 内核)       │                                                 ▼
│                     │                              ┌────────────────────────────────┐
│  规则分流(客户端)     │                              │  VPS: Xray 入站 :443             │
│  - 国内 → 直连        │                              │                                │
│  - AI/流媒体 → 节点   │                              │  路由(服务端第二次分流)：         │
│  - 其余 → 节点        │                              │   ├─ BT → block                 │
└─────────────────────┘                              │   ├─ AI/Gemini/流媒体 → warp ──┐│
                                                      │   └─ 其他 → direct(强制 IPv4)  ││
                                                      └────────────────────────────────┘│
                                                                                         ▼
                                                                              ┌──────────────────────┐
                                                                              │ warp-cli (proxy 模式) │
                                                                              │ SOCKS5 127.0.0.1:40000│
                                                                              └──────────┬───────────┘
                                                                                         ▼
                                                                              Cloudflare WARP 出口
                                                                              (干净的美国 IP)
```

一条连接经过 **两层分流**：

1. **客户端（Clash）**：决定这个域名要不要走代理节点（国内直连、广告拦截、其余走节点）。
2. **服务端（Xray）**：代理流量到达 VPS 后，再决定目标网站从哪个出口出去——
   - 敏感服务（AI、Gemini、流媒体）→ 交给本机 warp-cli，从 Cloudflare WARP 出口出去；
   - 普通网站 → VPS 本机网络直连（速度快），并强制 IPv4。

### 1.2 为什么"只用 Xray"可能不够

| 问题 | 原因 | WARP 如何解决 |
|---|---|---|
| Gemini/OpenAI 提示地区不支持 | 廉价 VPS 的机房 IP 段（尤其 IPv6）在 Google 地理库中定位不准或信誉低 | Cloudflare WARP 是主流大厂商用 IP，地理库 100% 识别为美国 |
| IP 被标记为代理/异常流量 | 小机房 IP 被大量滥用 | WARP IP 池干净，风控更宽松 |
| IPv6 出口行为不可控 | VPS 默认优先 IPv6，很多 VPS 的 v6 归属地混乱 | 让普通流量强制走 IPv4；敏感流量统一走 WARP |
| 不想所有流量都绕 WARP | WARP 会增加延迟、部分网站不友好 | 按域名精确分流，只有名单内的服务走 WARP |

### 1.3 为什么用 warp-cli 而不是 Xray 内置 WireGuard

Xray 本身也支持 wireguard 出站，但用官方 **warp-cli（proxy 模式）** 有几个实际好处：

- **独立维护连接**：断线自动重连、注册和密钥由 Cloudflare 客户端管理，Xray 重启不影响 WARP 隧道；
- **配置简单**：Xray 只需要写一个 socks 出站指向 `127.0.0.1:40000`；
- **方便排错**：可以直接用 `curl --socks5-hostname 127.0.0.1:40000 ...` 单独验证 WARP 是否正常。

---

## 2. 前置条件

- 一台 Linux VPS，**Debian 11/12/13 或 Ubuntu 20.04+**，以 root 操作（本指南以 Debian 13 为例）。
- VPS 已开放（或无防火墙拦截）入站端口：**443**（Xray）、订阅分发端口（本文用 **8888**）。
- 已有可用的 **Xray，入站协议为 VLESS + Reality**（`xtls-rprx-vision` flow）。
  - 没有的话，先按 [4.3 节](#43-全新机器从零安装-xray可选) 装好，或直接用脚本的 `--init`。
- 本地设备已安装 **Clash Verge X**（macOS/Windows）。
- 能 SSH 登录 VPS。

> ⚠️ **SSH 连接注意**：部分 VPS 面板（如 Pterodactyl 类主机）有暴力破解防护，短时间内多次新建 SSH 连接会被临时封禁
> （表现为 TCP 能连上但 SSH 不返回 banner，等 1~3 分钟自动解封）。建议开 SSH ControlMaster 复用连接，或减少连接次数：
>
> ```bash
> cat >> ~/.ssh/config <<'EOF'
> Host *
>     ControlMaster auto
>     ControlPath ~/.ssh/cm-%r@%h:%p
>     ControlPersist 10m
> EOF
> mkdir -p ~/.ssh
> ```

---

## 3. 快速开始（一键脚本）

把 `xray-warp-setup.sh` 上传到 VPS 后执行：

```bash
chmod +x xray-warp-setup.sh

# 情况 A：VPS 上已经有能正常使用的 Xray VLESS-Reality 配置
./xray-warp-setup.sh

# 情况 B：全新机器（已装好 xray 二进制，但还没有配置），脚本会现场生成 UUID 和 Reality 密钥
./xray-warp-setup.sh --init
```

脚本会按顺序完成：**安装 warp-cli → 配置 proxy 模式 → 改写 Xray（WARP 出站+分流+强制 IPv4）→ 生成 Clash 订阅 → 安装/配置 nginx → 验证并打印订阅链接**。

也可以分阶段单独执行（便于排错）：

```bash
./xray-warp-setup.sh warp     # 只装并配置 WARP
./xray-warp-setup.sh xray     # 只改写 Xray 配置并重启
./xray-warp-setup.sh sub      # 只重新生成订阅（改了节点信息后用）
./xray-warp-setup.sh nginx    # 只配置 nginx 订阅分发
./xray-warp-setup.sh verify   # 只做最终验证
```

可用环境变量覆盖默认值（均可选）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `NODE_DOMAIN` | 空（自动取公网 IPv4） | VPS 域名，有域名建议填域名 |
| `WARP_PORT` | `40000` | warp-cli 的 SOCKS5 端口 |
| `XRAY_CONF` | `/usr/local/etc/xray/config.json` | Xray 配置路径 |
| `XRAY_BIN` | 自动探测 | Xray 二进制路径 |
| `SUB_DIR` | `/var/www/html/my-sub` | 订阅文件目录 |
| `SUB_PORT` | `8888` | nginx 订阅端口 |
| `SUB_PATH` | `/my-sub` | 订阅 URL 路径 |
| `SUB_FILE` | `clash-<随机16位>.yaml` | 订阅文件名（保持随机） |
| `PROXY_NAME` | `US-Reality-WARP` | 订阅里的节点名称 |
| `FORCE_IPV4` | `1` | Xray direct 出站是否强制 IPv4 |
| `REALITY_PUB` | 空（由私钥推导） | 手动指定 Reality 公钥 |

示例：

```bash
NODE_DOMAIN=vps.example.com SUB_PORT=9000 PROXY_NAME="日本-WARP" ./xray-warp-setup.sh
```

脚本执行结束后会打印订阅链接，形如：

```
http://<VPS_IP>:8888/my-sub/clash-xxxxxxxxxxxxxxxx.yaml
```

> 脚本是**幂等**的：重复执行不会产生重复规则，每次改写 Xray 前都会自动备份。

---

## 4. 手动部署详解

> 想理解每一步、或脚本不适配你的系统时，按本节手工操作。所有命令以 **Debian/Ubuntu + root** 为准。

### 4.1 安装并配置 warp-cli

**① 添加 Cloudflare 官方 apt 源**

Debian 13 (trixie) 起系统默认没有 `gpg`，先装 `gnupg`：

```bash
apt-get update
apt-get install -y gnupg curl ca-certificates lsb-release

curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
  | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/cloudflare-client.list

apt-get update
apt-get install -y cloudflare-warp
```

> 若你的系统代号在 Cloudflare 源中不存在（比如非常新的版本），把上面 `$(lsb_release -cs)` 换成一个相近的旧代号，如 `trixie` 或 `jammy`。

**② 注册并设置为 proxy 模式**

warp-cli 有三种模式：`warp`（全局接管路由，**不要在服务器上用**）、`proxy`（只开一个本地代理端口，我们要的）、`dot`/`doh`。

```bash
warp-cli --accept-tos registration new     # 注册（已注册会报错，忽略即可）
warp-cli --accept-tos mode proxy           # 切换到 proxy 模式
warp-cli --accept-tos proxy port 40000     # SOCKS5 监听端口
warp-cli --accept-tos connect              # 连接
warp-cli --accept-tos status               # 看到 Status update: Connected
```

`warp-svc` 服务安装后默认开机自启、断线自动重连，无需额外配置。

**③ 验证 WARP 出口**

```bash
curl -s --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

正常应看到类似输出，关键是 **`warp=on`**、`loc=US`：

```
ip=2a09:bac5:636b:183c::26a:13
colo=LAX
loc=US
warp=on
```

### 4.2 改造 Xray 配置（核心）

编辑 `/usr/local/etc/xray/config.json`。要点有三处。

**① 把 warp 出站改为 socks 指向 warp-cli**（替换原来的 wireguard 出站，如果有的话）：

```json
{
  "tag": "warp",
  "protocol": "socks",
  "settings": {
    "servers": [
      { "address": "127.0.0.1", "port": 40000 }
    ]
  }
}
```

**② direct 出站强制 IPv4**（避免普通流量走到归属地混乱的 VPS IPv6）：

```json
{
  "protocol": "freedom",
  "tag": "direct",
  "settings": { "domainStrategy": "UseIPv4" }
}
```

**③ routing.rules 按域名分流**（顺序即优先级，从上往下匹配）：

```json
"routing": {
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    { "type": "field", "outboundTag": "block", "protocol": ["bittorrent"] },

    { "type": "field", "outboundTag": "warp", "domain": [
      "domain:gemini.google.com",
      "domain:generativelanguage.googleapis.com",
      "domain:aistudio.google.com",
      "domain:makersuite.google.com",
      "domain:bard.google.com",
      "domain:proactivebackend-pa.googleapis.com",
      "domain:alkalimakersuite-pa.clients6.google.com",
      "domain:cloudaicompanion.googleapis.com"
    ]},

    { "type": "field", "outboundTag": "warp", "domain": [
      "geosite:openai",
      "geosite:anthropic",
      "geosite:netflix",
      "geosite:spotify",
      "geosite:disney",
      "domain:ipinfo.io",
      "domain:whoer.net"
    ]},

    { "type": "field", "outboundTag": "direct", "network": "udp,tcp" }
  ]
}
```

说明：

- `domain:xxx` 匹配该域及其所有子域；`geosite:xxx` 使用 Xray 的 geosite 数据文件分类（文件位于 `/usr/local/share/xray/geosite.dat`）。
- 最后一条 `direct` 是兜底规则，保证**默认走 VPS 直连**，只有名单走 WARP。
- 想让**全部流量**都走 WARP（不推荐，延迟高），把最后一条的 `direct` 改成 `warp` 即可。
- 修改前先备份：`cp /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.bak.$(date +%F)`。

**完整的 config.json 参考**（inbound 部分请保留你原有的 UUID/密钥，不要照抄）：

```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "你的UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.apple.com:443",
          "serverNames": ["www.apple.com"],
          "privateKey": "你的Reality私钥",
          "shortIds": ["你的shortId"]
        }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "blackhole", "tag": "block" },
    { "tag": "warp", "protocol": "socks",
      "settings": { "servers": [ { "address": "127.0.0.1", "port": 40000 } ] } }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "block", "protocol": ["bittorrent"] },
      { "type": "field", "outboundTag": "warp", "domain": [
        "domain:gemini.google.com",
        "domain:generativelanguage.googleapis.com",
        "domain:aistudio.google.com",
        "domain:makersuite.google.com",
        "domain:bard.google.com",
        "domain:proactivebackend-pa.googleapis.com",
        "domain:alkalimakersuite-pa.clients6.google.com",
        "domain:cloudaicompanion.googleapis.com"
      ]},
      { "type": "field", "outboundTag": "warp", "domain": [
        "geosite:openai", "geosite:anthropic",
        "geosite:netflix", "geosite:spotify", "geosite:disney",
        "domain:ipinfo.io", "domain:whoer.net"
      ]},
      { "type": "field", "outboundTag": "direct", "network": "udp,tcp" }
    ]
  }
}
```

> ⚠️ Xray 会对 `dest`/`serverNames` 用 apple/icloud 给出警告（可能增加被 GFW 关注的概率）。已有节点不用动；全新搭建可换成其他大站，例如 `www.microsoft.com:443`、`dl.google.com:443`、`www.amazon.com:443`（dest 与 serverNames 必须一致，且目标站必须支持 TLS1.3 + h2）。

### 4.3 全新机器从零安装 Xray（可选）

```bash
# 官方安装脚本
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 生成客户端 UUID
xray uuid

# 生成 Reality 密钥对（PrivateKey 放服务端，Password/PublicKey 给客户端）
xray x25519

# 生成 shortId（8 位十六进制）
openssl rand -hex 8
```

把三组值填入 4.2 的完整配置，然后：

```bash
xray -test -config /usr/local/etc/xray/config.json   # 必须看到 Configuration OK
systemctl enable --now xray
systemctl restart xray
```

**由 Reality 私钥推导公钥**（客户端订阅要用，避免手抄）：

```bash
xray x25519 -i "你的Reality私钥"
# 输出中 Password (PublicKey): 后面的串就是公钥
```

### 4.4 重启 Xray 与链路验证

```bash
xray -test -config /usr/local/etc/xray/config.json
systemctl restart xray
systemctl is-active xray
ss -tlnp | grep 443        # 确认 xray 在监听 443
```

**端到端验证分流是否真的生效**（在 VPS 上自建一个临时 Xray 客户端走自己的 443 入站）：

```bash
cat > /tmp/xtc.json <<'EOF'
{
  "log": { "loglevel": "warning" },
  "inbounds": [ { "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": { "udp": true } } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": 443,
      "users": [ { "id": "你的UUID", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": {
        "serverName": "www.apple.com",
        "publicKey": "你的Reality公钥",
        "shortId": "你的shortId",
        "fingerprint": "chrome" } }
  } ]
}
EOF

xray -config /tmp/xtc.json &          # 后台运行测试客户端

# Gemini 名单内 → 应显示 warp=on、Cloudflare 段 IP
curl -s --socks5-hostname 127.0.0.1:10808 https://www.cloudflare.com/cdn-cgi/trace | grep -E 'ip=|warp='
# 普通网站（example.com 不在名单）→ 应显示 VPS 本机 IP、warp=off
curl -s --socks5-hostname 127.0.0.1:10808 https://example.com -o /dev/null -w '%{http_code}\n'

kill %1; rm -f /tmp/xtc.json         # 测完清理
```

> 判断规则是否命中的另一种方法：临时把 `loglevel` 改成 `info`，`systemctl restart xray` 后发请求，
> 用 `journalctl -u xray -f` 可看到每个域名的路由裁决（routed to warp/direct），验完改回 `warning`。

### 4.5 生成 Clash 订阅文件

在 VPS 上准备目录，写入订阅（`xray-warp-setup.sh sub` 会自动根据你的 Xray 配置生成，手工方式见下）：

```bash
mkdir -p /var/www/html/my-sub
SUB="clash-$(openssl rand -hex 8).yaml"
```

`/var/www/html/my-sub/$SUB` 内容模板（把 `@@` 标注处换成你的实际值；公钥用 4.3 的推导命令获取）：

```yaml
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
  - name: "US-Reality-WARP"
    type: vless
    server: @@VPS_IP或域名@@
    port: 443
    uuid: @@你的UUID@@
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    client-fingerprint: chrome
    reality-opts:
      public-key: @@Reality公钥@@
      short-id: @@你的shortId@@

proxy-groups:
  - name: "🚀 节点选择"
    type: select
    proxies: ["US-Reality-WARP", "DIRECT"]
  - name: "🤖 AI 服务"
    type: select
    proxies: ["US-Reality-WARP", "🚀 节点选择", "DIRECT"]
  - name: "🎬 国外流媒体"
    type: select
    proxies: ["US-Reality-WARP", "🚀 节点选择", "DIRECT"]
  - name: "🐟 漏网之鱼"
    type: select
    proxies: ["US-Reality-WARP", "🚀 节点选择", "DIRECT"]

rules:
  # 局域网
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
  # 广告
  - GEOSITE,category-ads-all,REJECT
  # 禁用 QUIC，强制浏览器回退 TCP
  - AND,((NETWORK,udp),(DST-PORT,443)),REJECT
  # AI
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
  # 流媒体
  - GEOSITE,netflix,🎬 国外流媒体
  - GEOSITE,spotify,🎬 国外流媒体
  - GEOSITE,disney,🎬 国外流媒体
  - GEOSITE,youtube,🎬 国外流媒体
  - GEOSITE,hbo,🎬 国外流媒体
  - GEOSITE,hulu,🎬 国外流媒体
  - GEOSITE,primevideo,🎬 国外流媒体
  # 国内直连（注意：不存在 GEOSITE,microsoft-cn 这个分类，写了会导致整份配置校验失败！）
  - GEOSITE,apple-cn,DIRECT
  - DOMAIN-SUFFIX,microsoft.cn,DIRECT
  - DOMAIN-SUFFIX,office365.cn,DIRECT
  - DOMAIN-SUFFIX,visualstudio.cn,DIRECT
  - DOMAIN-SUFFIX,azure.cn,DIRECT
  - GEOSITE,category-games-cn,DIRECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  # 兜底
  - MATCH,🐟 漏网之鱼
```

关键字段解释：

| 字段 | 含义 |
|---|---|
| `client-fingerprint: chrome` | Reality 必需的 uTLS 指纹，模拟 Chrome；不写会导致握手异常 |
| `flow: xtls-rprx-vision` | 必须与**服务端 clients 里的 flow 完全一致** |
| `servername` / `reality-opts.public-key` / `short-id` | 必须与服务端 `serverNames` / 私钥推导公钥 / `shortIds` 一致 |
| `AND,((NETWORK,udp),(DST-PORT,443)),REJECT` | 禁 QUIC：浏览器尝试 HTTP/3(UDP/443) 失败后回退 HTTP/2(TCP)，代理地区判定更稳定 |

**本地用内核校验订阅是否合法**（不依赖 GUI，macOS 上 Clash Verge 自带内核）：

```bash
# macOS 示例
MIHOMO="/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"
"$MIHOMO" -d <配置目录(需含 geosite.dat/geoip.dat)> -f 订阅.yaml -t
# 最后一行出现 configuration file ... test is successful 即通过
```

### 4.6 用 nginx 对外提供 HTTP 订阅链接

```bash
apt-get install -y nginx
cat > /etc/nginx/conf.d/xray-sub.conf <<'EOF'
server {
    listen 8888;
    server_name _;

    location /my-sub/ {
        root /var/www/html;
        default_type text/yaml;
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }
}
EOF

nginx -t && systemctl reload nginx
chmod 644 /var/www/html/my-sub/*.yaml
```

验证：

```bash
# VPS 本机
curl -I http://127.0.0.1:8888/my-sub/$SUB
# 本地电脑（确认端口对外开放）
curl -I http://<VPS_IP>:8888/my-sub/$SUB
```

> 不想装 nginx 的临时替代：`cd /var/www/html/my-sub && python3 -m http.server 8888`（不推荐长期使用，无缓存头、无进程守护）。

### 4.7 客户端导入

1. 复制订阅链接：`http://<VPS_IP>:8888/my-sub/clash-xxxxxxxxxxxxxxxx.yaml`
2. 打开 **Clash Verge X → 订阅（Profiles）→ 新建/导入**，粘贴 URL 保存。
3. 点该订阅卡片上的**刷新**，然后点击启用。
4. 第一次启用时内核会自动下载 `geosite.dat` / `geoip.dat`（走代理下载即可）。
5. 系统代理或 TUN 模式按需开启；浏览器访问 `https://gemini.google.com` 验证。

---

## 5. 分流规则说明（服务端 vs 客户端）

两层规则职责不同，**不要混淆**：

| 层级 | 配置位置 | 决定什么 | 例子 |
|---|---|---|---|
| 客户端 | Clash 订阅 `rules` | 流量**要不要走节点**、进哪个策略组 | 国内网站/IP → DIRECT；广告 → REJECT；Gemini → AI 组（节点） |
| 服务端 | Xray `routing.rules` | 到达 VPS 的流量**从哪个出口出去** | Gemini/OpenAI/Netflix → WARP；其他 → VPS 直连 |

**为什么两边都要写 Gemini？**

- 客户端不写：Gemini 也会被最后的 `MATCH` 兜底送到节点，其实也能工作；显式写是为了进「AI 服务」策略组，方便你**手动切换**（比如临时换 DIRECT 做对比测试）。
- 服务端必须写：客户端只管"送到 VPS"，真正换成 WARP 出口是服务端路由做的。

**如何加新的走 WARP 域名**：改服务端 Xray 配置，在 warp 规则的 `domain` 数组里加一行（`domain:example.com` 含子域），`xray -test` 后重启即可，**客户端无需改动**。

**只想在某台客户端临时全走 WARP**：在订阅的 proxy-groups 里把默认组节点后加一个走 warp 的入口，或直接改服务端兜底规则（不推荐）。

---

## 6. Gemini / AI 地区限制专题

这是最容易卡住的地方，单独讲透。

### 6.1 判定机制

Gemini 登录后是否可用，Google 同时检查两件事：

1. **IP 的地区与信誉**：不是看"能不能打开网页"，而是看登录后的应用请求（`gemini.google.com/app`、后台 API 域名）来源 IP 在 Google 地理库中的归属与风险评分。
2. **Google 账号的所属地区**：账号注册地/付款资料地区是中国大陆时，即使 IP 是美国，也可能提示 "Gemini isn't currently supported in your country/region"。

典型误区：用 curl 测首页返回 200 就以为 IP 没问题——**未登录首页不经过完整地区判定**。

### 6.2 本方案的应对顺序

1. Gemini 相关域名全部走 **WARP 美国出口**（Cloudflare 段 IP 地理归属稳定）。
2. 其他流量**强制 IPv4**，排除 VPS IPv6 归属地漂移。
3. 客户端**禁用 QUIC**，避免浏览器走 UDP/443 路径造成判定差异。
4. 刷新订阅后**用无痕窗口/完全重启浏览器**测试（清掉旧 QUIC 连接与缓存的地区 cookie）。

### 6.3 如果仍提示地区不支持 —— 账号侧处理

IP 侧已经做满还不行，基本就是账号地区问题：

- **首选：注册新 Google 账号**。注册全程挂当前美国节点（注册页 `accounts.google.com` 也走节点），新号默认就是美区，直接可用 Gemini。
- **老号改地区**：访问 [pay.google.com](https://pay.google.com) → 设置（付款资料）→ 国家/地区改为美国并填美国地址。
  - 有 Google Play 余额或活跃订阅时该选项可能不可改；
  - Play 商店地区一年只能改一次；
  - 也可以新建一个美国付款资料。
- 辅助验证：账号语言改 English、时区与 IP 一致，可降低风控概率。

### 6.4 WARP 出口被 Google 要求验证怎么办

小概率情况下 Google 会对 Cloudflare 共享 IP 弹"异常流量"人机验证。两个选择：

- 一般验证一次后会放行，正常使用即可；
- 实在不行，把服务端 Gemini 规则临时删掉（让它回退到 VPS IPv4 直连，美国机房 IP 通常也能用），即：

```bash
# 编辑配置删掉/注释 gemini 规则，然后
xray -test -config /usr/local/etc/xray/config.json && systemctl restart xray
```

### 6.5 判断"网络不通"还是"地区不支持"

| 现象 | 性质 | 处理方向 |
|---|---|---|
| 网页打不开、超时、连接重置 | 网络/DNS/QUIC | 查节点连通性、DNS、禁 QUIC、xray 日志 |
| 能打开但提示 supported in your country/region | IP 或账号地区 | 换 WARP 出口、无痕、账号改区 |
| 能登录但发消息报错 | 账号/接口层 | 换账号；检查 `generativelanguage.googleapis.com` 是否也走了代理 |
| API 返回 403 `PERMISSION_DENIED ... API Key` | 正常现象 | 这只是没带 API Key，说明网络是通的 |

---

## 7. 验证清单

部署完成后按此逐项确认：

```bash
# [VPS] WARP 正常（warp=on）
curl -s --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep warp=

# [VPS] xray 配置合法 + 服务运行
xray -test -config /usr/local/etc/xray/config.json
systemctl is-active xray

# [VPS] warp-svc 开机自启
systemctl is-enabled warp-svc

# [VPS] 订阅文件本机可拉
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8888/my-sub/<文件名>.yaml   # 200

# [本地] 订阅公网可拉
curl -I http://<VPS_IP>:8888/my-sub/<文件名>.yaml

# [本地] 订阅通过内核校验（见 4.5 末尾命令）

# [本地浏览器] 实际效果
# - https://gemini.google.com 可登录对话
# - https://www.cloudflare.com/cdn-cgi/trace 显示 VPS/Cloudflare 美国 IP
# - 国内网站（百度/淘宝）直连秒开、不卡
```

通过节点访问 `ipinfo.io` / `whoer.net` 若返回 **429/403**，这恰恰说明流量走的是 WARP 共享 IP（这两个域名被服务端规则指向了 warp），属正常现象。

---

## 8. 常见问题与排错

### 8.1 Clash 导入报"订阅配置校验失败，变更已撤销"

- **最常见原因：规则里写了 geodata 中不存在的分类**。典型就是 `GEOSITE,microsoft-cn`（meta-rules-dat 从未收录该列表，老教程以讹传讹）。改用具体域名：
  `DOMAIN-SUFFIX,microsoft.cn`、`office365.cn`、`visualstudio.cn`、`azure.cn`。
- 用 4.5 节的 `mihomo -t` 命令在本地跑一遍，错误会明确指出第几条规则有问题。
- 日志里若提示 `can't download GeoSite.dat ... deadline exceeded`：内核下载 geo 数据失败，开着代理重试，或从 [meta-rules-dat releases](https://github.com/MetaCubeX/meta-rules-dat/releases) 手动下载 `geosite.dat`/`geoip.dat` 放进内核数据目录。

### 8.2 Reality 握手失败 / 节点超时

- 核对四要素是否**逐字符一致**：UUID、flow（`xtls-rprx-vision`）、SNI、shortId。
- 公钥是否由**当前私钥**推导：`xray x25519 -i <私钥>`，别用旧密钥对的公钥。
- `client-fingerprint: chrome` 是否漏配。
- 服务端看日志：`journalctl -u xray -f`。

### 8.3 SSH 连上即断 / `kex_exchange_identification: Connection closed`

多为 VPS 的 SSH 防爆破（fail2ban/面板策略）因短时间多次连接临时封 IP。等待 1–3 分钟，或用 ControlMaster 复用连接（见第 2 节）。

### 8.4 重启 xray 时 SSH 会话瞬断

部分面板/主机的安全策略在 xray 重启瞬间会重置网络命名空间，属宿主侧行为。稍等重连即可，配置本身不受影响。

### 8.5 WARP 连不上 / 出口不通

```bash
warp-cli --accept-tos status                 # 是否 Connected
warp-cli --accept-tos disconnect && warp-cli --accept-tos connect
ss -tlnp | grep 40000                        # warp-svc 是否在监听
curl -v --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace
```

确认 Xray 配置里 socks 出站地址是 `127.0.0.1`（**不要写 localhost**，避免解析到 IPv6 或异常）。

### 8.6 改了配置没生效

- Xray：必须 `systemctl restart xray`，先 `-test`。
- 订阅：改的是服务端文件后，Clash 里要点**刷新订阅**（订阅有本地缓存）；nginx 已配置 `no-cache` 头。
- 浏览器：完全退出重开或用无痕窗口。

### 8.7 想看每个域名到底走了哪个出口

- 服务端临时开 info 日志：`sed -i 's/"loglevel": "warning"/"loglevel": "info"/' /usr/local/etc/xray/config.json && systemctl restart xray`，
  然后 `journalctl -u xray -f` 实时查看，验完改回 `warning`。
- Clash Verge X 的「连接（Connections）」页可看到每条连接命中的规则与链路上的出口。

### 8.8 apt 安装 cloudflare-warp 报仓库未签名

通常是缺 `gnupg` 导致 keyring 没建成。按 4.1 先装 gnupg，确认
`/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg` 文件存在再 `apt-get update`。

---

## 9. 备份、回滚与日常维护

**备份位置**（脚本和手工流程都会产生）：

```
/usr/local/etc/xray/config.json                 # 当前配置
/usr/local/etc/xray/config.json.bak.YYYYMMDDHHMMSS   # 每次脚本执行前自动备份
/var/www/html/my-sub/clash-xxxxxxxx.yaml        # 订阅文件（文件名即弱口令）
/etc/nginx/conf.d/xray-sub.conf                 # nginx 订阅站点
```

**回滚 Xray 配置**：

```bash
cp /usr/local/etc/xray/config.json.bak.<时间戳> /usr/local/etc/xray/config.json
xray -test -config /usr/local/etc/xray/config.json && systemctl restart xray
```

**更新 geodata**（新出的站点分类需要）：

```bash
# Xray 端
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-dat-geo
# 客户端由 Clash Verge X 自动更新，或在设置里手动更新 geo 数据
```

**升级 xray / warp-cli**：

```bash
apt-get update && apt-get install --only-upgrade -y cloudflare-warp   # warp-cli
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install  # xray（会保留配置）
systemctl restart xray
```

---

## 10. 安全建议

1. **订阅链接即账号凭证**：拿到 `http://IP:8888/my-sub/clash-xxxx.yaml` 的人就能看到节点全部信息并使用。务必：
   - 文件名保持**长随机串**（脚本默认即是）；
   - 不要把链接发到公开场合；
   - 怀疑泄露时立刻改名换订阅文件，并轮换 UUID / Reality 密钥。
2. **HTTP 明文**：订阅内容在网络上是明文传输。要求更高时：
   - 用域名 + nginx 套 HTTPS（Let's Encrypt），订阅链接变 `https://域名/...`；
   - 或在 nginx 上加 basic auth（Clash 订阅支持 `http://user:pass@域名/路径` 形式）；
   - 或用防火墙限制 8888 端口来源 IP（只允许你自己的固定 IP）。
3. **443 伪装目标**：长期使用建议把 Reality 的 `dest`/`serverNames` 从 apple 换成特征更普通的大站。
4. **BT 封禁**已在服务端规则内；如需进一步防滥用，可在 Xray 加流量统计/限速策略。
5. **定期更新** xray、warp-cli、geodata。

---

## 11. 附录

### 11.1 涉及的端口与进程

| 端口/进程 | 作用 |
|---|---|
| `:443` xray | VLESS Reality 入站（客户端连接点） |
| `127.0.0.1:40000` warp-svc | WARP SOCKS5（仅本机，Xray 链式出站用） |
| `:8888` nginx | HTTP 订阅分发 |
| 本机 `:7890`（客户端） | Clash mixed-port |
| 本机 `:9090`（客户端） | Clash external-controller |

### 11.2 服务管理命令速查

```bash
systemctl status  xray warp-svc nginx
systemctl restart xray
warp-cli --accept-tos status | connect | disconnect
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
journalctl -u xray -f
```

### 11.3 交付物清单

| 文件 | 说明 |
|---|---|
| `xray-warp-setup.sh` | 一键/分阶段自动化脚本（幂等） |
| `docs/GUIDE.zh-CN.md` | 本文档 |

### 11.4 配置变更对客户端的影响

| 服务端改动 | 客户端是否要刷新订阅 |
|---|---|
| 只改 routing（加/减走 WARP 的域名） | 否，重启 xray 即可 |
| 改 UUID / Reality 密钥 / shortId / 端口 / SNI | **是**，重新生成并刷新订阅 |
| 换 VPS / 换 IP / 换域名 | **是** |
| 只改客户端订阅规则（策略组、广告列表等） | 本身就在客户端，刷新/重载即可 |
