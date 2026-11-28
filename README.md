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
proxy rule [list|check|add|rm|update]  # 国内直连名单（见下）
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
| `SB_VERSION` | `latest` | 追官方最新版（用 GitHub Release 的 asset `digest` 校验）；sing-box 小版本会删改配置字段，故换内核前先用新内核 `check` 现有配置，不通过就不换（旧内核继续跑，另存 `.prev` 可回滚）；可设具体版本固定 |
| `SUB_HTTP` / `SUB_PORT` / `SUB_BIND` | `0`/随机/`127.0.0.1` | 订阅 HTTP 服务 |
| `EGRESS_URL` | 空 | 上游出口，也可 `proxy egress` 设置 |
| `HY2_INSECURE` / `ALLOW_UNVERIFIED_BIN` / `PN_NO_SELFUPDATE` | `0` | 调试/特殊场景开关 |

```bash
VLESS_PORT=8443 HY2_PORT=8443 ENABLE_OBFS=1 HY2_HOP=20000-30000 bash /root/setup-proxy.sh install
REALITY_DEST=www.samsung.com bash /root/setup-proxy.sh install
```

换伪装站时自签证书会重签（CN 与新站一致）。节点备注名默认按出口 IP 反查厂商（`DigitalOcean-VLESS` 等），改：`proxy name RackNerd`。

伪装站是脚本从一份内置池子里随机挑的，池子里都是些眼熟的大站（samsung / nvidia / ibm / oracle / dell / hp / intel / adobe / mozilla / nginx / mysql / python…），全部实测过不套 Cloudflare、国内可直连、全球流量排名 2100 名以内。想看清当前用的是哪个、还有哪些可选，或直接换一个：

```bash
proxy dest                    # 当前站 + 全部候选，末尾输入序号 / r 随机换 / c 自填域名
proxy dest list               # 只看候选池
proxy dest set www.oracle.com # 非交互换站；proxy dest set random 重新随机挑
```

**重装默认复用当前伪装站**：静默换 SNI 会让所有已经发出去的客户端链接一次性失效，所以只有上面这些显式操作才会换。换站会重签 hysteria2 / sing-box 证书、重算指纹、重写 Xray 配置与全部订阅，任一步失败自动回滚；成功后所有客户端必须重新导入。也可以在重装时指定：`REALITY_DEST=www.samsung.com bash /root/setup-proxy.sh install`。

**SNI 这一行必须与客户端一字不差**，抄错不会提示 SNI 错误，只会表现为连接超时或握手失败。`proxy info` 也会在 SNI 旁边标出它是哪个网站。

---

## 国内直连名单

三端订阅（小火箭 / Clash / sing-box）共用**同一份**国内域名清单，由脚本内置一份、可再叠加两份外部来源，合并去重后渲染。国内域名命中后走 DIRECT，用国内 DNS 解析 —— 属地检测看到的是国内运营商；境外域名走代理、远端解析 —— 检测看到的是 VPS 所在国。这是"打开国内站显示国内、国外站显示国外"的关键。

```bash
proxy rule                    # 看当前生效的全部域名（内置 + 用户 + 远程，已去重）
proxy rule check              # 检查用户/远程文件格式，报告非法行
proxy rule add taobao.com     # 加一个域名到用户名单
proxy rule rm  taobao.com     # 从用户名单移除（不影响内置/远程）
proxy rule update             # 从官方源更新远程名单
```

- **用户名单** `/etc/proxy-node/user-direct.txt`：一行一个域名，`#` 开头是注释。改完 `proxy rule add/rm` 或手工编辑后执行 `proxy sub` 重新生成订阅即可生效，不用重装。非法行（通配、下划线、路径）会被静默跳过，用 `proxy rule check` 查。
- **远程名单** `/etc/proxy-node/remote-direct.txt`：`proxy rule update` 从仓库 `cn-direct.txt` 拉取。官方源优先；官方不可达时退到镜像并要求**两个镜像哈希一致**才采用，失败时现有名单原样保留。拉下来的文件还要过格式强校验（大小/行数上限、格式自证头、每条都是合法域名），错误页或截断文件装不进来。
- 收录标准是"只收 100% 确定境内、DNS 落在国内"的服务，**绝不收境外域名** —— 一个境外域名混进直连名单，它的 DNS 就会走国内明文，比多漏几个国内站严重得多。关键词只收独创品牌词（`taobao`/`bilibili`…），不收 `58`/`sto`/`wps` 这类数字或通用缩写。
- **资源域名要单独收**：国内站点的主域名和它的图片/JS/CSS 常常不同域（淘宝页面 `taobao.com`，图片在 `alicdn.com`；微博页面 `weibo.com`，图片在 `sinaimg.cn`）。本配置的 `GEOIP,CN` 带 `no-resolve`，域名请求只认这份白名单，所以主域名进了名单、资源域名没进的表现是**页面能开、图片一直转圈**，而且这些请求全走代理。`cn-direct.txt` 末尾的「静态资源 / CDN」一组就是为此存在的，动它之前先读那几行注释。

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

**`singbox.json` 的默认出口**：服务端 Xray ≥ 26.9.8 时 sing-box 的 REALITY 客户端连不上（上游 #4520，见常见问题），这两份配置会把默认出口设为 HY2，REALITY 节点仍保留在 outbounds 里（上游修好后可手动切回）。`v2rayn-routed.json` 是同一份配置的副本，同样默认 HY2。

`SUB_HTTP=1` 起静态服务，默认只监听 `127.0.0.1`；只响应 `/<token>/<白名单文件名>`，其余 404、不列目录。手机取订阅先建 SSH 隧道。

---

## 客户端防护（送中 / DNS / WebRTC）

"送中" = Google 把你当中国大陆用户。根因是**客户端先在本地把域名解析了**：系统 DNS 拿到国内 CDN IP → 把 IP 交给代理 → 服务端只能连那个 IP。服务端已从 TLS ClientHello 里捞回域名自己重解析（REALITY `sniffing`+`destOverride`、HY2 `sniff`+`rewriteDomain`、sing-box route sniff），**这层不需客户端配合**。

订阅再强制 fake-ip（Clash `enhanced-mode: fake-ip`、sing-box `final: remote`），域名先拿 `198.18.x.x` 假地址，真域名原样送服务端；同时关 IPv6 防 AAAA 绕过。

**小火箭**：按顺序导入 `base64.txt`（节点）→ `shadowrocket.conf`（长按「使用配置」）→ 首页「全局路由」选「配置」→ 选节点。DNS 已配好：`FINAL,PROXY,force-remote-dns` 让境外域名在服务端解析（DNS 泄露检测仍显示境外解析器），`dns-server` / `direct-dns-server` 用国内 DoH 让抖音、淘宝等直连域名解析到国内 CDN 节点（开 VPN 也能刷抖音），`stun-response-ip` 填真实 VPS 出口 IP，让 WebRTC 报的公网 IP 与代理出口一致，避免属地检测误报「WebRTC 泄露」。TikTok 走境外 DNS、抖音走国内 DNS，两端互不干扰。只有纯节点链接才需手动核对七项（见 `client-guide.md`）。

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

只对 **reality / ss2022 / anytls / tuic** 生效：hysteria2 由独立的 hysteria 进程承载，不吃 xray/sing-box 的 outbounds，它的流量仍从本机 IP 直出。

### Claude / Anthropic 风控

没有任何部署脚本能保证不封号，能做的是把可控信号收拾干净。**最易触发封号是真实 IP 短暂暴露**（代理断几秒、大陆 IP 漏出）。用配置模式就不用切全局。

网传"Claude 分流域名清单"（除 `claude.ai`/`anthropic.com` 外还有 intercom 客服、datadog 监控、stripe 支付、sentry、sift 反欺诈、googleapis 推送等第三方域名）是给"只代理列名域名、其余默认直连"的配置用的——那种配置漏一个就从真实 IP 出去。本订阅反过来：`FINAL,PROXY,force-remote-dns` 是"除国内白名单外**全部**走代理"，这批域名一个都不用列就全在代理里。**只有用纯节点链接时才需要切全局兜底**，这也是前面强烈建议用 `v2rayn-routed.json` 的原因。

**别照抄清单里的 IP-CIDR 规则**（如 `IP-CIDR,34.8.0.0/16,PROXY`）：按官方 README 的 `no-resolve` 语义，域名请求撞到 IP 类规则会先向本地 DNS 查询判断 IP，正好把解析暴露给运营商；加 `no-resolve` 又会让域名请求跳过该规则，等于白写。靠兜底代理覆盖即可。

**TikTok 域名不用单独列**：兜底全代理已把所有非白名单域名钉在同一出口、DNS 走境外。真正决定风控的是 SIM 卡地区 / GPS / 系统语言时区 / 出口 IP 是否机房段，域名列得再全也没用。

---

## 常见问题

- **升级后 Reality 连不上、HY2 能用** → 客户端没发 REALITY 要求的 X25519MLKEM768 key share。时间线（已实测）：Xray **v25.5.16** 起支持该混合密钥交换（伪装站支持时自动协商），**v26.9.8 起服务端强制要求**，不带就静默回退到伪装站，客户端只看到 `REALITY authentication failed`。按内核处理：xray 内核原生支持；**mihomo ≥ 1.19.10** 需要 `reality-opts` 下写 `support-x25519mlkem768: true`（本脚本生成的 `clash.yaml` 会按服务端版本自动写，低于 25.5.16 的服务端不会写）；sing-box 截至 1.14.4 不支持，见下一条。再按顺序试 `proxy upgrade --rollback` → `REALITY_FP=firefox proxy sub` → `REALITY_DEST=random` 重装 → 换端口 → 先用 HY2。
- **sing-box 内核连 REALITY 必然失败（`reality verification failed`）** → Xray ≥ 26.9.8 的 REALITY 服务端要求 ClientHello 带 X25519MLKEM768 key share，sing-box 的 uTLS 模板不带，上游 issue [SagerNet/sing-box#4520](https://github.com/SagerNet/sing-box/issues/4520) 至今未修（1.14.4 实测仍失败，换指纹/关 uTLS 都无效）。所以脚本会把 `singbox.json` / `v2rayn-routed.json` 的默认出口切到 HY2；要用 REALITY 就换 mihomo（`clash.yaml`）或 xray 内核（`v2rayn.txt`）。想让 sing-box 也能用 REALITY，只能把服务端降到 **26.9.8 之前**（如 `XRAY_VERSION=26.6.27 bash /root/setup-proxy.sh install`，实测可用），代价是放弃后续内核更新。
- **sing-box 会不会自动升到最新版 / 升挂了怎么退** → 默认追官方最新版（`SB_VERSION` 留空即可），和 Xray、HY2 同一套策略：官方 API 可达就装最新，不可达就沿用本机在跑的版本，绝不降级。官方从不发校验文件，所以哈希取的是 GitHub Release 里每个资产的 `digest`（`sha256:…`），和脚本内置值一致；两者不一致直接拒绝安装。因为 sing-box 每个小版本都可能删改配置字段（1.11 弃用、1.12 删除 legacy inbound 与 geoip），换内核前会先用**新内核 `check` 一遍现有配置**，不通过就放弃升级、旧内核继续跑，节点不会断。升级后真出问题，上一版二进制留在 `/usr/local/bin/sing-box.prev`，`mv /usr/local/bin/sing-box.prev /usr/local/bin/sing-box && systemctl restart sing-box` 即可回退。
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
