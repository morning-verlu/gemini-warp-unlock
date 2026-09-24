# gemini-warp-unlock

**English** | [简体中文](README.zh-CN.md)

> 用 **Xray (VLESS + Reality) + Cloudflare WARP 官方客户端 (warp-cli)** 链式出站，
> 解决 **Gemini / OpenAI / Claude** 等 AI 服务的地区访问限制（*"Gemini isn't supported in your country/region"*）；
> 一条命令产出可直接导入 **Clash Verge / mihomo** 的 HTTP 订阅链接，内置国内外分流规则。

## 为什么需要它

廉价 VPS 直连 Gemini 时常遇到登录后提示 *"Gemini isn't currently supported in your country/region"*。
根因通常不是"连不上"，而是：

1. **VPS 机房 IP（尤其 IPv6）在 Google 地理库中定位不准或信誉低**；
2. 普通代理方案无法为 AI 域名单独指定干净出口。

本项目的做法：AI 相关域名在服务端被精确分流到 **Cloudflare WARP 原生美国出口**，
其余流量仍走 VPS 直连（并强制 IPv4），兼顾解锁成功率与速度。

```
Clash Verge (本地)
  └─ VLESS + Reality + Vision ──► VPS: Xray :443
                                    ├─ Gemini / OpenAI / 流媒体 ──► warp-cli SOCKS5 :40000 ──► WARP 美国出口
                                    └─ 其他流量 ───────────────────► VPS 直连 (强制 IPv4)
```

> 注意：IP 层方案无法解决 **Google 账号地区**被标记为中国大陆的问题。
> 若换干净 IP + 无痕窗口后仍提示地区不支持，需要美区账号或修改付款资料地区。详见[文档第 6 节](docs/GUIDE.zh-CN.md#6-gemini--ai-地区限制专题)。

## 特性

- **一键部署**：安装 warp-cli → 改写 Xray（WARP 出站 + AI 域名分流 + 强制 IPv4）→ 生成 Clash 订阅 → 配置 nginx 分发，全自动
- **分阶段执行**：`warp` / `xray` / `sub` / `nginx` / `verify` 可单独运行，便于排错
- **幂等**：重复执行不产生重复规则；自动备份原 Xray 配置；自动由 Reality 私钥推导公钥
- **无面板、小攻击面**：不常驻 Web 管理端口，节点就是一份可读的 JSON + 一份 YAML
- **订阅内置规则**：局域网直连、广告拦截、AI/流媒体分组、国内直连、禁 QUIC、兜底走节点

## 快速开始

适用：Debian 11/12/13、Ubuntu 20.04+，以 root 运行；VPS 上已有可用的 Xray VLESS+Reality 入站。

```bash
# 已有 Xray 节点
curl -fsSL https://raw.githubusercontent.com/morning-verlu/gemini-warp-unlock/main/xray-warp-setup.sh -o setup.sh
chmod +x setup.sh && ./setup.sh

# 全新机器（已装 xray 二进制但无配置，脚本自动生成 UUID/Reality 密钥）
./setup.sh --init
```

执行结束会打印订阅链接：

```
http://<VPS_IP>:8888/my-sub/clash-<随机串>.yaml
```

在 **Clash Verge X → 订阅** 中粘贴导入，刷新并启用即可。

### 分阶段运行

```bash
./setup.sh warp     # 只安装并配置 WARP（proxy 模式, SOCKS5 :40000）
./setup.sh xray     # 只改写 Xray 配置并重启
./setup.sh sub      # 只重新生成 Clash 订阅
./setup.sh nginx    # 只配置 nginx 订阅分发
./setup.sh verify   # 只做最终验证
```

### 常用环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `NODE_DOMAIN` | 自动取公网 IPv4 | VPS 域名 |
| `WARP_PORT` | `40000` | warp-cli SOCKS5 端口 |
| `XRAY_CONF` | `/usr/local/etc/xray/config.json` | Xray 配置路径 |
| `SUB_PORT` / `SUB_PATH` | `8888` / `/my-sub` | 订阅分发端口与路径 |
| `SUB_FILE` | `clash-<随机>.yaml` | 订阅文件名 |
| `PROXY_NAME` | `US-Reality-WARP` | 订阅内节点名称 |
| `FORCE_IPV4` | `1` | 直连出站是否强制 IPv4 |

## 验证

```bash
# VPS 上：WARP 在线
curl -s --socks5-hostname 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep warp=
# 期望: warp=on
```

客户端浏览器用**无痕窗口**打开 https://gemini.google.com 登录测试。
完整验证清单见[文档第 7 节](docs/GUIDE.zh-CN.md#7-验证清单)。

## 文档

- **[中文部署详解 docs/GUIDE.zh-CN.md](docs/GUIDE.zh-CN.md)**
  架构原理、7 步手动部署、完整 Xray/Clash 配置模板、Gemini 地区限制专题（IP 层 vs 账号层）、
  8 类常见排错（订阅校验失败 / Reality 握手 / SSH 防爆破断连等）、回滚与安全加固。

## 同类项目对比

| 方案 | 适合场景 |
|---|---|
| **本项目** | 单节点自用、要最小攻击面、配置透明可版本化 |
| [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) | 需要 Web 面板、多用户/流量统计、一键轮换 WARP IP |
| [mack-a/v2ray-agent](https://github.com/mack-a/v2ray-agent) | 偏好中文菜单式全家桶脚本 |
| [zhu327/gemini-openai-proxy](https://github.com/zhu327/gemini-openai-proxy) | 只需要程序调 Gemini API（Cloudflare Workers 中转） |

## 免责声明

本项目仅用于学习与研究网络技术，请在你所在地区法律法规允许的范围内使用，
并遵守目标服务的服务条款。使用者需自行承担一切使用风险。

## License

[MIT](LICENSE)
