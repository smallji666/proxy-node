# proxy-node

[![version](https://img.shields.io/github/v/release/smallji666/proxy-node?label=version&color=blue)](https://github.com/smallji666/proxy-node/releases/latest)
[![license](https://img.shields.io/github/license/smallji666/proxy-node)](LICENSE)

一条命令在 VPS 上部署 **Reality / Hysteria2 / SS2022 / AnyTLS / TUIC v5**，自带部署向导、VPS 优化、订阅生成、安全自检。面向「小内存 VPS + 小火箭 / v2rayN / Clash」。

- 部署：5 协议自由组合，幂等安装、多设备凭据可单独吊销
- 防泄露：三端订阅自带 DNS 分流 + STUN/WebRTC 拦截 + 未列域名全代理；服务端域名还原 + 关 IPv6
- 安全：二进制 SHA-256 校验、证书指纹固定、systemd 沙箱、订阅 token 常量时间比较、自更新多道校验
- 隐私：无硬编码凭据、本地生成、不向第三方上报、`--dnsbl` 默认关、输入先清洗再落盘
- 体检：`proxy audit` / `dnstest` / `selftest` / `diag` / `speed`；部署日志 `/var/log/proxy-deploy.log`

---

## 快速开始

VPS 上以 **root** 执行：

```bash
f=$(mktemp)&&curl -fsSL --connect-timeout 10 -m 120 https://raw.githubusercontent.com/smallji666/proxy-node/main/setup.sh -o "$f"&&bash -n "$f"&&install -m755 "$f" /root/setup-proxy.sh&&rm "$f"&&bash /root/setup-proxy.sh
```

这条命令看着长，但每一段都在挡一种具体的失败，删任何一段都会出真问题：

| 片段 | 挡什么 |
|---|---|
| `f=$(mktemp)` | `/tmp` 是全局可写目录。用固定名字（如 `/tmp/pn.sh`）时，同机用户能提前把它换成符号链接，以 root 执行的 `curl -o` 就会顺着链接把别的文件截断 |
| `curl -fsSL --connect-timeout 10 -m 120` | 目标被阻断时，不带超时的 `curl` 会长时间停在"连接中"没有任何输出，用户只看到光标闪，以为脚本坏了 |
| `-o "$f"` | 下到临时文件，不直接写 `/root/setup-proxy.sh`——下载中断会把磁盘上那份**能用**的脚本顶成半截 |
| `bash -n "$f"` | 语法过了才允许落到正式位置。半截脚本直接执行，等于把一个能用的版本换成坏的 |
| `install -m755 … /root/setup-proxy.sh` | 一步完成复制+权限。必须先落盘再执行：脚本用 `readlink -f "$0"` 找自己，跑临时文件会把 `proxy` 软链指到 `/tmp`，紧接着就被清理掉 |
| `rm "$f"` | `install` 是复制不是移动，不清就每次留一个 200KB 的临时文件 |

不用 `curl | bash`：那样没法先验语法，弱网下会直接执行半截脚本，而且脚本不落盘就建不了 `proxy` 管理命令。**云安全组放行 TCP 443 和 UDP 443**（脚本改不了云控制台）。

向导里可多选（`1 3` / `1,2,5`），回车默认 `Reality+Hysteria2`。跳过向导：`PROTOCOLS=reality,hy2 bash /root/setup-proxy.sh install`。装完信息存 `/root/proxy-info.txt`。

版本为 **v主版本.次版本**（当前 **v1.0**），`proxy update` 靠版本号判断新旧。

---

## 管理命令

`proxy` 打开菜单，或直接用子命令：

```bash
proxy                         # 交互菜单
proxy update / update install # 更新脚本 / 更新后立即重装
proxy version / info / status # 版本 / 节点信息 / 服务状态
proxy wizard / optimize / timezone
proxy sub                     # 重新生成订阅
proxy restart / logs [hy2]
proxy audit [--dnsbl] / dnstest / speed / selftest / diag
proxy egress [socks5://…|off] # 上游出口（住宅 IP）
proxy verify [--fix]          # 安全自检
proxy user [list|add|link|rm] / reset / backup / restore <文件>
proxy install --clean / clean [--all]
proxy upgrade [latest|版本号] / upgrade --rollback
```

`proxy` 跑的是磁盘那份脚本，不会自动跟仓库走；重新粘贴一键命令或 `proxy install` 会先校验并原子替换自己。

---

## 协议与环境变量

默认 `reality,hy2`。`PROTOCOLS` 逗号分隔，**是最终状态**（少写会停掉对应服务）。后三个协议共用一个 sing-box 进程。

| 协议 | 内核 | 端口 | 适合 |
|---|---|---|---|
| `reality` | Xray | TCP 443 | 主力，借真实站点证书，抗封锁最强 |
| `hy2` | hysteria | UDP 443 | 弱网抗丢包 |
| `ss2022` | sing-box | TCP+UDP 8445 | 老客户端/IoT 兼容 |
| `anytls` | sing-box | TCP 8444 | TLS 多路复用，特征接近 HTTPS |
| `tuic` | sing-box | UDP 8443 | QUIC over UDP |

首次安装用环境变量定制，之后写入 `/etc/proxy-node/state.env`：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PROTOCOLS` | `reality,hy2` | 协议组合 |
| `VLESS_PORT` / `HY2_PORT` | `443` | 监听端口 |
| `SS2022_PORT` / `ANYTLS_PORT` / `TUIC_PORT` | `8445`/`8444`/`8443` | 扩展协议端口 |
| `REALITY_DEST` | 自动 | 伪装站；`random` 强制重选 |
| `REALITY_FP` | `chrome` | 客户端 uTLS 指纹，连不上时试 `firefox`/`safari`/`ios` |
| `ENABLE_OBFS` / `HY2_HOP` | `0` / 空 | HY2 混淆 / 端口跳跃如 `20000-30000` |
| `HY2_BW_UP` / `HY2_BW_DOWN` | 空 | Brutal 带宽 Mbps，空=默认 BBR |
| `DEFAULT_NODE` | `reality` | 订阅默认节点 `reality`(稳)/`hy2`(快) |
| `XRAY_VERSION` | `latest` | 追官方最新版（用官方 `.dgst` 校验），可设具体版本固定 |
| `HY2_VERSION` | `latest` | 追官方最新 2.x（用官方 `hashes.txt` 校验） |
| `SUB_HTTP` / `SUB_PORT` / `SUB_BIND` | `0`/随机/`127.0.0.1` | 订阅 HTTP 服务 |
| `EGRESS_URL` | 空 | 上游出口，也可 `proxy egress` 设置 |
| `HY2_INSECURE` / `ALLOW_UNVERIFIED_BIN` / `PN_NO_SELFUPDATE` | `0` | 调试/特殊场景开关 |

```bash
VLESS_PORT=8443 HY2_PORT=8443 ENABLE_OBFS=1 HY2_HOP=20000-30000 bash /root/setup-proxy.sh install
REALITY_DEST=www.samsung.com bash /root/setup-proxy.sh install
```

换伪装站时自签证书会重签（CN 与新站一致）。节点备注名默认按出口 IP 反查厂商（`DigitalOcean-VLESS` 等），改：`proxy name RackNerd`。

---

## 订阅文件

输出到 `/var/www/proxy-sub/<随机token>/`：

```
shadowrocket.conf           iOS 小火箭，DNS 走隧道 + 全代理，导入即用（首选）
v2rayn-routed.json          v2rayN 首选，sing-box 内核导入，自带 DNS 分流 + STUN 拦截 + 全代理
clash.yaml                  Clash/mihomo，fake-ip + 国内分流；AnyTLS 需 mihomo ≥1.19
singbox.json / -compat.json sing-box 1.13+ / 1.12（格式在 1.11~1.14 连改三次，故出两份）
v2rayn.txt / -safe.txt      v2rayN 纯节点链接（不带 DNS，需客户端自己配分流）
base64.txt / links.txt      通用订阅 / 原始链接
client-guide.md             客户端配置指南
```

**纯节点链接（`base64`/`links`/`v2rayn*.txt`）格式本身不含 DNS 字段，不会自带防护**；要开箱即用的防泄露就导入 `shadowrocket.conf` / `v2rayn-routed.json` / `clash.yaml` / `singbox.json`。

`SUB_HTTP=1` 起静态服务，默认只监听 `127.0.0.1`；只响应 `/<token>/<白名单文件名>`，其余 404、不列目录。手机取订阅先建 SSH 隧道。

---

## 客户端防护（送中 / DNS / WebRTC）

"送中" = Google 把你当中国大陆用户。根因是**客户端先在本地把域名解析了**：系统 DNS 拿到国内 CDN IP → 把 IP 交给代理 → 服务端只能连那个 IP。服务端已从 TLS ClientHello 里捞回域名自己重解析（REALITY `sniffing`+`destOverride`、HY2 `sniff`+`rewriteDomain`、sing-box route sniff），**这层不需客户端配合**。

订阅再强制 fake-ip（Clash `enhanced-mode: fake-ip`、sing-box `final: remote`），域名先拿 `198.18.x.x` 假地址，真域名原样送服务端；同时关 IPv6 防 AAAA 绕过。

**小火箭**：按顺序导入 `base64.txt`（节点）→ `shadowrocket.conf`（长按「使用配置」）→ 首页「全局路由」选「配置」→ 选节点。DNS 已配好：`FINAL,PROXY,force-remote-dns` 让境外域名不在本地解析，`dns-server = https://cloudflare-dns.com/dns-query#proxy=节点名` 让 DNS 查询本身走隧道，`stun-response-ip` 让 STUN 返回假 IP。国内域名走国内 DoH 直连，属地正常。只有纯节点链接才需手动核对七项（见 `client-guide.md`）。

**v2rayN**：**首选导入 `v2rayn-routed.json`**（sing-box 内核），自带与上面一致的防护。若用纯节点链接，务必：路由模式选「绕过大陆」（不要全局）、路由域名解析策略选 `IPIfNonMatch`（不要 `AsIs`）、代理目标解析策略保持 `Default`（改成 `UseIP`/`UseIPv4` 就是送中）、TUN 的 MTU 填 1500 并关严格路由。

**Clash**：必须用 **mihomo 内核**（老 Clash 不支持 fake-ip，会静默回退系统 DNS）。导入 `clash.yaml` 即用。

**所有客户端**：关掉浏览器/App 自带 DoH（Chrome/Edge 隐私设置、Firefox 网络设置、Safari 系统 DNS），否则会绕过 fake-ip 把域名解析成国内 CDN IP。

**自测**：连上代理后跑 `dnsleaktest.com`(Extended) / `ipleak.net` / `browserleaks.com/webrtc`，只出现境外解析器正常，出现国内运营商 DNS 或真实 IP 就是有请求绕过代理。`proxy audit` 只看服务端侧；`proxy dnstest` 会验三端订阅的 DNS 配置、DoH 端点能否真解析、出口是否同源。但**客户端到底用了哪个 DNS，服务端测不到**，最终仍要你自己跑一次 dnsleaktest。判定 Google 地区拿出口国家做基准，别见 `google.com.hk` 就报送中。

---

## TikTok / Claude 与多账号

脚本只优化**链路质量**，账号安全一大半在脚本之外。服务端已做：出口 IP 稳定、一条线路一个出口（不套 WARP/CDN）、时间同步、独立凭据、服务端二次解析、订阅关 v6。

改不了的硬伤：**机房 IP**（数据中心段直接归类 `hosting`，权重天然低于住宅 IP，双线 ISP 也不改变 IP 段在数据库里的注册类型）、无 PTR / 共享 IP 历史、客户端 DNS 泄露、浏览器指纹、账号行为。

唯一技术解是让最终出口不是机房 IP：有家宽/动态 IP 时放最外层，脚本内置：

```bash
proxy egress socks5://用户:密码@住宅机IP:1080   # 接上（会走隧道复测真实出口）
proxy egress                                   # 查看 + 实测
proxy egress off                               # 关闭
```

动态 IP 要配 DDNS；两跳延迟上升；上游挂了不会自动回落直连（防暴露）；WARP 段同样被标机房。

只对 **reality / anytls / tuic** 生效：hysteria2 由独立的 hysteria 进程承载，不吃 xray/sing-box 的 outbounds，它的流量仍从本机 IP 直出。

### Claude / Anthropic 风控

没有任何部署脚本能保证不封号，能做的是把可控信号收拾干净。**最易触发封号是真实 IP 短暂暴露**（代理断几秒、大陆 IP 漏出）。用配置模式就不用切全局。

网传"Claude 分流域名清单"（除 `claude.ai`/`anthropic.com` 外还有 intercom 客服、datadog 监控、stripe 支付、sentry、sift 反欺诈、googleapis 推送等第三方域名）是给"只代理列名域名、其余默认直连"的配置用的——那种配置漏一个就从真实 IP 出去。本订阅反过来：`FINAL,PROXY,force-remote-dns` 是"除国内白名单外**全部**走代理"，这批域名一个都不用列就全在代理里。**只有用纯节点链接时才需要切全局兜底**，这也是前面强烈建议用 `v2rayn-routed.json` 的原因。

**别照抄清单里的 IP-CIDR 规则**（如 `IP-CIDR,34.8.0.0/16,PROXY`）：按官方 README 的 `no-resolve` 语义，域名请求撞到 IP 类规则会先向本地 DNS 查询判断 IP，正好把解析暴露给运营商；加 `no-resolve` 又会让域名请求跳过该规则，等于白写。靠兜底代理覆盖即可。

**TikTok 域名不用单独列**：兜底全代理已把所有非白名单域名钉在同一出口、DNS 走境外。真正决定风控的是 SIM 卡地区 / GPS / 系统语言时区 / 出口 IP 是否机房段，域名列得再全也没用。

---

## 常见问题

- **升级后 Reality 连不上、HY2 能用** → 多为客户端 TLS 指纹与 Xray 自动协商的 X25519MLKEM768 对不上：mihomo 在 `reality-opts` 下加 `support-x25519mlkem768: true`，小火箭保持默认指纹。再按顺序试 `proxy upgrade --rollback` → `REALITY_FP=firefox proxy sub` → `REALITY_DEST=random` 重装 → 换端口 → 先用 HY2。
- **开代理后国内网站打不开** → 国内流量被误判进代理：小火箭 DNS 覆写留空或 `223.5.5.5`、全局路由选「配置」；v2rayN 域名解析策略改 `IPIfNonMatch`、路由模式选「绕过大陆」。
- **开 TUN 完全没网** → MTU 填 1500、关严格路由、管理员运行；`ping 1.1.1.1` 通=DNS 问题，不通=网卡/路由没起来。
- **连不上不知哪环** → `proxy diag` 生成脱敏报告（UUID/密码/token 已脱敏）。
- **`proxy` 提示 Permission denied** → `chmod +x /root/setup-proxy.sh`。
- **换端口连不上** → 云安全组跟着改（HY2 是 UDP，别只放行 TCP）。

## 卸载

```bash
proxy clean          # 清服务与配置，保留 proxy 命令
proxy clean --all    # 连管理命令一起删
```

## License / 边界

[MIT](LICENSE)。真实 VPS 重装复验、客户端 dnsleaktest 实测、各内核版本启动回退只能在真机验证；本仓库回归是静态断言 + 沙箱抽函数，不宣称真机通过。
