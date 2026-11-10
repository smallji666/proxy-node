# proxy-node

[![version](https://img.shields.io/github/v/release/smallji666/proxy-node?label=version&color=blue)](https://github.com/smallji666/proxy-node/releases/latest)
[![license](https://img.shields.io/github/license/smallji666/proxy-node)](LICENSE)
[![platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20Rocky-lightgrey)](#系统要求)

> 一条命令在 VPS 上部署 **Reality / Hysteria2 / SS2022 / AnyTLS / TUIC v5**，
> 运行后先出**部署向导**让你点选协议，自带 VPS 优化、幂等安装、订阅生成和日常管理命令。

专为「小内存 VPS + iOS 小火箭 / v2rayN / Clash」这种常见组合调过参数，
把几个实际会踩的坑提前处理掉了（见下方[设计取舍](#设计取舍)）。

---

## 特性

| 能力 | 说明 |
|---|---|
| 部署向导 | 无参数运行即出菜单：选协议 / 一键优化 VPS / 清理重装，不用记参数 |
| 多协议 | 5 种可自由组合：VLESS-REALITY、Hysteria2、Shadowsocks-2022、AnyTLS、TUIC v5；默认前两种，其余按需加装 |
| VPS 优化 | `proxy optimize` 独立执行：BBR + fq、UDP 缓冲区与网卡队列、句柄数、journald 限容、1GB swap、时间同步 |
| 时区 | `proxy timezone` 独立设置（按出口 IP 自动匹配 / 亚洲 / 欧洲 / 美洲 / UTC / 手动输入）；NTP 同步与时区分开，互不影响 |
| 证书固定 | Hysteria2 用 `pinSHA256`（整证书 SHA-256，64 位 hex）固定指纹；`insecure` 只跳过 CA 校验，身份仍由指纹保证 |
| 自动选伪装站 | 候选站限定「国内可直连」，按 TLS 1.3+H2 分档、档内按握手耗时排序，**只在前三名里随机**，再用真实 REALITY 握手验证通过才采用 |
| 幂等安装 | 凭据持久化，重跑脚本不会重置 UUID，已有客户端不失效 |
| 多设备凭据 | 每台设备一条 UUID，可单独吊销；丢手机不影响其他设备 |
| 一键清理 | 清理内嵌在安装流程：`install --clean` 一步清理重装，残缺安装自动识别；也可 `proxy clean` 单独清 |
| 备份迁移 | `proxy backup` 打包凭据与证书，换 VPS 时 `restore` 直接沿用，不用重新导入客户端 |
| 隧道自检 | 健康检查每 30 分钟真跑一次 REALITY 握手，连续失败才重启，避免误杀 |
| 订阅生成 | 自动产出 `clash.yaml` / `singbox.json` / `singbox-compat.json` / `v2rayn.txt` / `v2rayn-safe.txt` / `base64.txt` / `links.txt` / `client-guide.md` |
| 端口跳跃 | Hysteria2 UDP 端口区间跳跃，绕开单端口 QoS |
| 管理命令 | 安装后可用 `proxy` 打开菜单，或用子命令直接操作 |
| 配置备份 | 每次改动前自动备份，保留最近 5 份 |
| 内置 DNS 解析 | Xray 自带 DNS 缓存 + 强制 IPv4，解析更快、不依赖系统解析器 |
| 订阅自带 DNS | 生成的 Clash / sing-box 配置带 fake-ip，**域名原样送到服务端解析**，这是防 Google 送中的关键 |
| IP 画像体检 | `proxy audit` 直查 `hosting` / `proxy` 标记与 Google 地区判定，不用自己猜平台会怎么看你 |
| IPv6 防泄漏 | 出站强制 IPv4 + 路由层屏蔽 IPv6 目标 |
| 健康检查 | systemd timer 每 5 分钟检查，服务或端口异常自动重启 |
| 线路体检 | `proxy audit` 实测出口 IP、PTR、时间同步、**网卡丢包与 TCP 重传率**，并给出客户端检查清单 |
| 上游出口 | `proxy egress` 把最终出口换成住宅 IP / 中转机，服务端改一处、客户端不用动 —— 这是不被判机房的唯一技术解法 |
| 协议实测 | `proxy selftest` 用**订阅里同一份配置**起临时客户端，逐个协议真连一次；装完自动跑，订阅与服务端不一致当场暴露 |
| 安全自检 | `proxy verify` 查二进制指纹 / 配置合法性 / 凭据权限 / 订阅目录权限 / 订阅 DNS；`--fix` 自动修权限 |
| 速度体检 | `proxy speed` 只读体检：BBR 与实际 qdisc、默认节点、Brutal 开关、该开哪一项 |
| 诊断报告 | `proxy diag` 一条命令导出系统 / 服务 / 端口 / 网络 / 时间 / 日志，**UUID、密码、token 自动脱敏**，可直接外发求助 |
| 完整性校验 | 三个内核的 SHA-256 写死在脚本里，下载走镜像也对不上就中止（安装与升级都校验） |

---

## 快速开始

在 VPS 上以 **root** 执行（就这一条，每次粘贴都会重新下载最新版）：

```bash
PN_TMP=$(mktemp /tmp/pn.XXXXXXXXXX) && curl -fsSL https://raw.githubusercontent.com/smallji666/proxy-node/main/setup.sh -o "$PN_TMP" && [ -f "$PN_TMP" ] && [ ! -L "$PN_TMP" ] && bash -n "$PN_TMP" && mv -f "$PN_TMP" /root/setup-proxy.sh && chmod 755 /root/setup-proxy.sh && bash /root/setup-proxy.sh
```

这一条命令的四步，每一步都是为了防止「跑的不是最新版」和「把能用的脚本弄坏」：

| 步骤 | 作用 |
|---|---|
| `mktemp /tmp/pn.XXXXXXXXXX` | 随机临时文件名。`/tmp` 全局可写，固定名字会被预置成符号链接，root 下 `curl -o` 会顺着链接截断目标文件 |
| `curl ... -o "$PN_TMP"` | 每次都重新拉 `main` 分支的最新脚本，不存在「还在用老版本」 |
| `bash -n "$PN_TMP"` | 先做语法检查。下载被劫持、文件不完整、拿到错误页，都当场停下 |
| `mv -f ... /root/setup-proxy.sh` | 只有校验通过的文件才会落到正式位置，原子替换，旧的那份不会变成半截文件 |
| `bash /root/setup-proxy.sh` | 执行。脚本自己还会再查一次远端版本，发现更新就自动换成新版继续 |

> 为什么不直接 `curl | bash`：下载成文件再执行，脚本才能把自己软链成 `proxy` 管理命令。
> 管道执行（`curl ... | bash`）部署本身没问题，但**只有在发现远端有更新时**才会把自身
> 落到 `/root/setup-proxy.sh`；版本相同就完全不落盘 —— 磁盘上那份旧 `setup*.sh`
> 一个字节都不会变，`proxy` 命令也不会被创建（安装末尾会明确提示「以管道方式运行」）。
> 要真正做到「每次都拿最新版并留下管理命令」，请用上面这条四步命令。

**旧副本的清理有前提。** 从**文件**运行且安装成功结束时，脚本会扫一遍 `/root`、
`/tmp`、`/usr/local/bin`（最多两层），删掉本项目残留的旧副本；只删同时满足
「文件名像 `setup*.sh`」和「文件里有 `SCRIPT_VERSION=` 与 `Proxy Node Installer`」
两个条件的文件，你自己的脚本和软链不会被碰。管道运行时没有落盘文件，这一步不执行。

脚本还带一个只增不减的**世代号**（`SCRIPT_EPOCH`）：版本号可能重新起算（例如
1.3.x → 1.0.0），光比 x.y.z 会把 1.3.x 的老副本误判成「更新版」保留下来、`proxy update`
也会因「防降级」拒绝升级。世代号让老副本能被正常清理，也让更新链不再被版本号回退卡死。

运行后会先出现部署向导，输入序号即可，不用记任何参数：

```
============================================================
   Proxy Node Installer v1.0.0   ·   部署向导
============================================================

  当前状态: 尚未安装

  选择要部署的协议, 输入编号, 可多选(如 1 2 表示两个都开):

   1) Reality       VLESS + Vision    抗封锁最强, 不需要证书
   2) Hysteria2     UDP 高速          弱网 / 高丢包环境最强
   3) SS2022        Shadowsocks-2022  兼容性最好, 老客户端也能用
   4) AnyTLS        抗主动探测        新一代 TLS 伪装
   5) TUIC v5       低延迟 UDP        基于 QUIC

   6) Reality + Hysteria2             推荐: TCP/UDP 双保险
   7) 全协议                          1~5 全部开启

  ── VPS 优化 (可单独执行, 不装代理也能用) ──────────────────
   8) 一键优化 VPS                    BBR + 内核参数 + swap + 时间同步 + 日志限容
   9) 设置时区                        按机器所在地区设, 别留默认的 UTC

  ── 维护 ────────────────────────────────────────────────────
   c) 清理所有配置                    端口被占用 / 想彻底重来时用
   0) 退出

  请选择 [直接回车 = 6 推荐]:
```

几个约定：

- **可多选**：输入 `1 3` 或 `1,2,5`，会同时开多个协议
- **直接回车** = 6（Reality + Hysteria2，最稳的组合）
- **选 8** 只做 VPS 优化，不进安装流程；优化完回到菜单
- **选 9** 只改时区，不进安装流程
- **选 c** 清干净后回到菜单，接着选协议
- 已装过再进来，若协议组合变了会提示「需要先清理旧实例」，确认后自动 `--clean`

想跳过向导直接装（自动化脚本用）：

```bash
PROTOCOLS=reality,hy2 bash /root/setup-proxy.sh install
```

跑完会打印两套链接和终端二维码，同时把纯文本信息存到 `/root/proxy-info.txt`。

### 部署后必做

**云厂商安全组放行** `TCP 443` 和 `UDP 443`。脚本只能改本机防火墙，改不了云控制台。

---

## 管理命令

安装完成后，任意目录直接输入 `proxy`：

```bash
proxy                # 打开交互菜单
proxy update         # 更新脚本自身（不更新内核，只更新这份 .sh）
proxy update install # 更新后立刻用新版本重新部署
proxy version        # 显示脚本版本与构建日期
proxy wizard         # 部署向导：选协议 / 优化 / 清理
proxy optimize       # 一键优化 VPS（BBR / 内核参数 / swap / 时间同步）
proxy timezone       # 时区菜单（自动匹配 / 亚洲 / 欧洲 / 美洲 / UTC / 手动输入）
proxy info           # 查看节点信息、链接、二维码
proxy name RackNerd  # 改节点备注名（只改客户端显示，不用重装、不用重启）
proxy sub            # 重新生成订阅文件
proxy status         # 服务状态与监听端口
proxy restart        # 重启 xray 与 hysteria2
proxy logs           # 实时日志（proxy logs hy2 看 hysteria2）
proxy audit          # 线路体检：出口 IP / PTR / 时间同步 / 丢包重传 / 客户端清单
proxy speed           # 速度体检，只读不改配置（BBR / 默认节点 / 该开哪项）
proxy selftest       # 逐协议真连一次（用订阅里同一份配置），装完不通先跑这个
proxy diag           # 生成脱敏诊断报告（系统/服务/端口/网络/时间/日志），用不了时贴这个
proxy egress         # 上游出口：接住宅 IP 换掉最终出口（不带参数=查看，off=关闭）
proxy verify         # 安全自检：二进制指纹 / 配置合法性 / 凭据权限 / 订阅 DNS
proxy verify --fix   # 同上，并自动把过宽的权限改回来
proxy user           # 设备凭据：list / add <名字> / link <名字> / rm <名字>
proxy reset          # 重置凭据（会作废所有已导入客户端）
proxy backup         # 打包凭据与证书（迁移用）
proxy restore <文件> # 从备份恢复
proxy install --clean # 清理旧实例后全新安装（端口冲突时用这个）
proxy clean          # 只清理不安装，保留 proxy 命令
proxy upgrade 26.3.27  # 装指定版本（同样做完整性校验）；--rollback 回滚上一版
```

> **关于脚本更新（这一节值得看完）**
>
> `proxy` 跑的是**磁盘上那份脚本文件**。第一次用 `curl -o` 下载之后，如果只敲
> `proxy`，跑的就是下载那一刻的版本——上游修了 bug 也不会自动生效。
>
> 所以现在有两条路，都是自动的：
>
> 1. **重新粘贴一键命令** —— `curl` 每次都会拉最新版，这是最直接的做法
> 2. **任何一条部署入口** —— `proxy install`、`proxy install --clean`、`proxy fresh`、
>    敲 `proxy` 进向导、在菜单里点「重新部署」，动手之前都会先查远端版本，
>    发现更新就下载、`bash -n` 校验、原子替换自己，然后 `exec` 新版继续部署。
>    下载失败或校验不过就退回当前版本继续，不会卡住
>
> 三条校验（语法能过 / 有版本号 / 内容确实是这份脚本）任何一条不过就丢弃下载结果，
> 磁盘上那份永远不会被写坏。装完还会顺手清掉其它位置的旧副本。
>
> 已安装的机器敲 `proxy` 打开菜单**不会**卡在网络上查版本——只有真的要部署时才查。
>
> 断网环境想跳过这一步：`PN_NO_SELFUPDATE=1 proxy install`。
>
> 也可以手动更新：`proxy update`（只更新脚本）或 `proxy update install`（更新后立刻重新部署）。

也可以继续用脚本本身：`bash /root/setup-proxy.sh info`

---

## VPS 优化

优化在安装时自动做一次，也可以**单独执行**（不装代理也能用）：

```bash
proxy optimize          # 全部：BBR + 内核参数 + 句柄数 + 日志限容 + swap + 时间同步
proxy optimize bbr      # 只做网络参数（BBR / fq / 缓冲 / conntrack）
proxy optimize swap     # 只补 swap（已有则跳过）
proxy optimize time     # 只做时间同步（REALITY 对时间偏差敏感）
proxy optimize log      # 只限制 journald 日志体积
```

具体改了什么：

| 项 | 内容 | 为什么 |
|---|---|---|
| 拥塞控制 | `bbr` + `fq` | 弱网/高丢包下比 cubic 吞吐高很多，是提速最明显的一项 |
| 缓冲上限 | `rmem_max` / `wmem_max` 32MB | 要盖过 hysteria 的 8MB/20MB QUIC 窗口，否则内核截断后 UDP 跑不满 |
| 端口范围 | `ip_local_port_range` 10000-65000 | 代理场景短连接多，默认 32768-60999 容易不够用 |
| TIME_WAIT 复用 | `tcp_tw_reuse=1` | 少占端口，重连更快 |
| 长连接 | `tcp_slow_start_after_idle=0` | 视频/直播空闲后不重新慢启动 |
| 小包延迟 | `tcp_notsent_lowat=16384` | 交互类流量更跟手 |
| 并发 | `somaxconn` / `tcp_max_syn_backlog` 8192 | 大量并发连接不被队列丢包 |
| 连接跟踪 | `nf_conntrack_max=65536` | 多设备同时用不会耗尽跟踪表 |
| 句柄数 | `nofile 65535` | 默认 1024 在并发高时是瓶颈 |
| 日志 | journald 上限 100M | 小硬盘机器最容易被日志写满 |
| swap | 无 swap 时补 1GB | 512MB/1GB 内存机器防 OOM |
| 时间 | 启用 `systemd-timesyncd` | REALITY 握手依赖时间，偏差几分钟就失败 |

全部只改系统网络参数，**不动任何已有服务**；`proxy clean` 时这些配置会一起清掉。
---

## 速度与调优

系统层调优这个脚本比多数一键脚本完整（BBR + fq、32MB 收发缓冲、UDP 内存、conntrack、
句柄数、TIME_WAIT 复用）。这里有个容易被忽略的顺序问题，脚本已经处理掉了：

内核参数必须在**任何服务启动之前**生效。`rmem_max` 还是默认 208KB 时如果先起了
Hysteria2 / TUIC，UDP socket 已经按小缓冲建好，事后改 sysctl **不会**扩大已创建
socket 的 `SO_RCVBUF`，QUIC 的 8MB / 20MB 接收窗口被内核钳死 —— 表现就是「刚装完
测速慢，手动重启一次服务后明显好转」。所以安装流程里 `optimize_system` 排在所有
服务启动之前；手动调过参数的机器，记得 `proxy optimize all` 之后再 `proxy restart`。

排除这个之后，剩下的体感差距主要在这三处，都在协议 / 客户端层：

### ① 默认节点走的是 TCP，不是 UDP

默认 `PROTOCOLS=reality,hy2`，两份订阅的默认出口都指向 **REALITY（VLESS over TCP）**：
`clash.yaml` 的 select 组第一项是 VLESS，`singbox.json` 的 `route.final` 是 `vless-out`。
REALITY 抗封锁最强、最稳，但跨境链路一丢包，TCP 的吞吐就掉得厉害；别人的 hy2 一键脚本
默认走 UDP/QUIC，晚高峰体感快很多 —— 这不是脚本写差了，是协议取舍不同。

**先在客户端把节点切到 HY2 测一次**，服务端一个字都不用改。想让两份订阅的默认节点
都直接指向 UDP：

```bash
DEFAULT_NODE=hy2 proxy sub       # 切到 HY2 (UDP, 速度优先)
DEFAULT_NODE=reality proxy sub   # 切回 REALITY (TCP, 抗封锁优先)
```

这个值会写进 `state.env` 沿用。**默认仍是 REALITY，没有改成 UDP**：部分运营商会限速
甚至阻断 UDP，把 UDP 设成全局默认会让这些用户装完就连不上 —— 这种「出错」比慢更糟。
上面的命令只改客户端订阅的默认选中项，REALITY 节点始终还在，随时可切。

**切之前先确认 HY2 这条 UDP 链路真的通。** 只开 `reality,hy2` 时服务端不会安装
sing-box 内核，部署后自检里的 `hy2` 会显示「跳过(缺 sing-box 客户端)」——
这是**没测过**，不是通过；别拿「REALITY 通」推断 hy2 通。最可靠的验证是客户端导入
订阅真连一次；另外 `proxy status` 看 `hysteria-server` 是否在跑、云安全组是否放行了
`UDP 443`（开了 `HY2_HOP` 还要放行端口跳跃区间）。本机回环自检覆盖不到云安全组、
端口跳跃和本地到 VPS 的链路，这几项只能靠客户端实测。跑一遍 `proxy speed`（只读）
会把 BBR 是否真的生效、Brutal 有没有开、默认节点是谁逐项列出来。

### ② Hysteria2 没开 Brutal

Hysteria2 默认用 BBR，在拥塞链路上不会主动抢带宽。官方的 Brutal 拥塞控制「擅长在拥塞的
网络中抢占带宽」，这是与主流 hy2 脚本体感差距最大的一项。

```bash
HY2_BW_UP=50 HY2_BW_DOWN=300 proxy sub
```

- 单位是 **Mbps**，填的是**你本地到这台 VPS 这条链路**的实际上下行，不是 VPS 标称带宽
- 只有 `clash.yaml`（`up` / `down`）和 `singbox*.json`（`up_mbps` / `down_mbps`）会用到；
  `hysteria2://` 分享链接标准没有带宽参数，用链接导入的用户需要改用订阅文件
- 值会存进 `state.env`，之后 `proxy sub` / `proxy install` 都会保留
- 关掉 Brutal 回到默认 BBR：`HY2_BW_UP= HY2_BW_DOWN= proxy sub`（显式留空才会清空已保存的值）
- **服务端不写 `bandwidth`**：官方文档说自建自用可以直接删掉服务端该字段，由客户端指定即可；
  服务端写了反而变成限速（且只限制 Brutal 速率）

> **填错比不填更糟。** 官方原话：设置得高于实际最大值「会因为补偿机制导致连接速度慢、
> 不稳定，且浪费流量」；低于实际值只是相当于限速。所以脚本默认留空＝不开，
> 且只接受 1–10000 的整数，填错只警告并**沿用原有设置**（原本没开就是默认 BBR），
> 不会把已保存的值抹掉，也不会让部署失败。
> 不确定就先别填，或按实测带宽的 **80%** 起步。

### ③ 客户端把国内流量也塞进了代理

`clash.yaml` 带 `GEOSITE,cn` / `GEOIP,CN` 直连规则，国内站点不绕路；
`singbox.json` 是**纯代理配置**，`route.final` 指向节点，国内网站也会出国再回来 —— 慢，
部分国内服务还会直接拒绝境外 IP。需要国内分流就用 `clash.yaml`，或在 sing-box 客户端
自己补规则（脚本不自动加 `geosite` 规则，是因为客户端缺 `geosite.db` 时整份配置会启动失败，
这个代价太大）。

其它按序核对：TUN 的 MTU 填 1500 并关掉「严格路由」；不需要抗封锁时关掉 obfs / 端口跳跃；
单核小机器用 `top` 看 hysteria 是不是吃满一个核。

### 一键体检

```bash
proxy speed
```

只读，不改任何配置。会打印 BBR 是否真生效、当前协议与拥塞控制、两份订阅的默认节点、
Brutal 有没有开，以及该优先动哪一项。

### Xray 移除 `allowInsecure` 对本脚本的影响

Xray-core v26.2.6 移除了 TLS 的 `allowInsecure`，改用 `pinnedPeerCertSha256` /
`verifyPeerCertByName`（分享链接里是 `pcs` / `vcn`）。逐条对照：

| 组件 | 是否受影响 |
|---|---|
| REALITY 主力 | **不受影响**。靠 `pbk` / `sid` 验证身份，配置里没有 TLS `allowInsecure`；v2rayN 维护者明确说「reality 相当于强制要求 pin 证书，原理上不可能 allowinsecure 跳过验证」 |
| 服务端 Xray | **不受影响**。锁的 26.3.27 虽在 v26.2.6 之后，但 inbound 不写 `allowInsecure`（「为什么锁死 26.3.27」讲的是 26.9.8 的 MLKEM 门槛，与此无关） |
| HY2 / AnyTLS / TUIC | 在 v2rayN 里由 **sing-box 内核**承载，用的是 `insecure: true`，不是 Xray 的 `allowInsecure`，**不会**触发「内核无法启动 / 批量测试全 -1」；但新版 v2rayN 会持续提示「不安全」 |
| 订阅里的 `insecure=1` | `v2rayn.txt` / `base64.txt` 仍保留以兼容老客户端；新版 v2rayN 请改用 `v2rayn-safe.txt` |

`pcs` / `vcn` 属于 VLESS/VMess 分享链接标准里给「普通 TLS + allowInsecure」节点用的参数，
本脚本没有这类节点；HY2/AT/TUIC 的 URI 也不属于该标准，硬加不会被识别。脚本早已用
`pinSHA256`（整证书 SHA-256 hex）、`certificate_public_key_sha256`（SPKI base64）、
mihomo `fingerprint` 三种指纹做真固定，方向比「跳过验证」更靠前。

---

## 时区

**时间同步和时区是两件事，别混在一起看：**

| | 作用 | 对 REALITY / TLS 的影响 |
|---|---|---|
| NTP 同步（`optimize time`） | 把系统 UTC 时钟校准准确 | **必须准确**，偏差超过几分钟握手就失败 |
| 时区（`proxy timezone`） | 只决定 `date` 和日志显示成哪个地区的时间 | **没有影响**，TLS 校验用 epoch 秒，与时区无关 |

脚本**不会**擅自改时区——装完是什么时区就还是什么。要改：

```bash
proxy timezone        # 菜单：自动匹配 / 亚洲 / 欧洲 / 美洲 / UTC / 手动输入
proxy timezone auto   # 直接按出口 IP 自动匹配
proxy timezone Asia/Tokyo
```

**原则是「机器在哪就设哪」，不是「一律设美国」。** 自动匹配会依次试三家 IP 库
（`ip-api` → `ipinfo` → `ipwho.is`），任何一家给出合法时区就用，并且只接受本机
`/usr/share/zoneinfo` 里真实存在的名字——接口返回脏数据不会写进系统。

菜单没列到的地区用「手动输入时区名」，写 `大洲/城市` 即可（`Asia/Tokyo`、
`Europe/Berlin`、`America/Sao_Paulo`）。查可用名字：

```bash
timedatectl list-timezones | grep -i tokyo
```

### VPS 时区会被 TikTok 识别吗

不会。代理只转发 TCP/UDP 字节流，VPS 的系统时区不会出现在任何报文里。
TikTok 判断地区靠的是：**客户端出口 IP、设备时区 / 语言 / 地区设置、SIM 卡、GPS、行为特征**。

所以：

- VPS 时区设成机器所在地，主要是让**你自己看日志更直观**（东京机器按东京时间记日志，
  对日志不会对错时间），对风控没有实质影响
- `proxy audit` 里那条「时区一致性」也是这个定位：对不上只提示一句，不当作风险
- 真正要改的是**手机或模拟器上的时区**（连同语言、地区、App 内地区设置），这部分脚本管不到
- 服务端能做的只有三件：给一个干净的 IP、禁 IPv6 泄漏、把 UTC 时间校准准

---

## 多设备凭据

每台设备用独立 UUID，而不是全家共用一个：

```bash
proxy user                 # 列出所有凭据
proxy user add iPhone      # 新增，直接打印这台设备的链接
proxy user link iPhone     # 取回已有设备的链接
proxy user rm iPhone       # 吊销，这条链接立即失效
```

好处是**丢设备时只吊销那一条**，其他设备不受影响。`proxy reset` 则是核弹，全部作废。

凭据存在 `/etc/proxy-node/users.txt`（权限 600），格式 `UUID|名字|日期`。
订阅文件取第一条凭据，所以删掉第一条时订阅会自动换用新的第一条，不会失效。

增删设备时会同时重载 Xray 和 sing-box —— 只重载 Xray 的话，新设备在
AnyTLS / TUIC / SS2022 上进不来，被吊销的设备也还能继续用这三个协议。

### SS2022 的密码为什么有两段

SS2022 走的是 sing-box 的多用户模式，客户端密码必须是**两段**：

```
服务端密钥:设备密钥        # 例：8JCsPssfgS8tiRwiMlhARg==:PCD2Z4o12bKUoFa3cC97Hw==
```

两段都是 base64 的 16 字节密钥，冒号分隔。只填设备密钥会被服务端直接拒掉，
表现为「配置看着没错，但一连就断」。

这是 sing-shadowsocks2 的实现决定的：`NewMethod` 里对密码做
`strings.Split(password, ":")` 得到密钥列表，列表长度大于 1 才走 EIH 多用户模式。
脚本生成的 `ss://` 链接、`clash.yaml`、`singbox.json` 里都已经拼好了这两段，
`proxy user link <名字>` 也会直接给出完整链接，不需要手工拼。

---

## 端口被占用 / 重装

重装最常卡在端口上：上次的服务没停干净，或者 `/etc/proxy-node` 删了但进程还在跑。

清理已经内嵌进安装流程，不用先手动清：

```bash
bash /root/setup-proxy.sh install            # 正常重装：幂等，凭据不变
bash /root/setup-proxy.sh install --clean    # 清理旧实例后全新安装（换新凭据）
bash /root/setup-proxy.sh fresh              # 同上，短写法
```

`install` 会先做一次残留检测，分三种情况：

| 机器状态 | 行为 |
|---|---|
| 有 `state.env`（正常装过） | 直接原地重部署，只提示一句“要全新安装请加 `--clean`”，不打扰 |
| 无 `state.env` 但有残留文件 | 判定为残缺安装，列清单并问是否清理；`ASSUME_YES=1` 或无 tty 时自动清理 |
| 完全没有残留 | 全新安装 |

端口真被外部进程占着时，会报出占用者名字并问你：是清掉本脚本的残留实例，还是结束那个进程，或者换端口。

菜单里也有对应入口：`f) 清理并全新安装`。只想清不装：

```bash
proxy clean            # 保留 proxy 命令，方便随后重装
proxy clean --all      # 连管理命令和脚本一起删
```

`clean` 依次做：停并禁用相关服务（含旧版 `hysteria.service`）→ 删 systemd unit →
杀残留的 xray/hysteria 进程 → 枚举清掉**所有**端口跳跃 iptables 规则（不只是 state 里当前那段）→
撤回本脚本在 ufw/firewalld 里放行过的端口 → 删配置/凭据/订阅目录 →
还原 sysctl / 句柄数 / journald → 复查端口是否真空了。

**只删本脚本创建的东西**，不动系统里其它服务；swap 会保留（不影响重装）。

## 备份与迁移

```bash
proxy backup                       # → /root/proxy-backup-20261031-160000.tar.gz
proxy restore /root/xxx.tar.gz     # 在新机器上执行
```

备份含 `state.env`、`users.txt`、Hysteria2 证书与私钥、`proxy-info.txt`，打包后权限 600。

换 VPS 时 **UUID、x25519 密钥、Hysteria2 密码、证书全部沿用**，客户端只需要把服务器地址改成新 IP
（或重新导入订阅），协议参数不用重配。`restore` 会自动重新探测公网 IP 并重生成链接——
IP 变了旧链接本来就连不上，但凭据本身不变。

---

## 线路体检

```bash
proxy audit            # 常规体检
proxy audit --dnsbl    # 额外查反垃圾库（会把 IP 提交给 Spamhaus）
```

检查项：

| 项目 | 说明 |
|---|---|
| **隧道出口 IP** | 真的走一遍 REALITY 隧道去查，与本机 IP 对比，能发现中转和泄漏 |
| **PTR 反向解析** | 没有 PTR 记录会提高风控可疑度 |
| **公网 IPv6** | 有公网 IPv6 就意味着存在泄漏面 |
| **时间同步** | REALITY 依赖时间校验，未同步会握手失败 |
| **系统状态** | 拥塞控制、日志占用、磁盘、内存 |
| **客户端清单** | WebRTC / IPv6 / DNS / 时区 / 一号一 IP 等自查项 |

出口 IP 那一项值得单独说：它不是读本机 IP 糊弄你，而是**临时起一个本地客户端走完整 REALITY 握手**，
再通过隧道访问 IP 回显服务。如果结果和本机 IP 不一致，说明链路中间有东西，TikTok 看到的是另一个地址。

---

## 协议选择

默认只装两种（`reality,hy2`），其余按需加。`PROTOCOLS` 用逗号分隔：

```bash
PROTOCOLS=reality,hy2,ss2022 bash /root/setup-proxy.sh install
PROTOCOLS=reality,hy2,anytls,tuic bash /root/setup-proxy.sh install
PROTOCOLS=ss2022 bash /root/setup-proxy.sh install        # 只装一个也可以
```

| 协议 | 内核 | 端口默认 | 适合什么 |
|---|---|---|---|
| `reality` | Xray | TCP 443 | 主力。借用真实站点证书，抗封锁最强，不需要你有域名 |
| `hy2` | hysteria | UDP 443 | 备用。UDP 抗丢包，弱网、跨境视频更稳 |
| `ss2022` | sing-box | TCP+UDP 8445 | 兼容兜底。老客户端、路由器、IoT 设备基本都认 |
| `anytls` | sing-box | TCP 8444 | 新协议。TLS 内多路复用，流量特征接近普通 HTTPS |
| `tuic` | sing-box | TCP+UDP 8443 | UDP 系，BBR 拥塞控制，晚高峰表现好 |

后三个由同一个 sing-box 进程承载，装几个都只占一个进程。

**`PROTOCOLS` 就是最终状态，不是"追加"**：重装时少写一个协议，对应的服务会被
`disable --now` 停掉（配置和凭据保留，重新写回去就恢复）。以前只加不减，结果是
`state.env` 里已经没有 hy2、订阅也不列它、`proxy status` 不显示它，但进程和 UDP 端口
还开着 —— 多一个没人看管的对公网端口，比没装更糟。

**端口别撞**：扩展协议默认从 8443 起，避免和 REALITY 抢 443。要改就一起改：

```bash
SS2022_PORT=9445 ANYTLS_PORT=9444 TUIC_PORT=9443 bash /root/setup-proxy.sh install
```

**证书固定在这几个扩展协议上有区别**：AnyTLS / TUIC 用自签证书，它们的分享链接
（`anytls://`、`tuic://`）标准里没有证书指纹字段，只能 `insecure=1`；**SS2022 没有 TLS，
根本不需要证书固定**，别把它和前两个混为一谈。真正固定证书的是订阅里的
`singbox.json`（1.13+，`certificate_public_key_sha256`），1.12 用 `singbox-compat.json`
（走 `insecure`）。`clash.yaml` 里**只有 Hysteria2 一条**带 `fingerprint`，AnyTLS / TUIC
仍是 `skip-cert-verify: true`，不要以为整份 clash 订阅都已固定证书。
这一点 `client-guide.md` 里也写了。

## 环境变量

首次安装时通过环境变量定制，安装后写入 `/etc/proxy-node/state.env` 复用：

| 变量 | 默认 | 说明 |
|---|---|---|
| `PROTOCOLS` | `reality,hy2` | 协议组合，可选 `reality` `hy2` `ss2022` `anytls` `tuic` |
| `VLESS_PORT` | `443` | VLESS 监听 TCP 端口 |
| `SS2022_PORT` | `8445` | Shadowsocks-2022 端口（TCP+UDP） |
| `ANYTLS_PORT` | `8444` | AnyTLS 端口（TCP） |
| `TUIC_PORT` | `8443` | TUIC v5 端口（TCP+UDP） |
| `HY2_PORT` | `443` | Hysteria2 监听 UDP 端口（可与 TCP 443 共存） |
| `REALITY_DEST` | 自动 | 伪装目标站，留空则自动挑选并验证；填 `random` 强制重新随机挑一个 |
| `ENABLE_OBFS` | `0` | `1` 开启 Hysteria2 salamander 混淆 |
| `HY2_HOP` | 空 | 端口跳跃区间，如 `20000-30000` |
| `HY2_INSECURE` | `0` | `1` 关闭证书固定、退回 `insecure`，**仅调试用** |
| `HY2_BW_UP` / `HY2_BW_DOWN` | 空 | Hysteria2 Brutal 带宽（Mbps），空＝官方默认 BBR，见「速度与调优」 |
| `DEFAULT_NODE` | `reality` | 客户端默认节点：`reality`(TCP 稳) 或 `hy2`(UDP 快)；只改订阅，不改服务端 |
| `SUB_HTTP` | `0` | `1` 起一个订阅 HTTP 服务 |
| `SUB_PORT` | 随机 | 订阅 HTTP 端口 |
| `SUB_BIND` | `127.0.0.1` | 订阅服务监听地址；改成 `0.0.0.0` 才会对公网开放 |
| `NODE_NAME` | 自动识别 VPS 厂商 | 节点名（订阅与链接里的显示名）。反查只能到机房，转售商要手动填，见下文 |
| `XRAY_VERSION` | `26.3.27` | Xray 版本，**不建议改动**，见下文 |
| `HY2_VERSION` | `2.13.0` | Hysteria2 版本，固定值（内置哈希与之一一对应） |
| `ALLOW_UNVERIFIED_BIN` | `0` | `1` 跳过二进制完整性校验，**仅自定义版本时用** |
| `CLEAN` | `0` | `1` 安装前先彻底清理旧实例（等同 `install --clean`） |
| `ASSUME_YES` | `0` | `1` 全程不询问 |
| `EGRESS_URL` | 空 | 上游出口代理（住宅 IP / 中转机），也可用 `proxy egress` 设置 |
| `PN_NO_SELFUPDATE` | `0` | `1` 部署前不做自动更新（断网环境 / 复现旧版行为时用） |

示例：

```bash
# 换端口 + 开混淆 + 开端口跳跃
VLESS_PORT=8443 HY2_PORT=8443 ENABLE_OBFS=1 HY2_HOP=20000-30000 \
  bash /root/setup-proxy.sh install

# 指定伪装站（会先验证握手，不通过会自动换下一个）
REALITY_DEST=www.samsung.com bash /root/setup-proxy.sh install

# 重新随机挑一个伪装站（已装好的机器想换 SNI 用这个）
# 注意：SNI 写在订阅链接里，换完客户端要重新导入
REALITY_DEST=random bash /root/setup-proxy.sh install
```

> 换伪装站时，hysteria2 与 sing-box 的**自签证书会跟着重签**（CN 与新站一致）。
> 证书不能只在「文件不存在」时生成：换了站 CN 还是旧的，配置里的 `server_name`
> 与证书 CN 对不上，主动探测一比对就是破绽。

### 节点备注名怎么来的

不指定 `NODE_NAME` 时，安装过程会用出口 IP 反查 VPS 厂商，把节点备注命名成「厂商-协议」：

```
DigitalOcean-VLESS
Hetzner-HY2
Vultr-SS2022
```

这样客户端里同时挂着好几台机器时，一眼就能看出哪条是哪台，不用记 IP。

探测顺序：`ip-api.com` 的 `isp` 字段 → 同一响应的 `as`（组织名）→ `ipinfo.io` 的 `org`。
拿到组织名后做一次清洗：去掉 `AS` 号、取第一个有意义的词、跳过 `LLC` `Inc` `GmbH` 之类的法律后缀、
去掉 `.com` 尾巴，再对少数几家做统一映射（`The Constant Company` → `Vultr`、`Amazon.com` →
`AWS`、`CHINANET-BACKBONE` → `ChinaTelecom` 等）。

#### 认出上游机房是正常的，那不一定是你买的那家

反查只能查到**这段 IP 登记在谁名下**，查不到**你把钱付给了谁**。转售商自己没有 ASN，
机器和 IP 都从批发商那里租，所以在 IP 注册信息里根本不会出现：

| 你实际买的 | 反查会得到 |
|---|---|
| RackNerd、CloudCone、AlphaVPS 等 | `HostPapa`（AS36352，原 ColoCrossing，2023 年被 HostPapa 收购后改名） |
| Psychz / QuadraNet 下游的各类小商家 | `Psychz` / `QuadraNet` |

所以 RackNerd 的机器装完会显示 `HostPapa-HY2`。这不是识别错了，是数据源的天花板。
脚本认出这类批发商时会明确提示「这是机房，不一定是卖你机器的商家」，改一下就行：

```bash
proxy name RackNerd
```

改名只动客户端显示，不碰任何服务端配置，**不用重装也不用重启内核**；链接和订阅文件会一起重写，
客户端重新导入一次即可。也可以装的时候直接指定，一步到位：

```bash
NODE_NAME=RackNerd bash /root/setup-proxy.sh install
# 结果: RackNerd-VLESS / RackNerd-HY2
```

识别不出来（IP 属于保留段，或 ASN 只有一个编号没有名字）时会保留默认的 `Node`，
并在安装日志里提示可以手动指定。

> 备注名会写进 `state.env`，后续重装、改协议、加设备都沿用同一个名字；想把老机器的 `Node`
> 换成厂商名，重跑一次 `install` 即可（仅在当前值仍是 `Node` 时才会重新识别）。

---

## 订阅文件

默认输出到 `/var/www/proxy-sub/<随机token>/`：

```
links.txt           原始链接（每条节点一行）
base64.txt          通用订阅，小火箭 / v2rayN / v2rayNG 直接导入
clash.yaml          Clash / mihomo / Clash Verge（含 fake-ip + 国内分流）
                     ※ 含 AnyTLS 节点时需 mihomo ≥ 1.19；旧内核会整份加载失败，
                       这种客户端请改用 singbox.json / singbox-compat.json
singbox.json        sing-box 1.13+（含证书指纹真固定）
singbox-compat.json sing-box 1.12（DNS 格式相同，证书走 insecure）
v2rayn.txt          v2rayN 兼容版（含 HY2/AT/TUIC，新版会提示"不安全"）
v2rayn-safe.txt     v2rayN 推荐版（只含 REALITY / SS2022，无跳过证书验证）
                     ※ 只开 hy2 / anytls / tuic 时不生成这个文件
client-guide.md     客户端配置指南（证书固定 / TUN 参数 / 防送中 / 提速 / 排障）
```

### sing-box 为什么有两份

sing-box 的配置格式在 **1.11 ~ 1.14 之间连改了三次**，老格式在新版上是硬错误，不是警告：

| 版本 | 变更 |
|---|---|
| 1.11 | `dns-out` outbound 弃用 |
| 1.12 | `dns.servers[].address` 弃用，新增 `route.default_domain_resolver`；`certificate_public_key_sha256` **还不存在** |
| 1.13 | `dns-out` outbound **移除**，DNS 劫持改用 `action: hijack-dns` |
| 1.14 | `dns.servers[].address` **彻底移除** |

实测在 1.14.4 上：用旧格式直接 `FATAL` 拒绝启动。所以按版本生成两份，
选错时报错信息很不好懂：

- 新版客户端误用 legacy → `legacy DNS server formats ... removed in sing-box 1.14.0`
- 1.12 客户端误用 pinned → `unknown field "certificate_public_key_sha256"`

| 文件 | 内核版本 | 证书校验 |
|---|---|---|
| `singbox.json` | 1.13 及以上 | `certificate_public_key_sha256` 真固定自签证书 |
| `singbox-compat.json` | 1.12（1.13/1.14 也能用） | `insecure: true` |

**sing-box 1.11 及更早不认 1.12 起的新 DNS 格式**，导入会直接报配置错误，
这类版本请改用 `clash.yaml`（mihomo 内核）。

先执行 `sing-box version` 看版本号再选。

> 这两份配置都用官方 1.12.0 / 1.13.0 / 1.14.4 三个二进制实跑验证过
> （`sing-box check` + `sing-box run` 启动），不是照文档猜的。
> 启动这一步尤其关键：`check` 过不代表能起得来 —— 空 `direct` 出站被
> `detour` 引用时会 `check` 通过、运行时才 `FATAL`。

加 `SUB_HTTP=1` 会起一个静态 HTTP 服务提供订阅链接。默认**只监听 `127.0.0.1`**，
手机/电脑取订阅先建 SSH 隧道：

```bash
ssh -N -L <端口>:127.0.0.1:<端口> root@<服务器IP>
# 然后访问 http://127.0.0.1:<端口>/<token>/clash.yaml
```

想让客户端直接拉公网地址就设 `SUB_BIND=0.0.0.0`。但那样 token 就是唯一凭据，
而且走的是明文 HTTP，只建议在受控网络里用。

**订阅服务只响应 `/<token>/<已知文件名>`，其余一律 404，不列目录。**
这一点很关键：早前用的是 `python3 -m http.server`，它会在根路径返回目录列表，
而目录名就是 token —— 任何人扫到这个端口，`GET /` 一次就能拿到全部凭据。
现在换成自带的 40 行小服务（`/usr/local/lib/proxy-sub/server.py`），
带文件名白名单和目录穿越防护。不需要时：

```bash
systemctl disable --now proxy-sub
```

---

## 系统要求

- Debian 11/12、Ubuntu 20.04+、CentOS/Rocky/AlmaLinux 8+
- x86_64 或 arm64
- 内存 512MB 以上（脚本会自动加 1GB swap）
- 能访问 GitHub（脚本内置两个加速镜像作为备用源）

---

## 设计取舍

### 为什么锁死 Xray 26.3.27

Xray 从 **v26.9.8** 起，要求 REALITY 握手的 ClientHello 中首个 `key_share`
必须是 `X25519MLKEM768`（0x11ec），单纯 X25519 只能后置。

| 客户端 | 能否发出该 key_share | 结果 |
|---|---|---|
| v2rayN / v2rayNG（Xray 官方内核） | 可以 | 正常 |
| mihomo / Clash Meta 系（新版） | 需显式开启 | 加 `reality-opts.support-x25519mlkem768: true` |
| **Shadowrocket（小火箭）** | **不能，且无此开关** | **握手失败，开关变绿但打不开网页** |

因为小火箭是大量 iOS 用户的主力客户端，脚本固定使用 26.3.27（门槛之前），
这样所有客户端都能连、都不需要额外开关。

需要升级时脚本提供了 `proxy upgrade`，但会先打印警告并要求确认。

### 为什么用自签证书 + 指纹固定，而不是申请证书

Hysteria2 基于 QUIC，必须走完整 TLS 握手，所以需要一张证书；而裸 IP 签不出公共 CA 证书。

常见做法是勾"跳过证书验证"，但那等于**完全不验证对端身份** —— 链路上任何人都能冒充服务器，
拿走你的密码和全部明文域名。这是这个脚本早期版本的问题，现在已经改掉。

正确做法是**指纹固定**：跳过 CA 链校验，但要求"对端证书的哈希必须等于我记下的值"。
指纹只能来自你这台服务器，中间人换不掉，安全性等同于正式证书，且不需要域名、不需要续期。

> **`insecure: true` 和 `pinSHA256` 必须同时出现。**
> 前者只负责跳过自签证书的 CA 校验（否则连接根本建立不起来），
> 后者才是真正的身份校验。这不是折中，是 hysteria2 官方 `hysteria cert` 命令给出的标准配置。

指纹的算法也被固定下来了，不再靠猜：

- **hysteria2 的 `pinSHA256` = 整张证书 DER 的 SHA-256，64 位小写十六进制**（不是 SPKI，不是 base64）
- **sing-box 的 `certificate_public_key_sha256` = SPKI 公钥的 SHA-256，base64**（另一个字段，另一种算法）

这两个值脚本都会算，客户端按自己的字段填，别混用。

| 客户端 | 字段 |
|---|---|
| hysteria2 链接 / 官方客户端 | `insecure=1` + `pinSHA256=<64位hex>`（脚本自动带上） |
| sing-box | `tls.certificate_public_key_sha256`（SPKI base64） |
| mihomo / Clash | `skip-cert-verify: false` + `fingerprint: <64位hex>` |

> 注意：v2rayN 7.x 的 Hysteria2 界面只有"跳过证书验证"一个勾选框，没有指纹字段，
> 链接里的 `pinSHA256` 会被它忽略（7.24 二进制中查无此参数）。所以脚本会**额外打印一条
> v2rayN 兼容链接**（带 `insecure=1`），导入后能连但拿不到身份验证。
> 想真正固定指纹，用 Clash Verge Rev（mihomo 支持 `fingerprint`）或 sing-box。

### 伪装目标站黑名单

| 域名 | 原因 |
|---|---|
| `cloudflare.com` / `1.1.1.1` | Anycast CDN 边缘，TLS 在 CDN 侧终结，`session_id` 回显不稳定；证书链被海量站点共用，伪装反而更假 |
| `apple.com` / `icloud.com` | Xray 官方警告：用作目标站易导致 IP 被封 |
| `microsoft.com` | 不回显 `session_id`，REALITY 握手直接失败 |
| `dl.google.com` / `google.com` / `youtube.com` | 这些域名在国内本身就被墙。正常中国用户不会主动连，GFW 看到 `SNI=dl.google.com` 反而更容易把连接挑出来 |

这类问题光看「网站能不能访问」发现不了 —— 微软站 curl 返回 200、TLS 1.3 也支持，
但 REALITY 就是握手不过。所以脚本会真的起一个本地客户端做完整握手，通了才算数。

#### 候选站怎么挑的

只用**国内能直连**的大站。`dest` 被墙的话，客户端连发 `ClientHello` 都过不了 GFW，
后面的握手再完美也没意义。然后按三档排序：

| 档位 | 条件 | 处理 |
|---|---|---|
| 优先 | TLS 1.3 + H2 | 直接用 |
| 备选 | 只有 TLS 1.2 + H2 | 前面都失败才用，会提示抗探测略弱 |
| 兜底 | TLS 探测无结果 | 不淘汰，交给后面的真实握手判定 |
| 排除 | 不支持 H2 / 不可达 / 套了 Cloudflare / 在黑名单 | 跳过 |

探测用一次 `openssl s_client -alpn h2` 同时拿到 TLS 版本和 ALPN 结果，
输出里有二进制（session ticket），所以要先落文件再 `grep -a`，不能直接塞进 `$()`。

**档内按 TLS 握手耗时排序，但只在前三名里随机。**

三个做法各有问题，这是折中：

| 做法 | 问题 |
|---|---|
| 固定取最快的那个 | 候选池是写死的，全网几十万台机器都取第一 → SNI 全集中到同一个域名，统计「哪些机房 IP 在跟这个站握手但 ASN 对不上」就能整段捞出来 |
| 纯随机 | 明明有个 20ms 的站，随机到 300ms 的那个，未认证探测被回落时体验白差一截 |
| **前三名内随机** | 既不会全网聚集，也不会选到慢站 |

耗时取的是 `time_appconnect - time_namelookup`，即 **DNS 之后到 TLS 完成**那段 ——
排除 DNS 缓存抖动，剩下的才是「探测方真正等的时间」。测不到耗时的站填 `9999`
排到本档最后，但不淘汰（探测失败 ≠ 站点不能用）。

前三名真实握手都失败时，按耗时顺序继续试本档剩下的，不会因为「没被随机到」
就丢掉一个 TLS 1.3 的站、转头去试 TLS 1.2 的。

> `www.bing.com` 从国内节点看经常只有 TLS 1.2，从境外 VPS 上看可能是 1.3 ——
> 这个探测在 VPS 上跑才有意义，结果会随地理位置变。

### 为什么没启用 VLESS Encryption

Xray 新版支持给 VLESS 头部加密（`"decryption": "mlkem768x25519plus.native.600s.xxx"`），
能消除 TLS-in-TLS 的特征，理论上抗检测更强。

但它要求**客户端也支持**。Shadowrocket 目前不支持，启用后手机直接连不上。
对一个以「iOS 小火箭能用」为前提的脚本来说，这是负收益。

如果你的客户端是 v2rayN 新版或 sing-box，可以自己改 `decryption` 字段尝鲜。

### 为什么不做 WARP / Argo

- **WARP 出站**：出口 IP 会变成 Cloudflare WARP 段，被大量滥用者共用，风控判定比普通机房 IP 更差
- **Argo 隧道**：依赖 CF 域名、绕行边缘节点增加延迟；它的价值是 IP 被封后的保命通道，平时属于多余依赖

这两项属于「特定场景才需要」的能力，默认不做；协议本身已经支持 5 种（Reality / Hysteria2 / SS2022 / AnyTLS / TUIC v5），
用 `proxy wizard` 按需勾选，不必为用不上的协议承担故障面。

---

## 安全说明

- 脚本**不含任何硬编码凭据**，UUID、x25519 密钥、shortId、Hysteria2 密码全部在服务器本地生成
- 不向任何第三方上报信息；公网 IP 优先从本地路由表读取，读不到才查询公共 IP 回显服务
- 反垃圾库查询（`proxy audit --dnsbl`）**默认关闭**，因为它会把 IP 交给第三方 DNSBL，需要你显式开启
- Hysteria2 使用自签证书 + 指纹固定：`insecure` 只负责跳过 CA 校验，身份由 `pinSHA256`（整证书 SHA-256）保证；订阅里带的是公开指纹，不是私钥
- 设备凭据独立存放于 `/etc/proxy-node/users.txt`（600），每条可单独吊销
- systemd 单元启用沙箱：`NoNewPrivileges`、`PrivateTmp`、`ProtectHome`、`ProtectKernelTunables`、
  `RestrictAddressFamilies` 等，服务被攻破后能动手的范围被压到最小
- 订阅 HTTP 服务只响应 `/<token>/<白名单文件名>`，且对 token 做常量时间比较
  （`hmac.compare_digest`），不是只靠「目录名难猜」；其余请求一律 404，绝不列目录
- 用户输入先过清洗再落盘：`state.env` 是会被 `source` 的，备注名里的单引号、反引号、
  美元符号、分号、管道符等会被剔除，伪装站 `REALITY_DEST` 必须是合法域名，
  避免写坏配置或被当成命令执行
- 脚本自更新有多道校验：语法、体积下限、版本号、身份标记、版本/世代号一致；任何一道不过都丢弃下载件
- 部署日志：`/var/log/proxy-deploy.log`

### 下载的二进制怎么保证没被换过

这是整条链路里唯一「从外面拿东西」的环节，也是唯一可能被投毒的地方：

| 组件 | 版本 | 校验方式 |
|---|---|---|
| Xray | 26.3.27 | 内置 SHA-256（取自官方 `.dgst`） |
| Hysteria2 | 2.13.0（固定，不再用 `latest`） | 内置 SHA-256（取自官方 `hashes.txt`） |
| sing-box | 1.14.4 | 内置 SHA-256（官方不发校验文件，由本脚本实测后固定） |

**为什么哈希要写死在脚本里**：下载失败会退回 `ghfast.top` / `gh-proxy.com` 这类第三方镜像。
如果只是「镜像给的哈希 vs 镜像给的文件」，两个都能被同时替换，等于没校验。只有期望值写死在脚本里，
镜像投毒或中间人换包才会在**安装前**就失败，而不是装上一个后门。

校验不通过会直接中止并打印期望值/实际值，不会「警告一下继续装」。
用自定义版本号（如 `XRAY_VERSION=26.9.8`）时没有对应哈希，默认也会中止；
确认来源可信后再加 `ALLOW_UNVERIFIED_BIN=1` 放行。

### 凭据在磁盘上的可见范围

- 全局 `umask 077`：新建文件默认只有 root 可读
- `/usr/local/etc/xray/config.json` 600 —— 里面是**全部设备的 UUID**，就是凭据本身。
  默认 022 会留下 644，同机任何用户都能读走，这是之前版本的一个真实漏洞
- `/etc/proxy-node/state.env` 600、`/root/proxy-info.txt` 600、Hysteria2 私钥 600
- 自测用的临时配置（含 UUID / hy2 明文密码）不再写 `/tmp/_hc.yaml` 这种可预测路径，
  改成 `mktemp -d` 或 0700 的 `/run/proxy-hc`：既防同机用户读，也防预先做成软链接
- **订阅目录**：默认 `SUB_HTTP=0` 时目录 `700` / 文件 `600`，同机普通用户读不到。
  只有真的开了 HTTP 服务（以 `nobody` 运行）才需要 `755` / `644` —— 此时**同机任何用户
  都能读到订阅里的 UUID 与密码**，token 只防网络扫描、不防同机用户。`proxy verify`
  会按当前 `SUB_HTTP` 判断并报出异常放开的权限
- 订阅 HTTP 服务以 `nobody` 运行（`ProtectSystem=strict`、只留 `CAP_NET_BIND_SERVICE`），
  只读几个静态文件，没有任何理由用 root

### 会主动拦住你的错误

- 端口不是 1-65535 的整数、或两个协议撞同一个 TCP/UDP 端口 → 安装前中止
- 机器上已有**别的脚本/你手工装的** xray / hysteria / sing-box（没有 `/etc/proxy-node`
  等本脚本标记）→ 只提示端口冲突，**不会**自动删除；`ASSUME_YES=1` 的非交互安装同样不删
- 端口写成 `0443` 这种带前导零的形式 → 自动归一化成 `443`（JSON 不允许前导零，否则内核读不进配置）
- 设备名 / 节点备注里带 `"` 或 `\` → 清洗掉，不会让 `clash.yaml`、`singbox.json` 变成非法配置
- 写完 Xray 配置后强制 `xray run -test`，写完 sing-box 配置后强制 `sing-box check`，不过就停
- `disable_ipv6=1` 的机器上 sing-box 自动改用 `0.0.0.0` 监听，不会三个协议一起起不来

### 装完之后还能自己查

```bash
proxy verify          # 只检查，不改动
proxy verify --fix    # 顺手把过宽的权限改回来
```

五项检查：

1. **二进制指纹** —— 安装时把 xray / hysteria / sing-box 的 sha256 记进 `state.env`，
   之后每次自检重新算一遍。机器被人动过、内核被替换，这里会直接标红（基准 vs 当前）。
2. **配置合法性** —— 现场跑 `xray run -test` 和 `sing-box check`，配置被人手改坏了能立刻发现。
3. **凭据权限** —— 逐个核对 `config.json`（600）、`state.env`（600）、`users.txt`（600）、
   私钥（600）、状态目录（700），并用 `find -perm /o+r` 扫状态目录；订阅目录按 `SUB_HTTP`
   判断：没开 HTTP 却对其它用户可读就报「泄露」，`--fix` 会收成 600。
4. **服务状态** —— 四个 unit + 健康检查定时器是否还在跑；配置里已经不需要、却仍在
   运行的服务会标「多余」（多一个对公网端口，执行 `proxy restart` 即可收掉）。
5. **订阅 DNS** —— 查订阅目录里的 `clash.yaml` 有没有 `enhanced-mode: fake-ip`、
   `singbox.json` 有没有接管 DNS。**老用户升级后旧订阅还在用**，这一步能直接报出来，
   提示重跑 `proxy sub`。

退出码 0 表示全过，非 0 表示有问题，可以挂到自己的巡检脚本里。

> `--fix` 只自动修权限一类的问题（把过宽的 `chmod` 收回去），
> 配置非法、服务没起来、订阅缺 DNS 这几类仍然会标红，不会被 `--fix` 一起抹掉。

### 升级路径同样校验

`proxy upgrade` 不能直接下 `/releases/latest/download/` —— 那等于绕开安装时的校验，
前面修得再严，一条升级命令就能装进被换过的内核。这里的做法：
`latest` 先用 GitHub API 解析成确切版本号，再按版本查内置哈希，对不上就中止。
解析失败会提示你直接指定版本（`proxy upgrade 26.3.27`）。

> 脚本里只写死了 26.3.27 / 2.13.0 / 1.14.4 三个版本的哈希。装**别的**版本会停下并
> 打印下载文件的 sha256，要你拿它和官方 release 页核对；一致后加
> `ALLOW_UNVERIFIED_BIN=1 proxy upgrade <版本>` 才会继续。升级成功后 `XRAY_VERSION`
> 会一起写回 `state.env`，否则下一次 `install` / `restore` 会把内核静默下回旧版本。

### systemd 单元再收一层

除了原有的 `NoNewPrivileges` / `PrivateTmp` / `ProtectHome`，三个内核服务都补上了：

- `ProtectSystem=full`：`/usr`、`/boot`、`/etc` 一律只读，服务只收发流量，不需要写系统
- `ProtectClock` / `ProtectHostname` / `ProtectProc=invisible`：不能改时钟、主机名，看不到别人的进程
- `RestrictNamespaces` / `SystemCallArchitectures=native` / `UMask=0077`

健康检查的 oneshot 也进了沙箱。**刻意没加 `ProcSubset=pid`**：它会把 `/proc/net` 一起隐藏，
`ss` 就读不到端口表，健康检查会误判成"端口未监听"然后每 5 分钟重启一次服务。

### 这个脚本做不到的事（别指望它）

说清楚边界，比堆一堆「已加固」更有用：

- **VPS 服务商始终在你的信任链上游**。它有 hypervisor 权限，能读内存、能快照磁盘，
  root 密码也经过它。脚本能防的是同机普通用户（前提是 `SUB_HTTP=0`）、网络中间人、
  镜像投毒，防不了机房；开了订阅 HTTP 时同机用户也在信任链内。
- **订阅走的是明文 HTTP**。默认只监听 `127.0.0.1`，取订阅要 SSH 隧道；一旦你把
  `SUB_BIND` 改成 `0.0.0.0`，token 就是唯一凭据，链路上谁都能看到——要公网就自己套一层 TLS 反代。
- **客户端是否真的用了指纹固定**，服务端管不了。用 `insecure=1` 且忽略 `pinSHA256` 的客户端，
  等于放弃了身份校验（v2rayN 7.x 就是这种情况，所以脚本额外给了一条兼容链接并标注）。
- **脚本本身以 root 运行**。它不联网执行远程代码、不 `curl | bash` 二级脚本，但你必须信任
  你下载的那份 `setup.sh`——用之前对一下仓库里的内容。
- **没有任何自动化能替代看日志**。装完先跑 `proxy info`、`proxy status`、`proxy audit`。
  真出问题时跑 `proxy diag`，它会把这些一次性收集齐并自动脱敏。

---

## Google 送中

「送中」是指 Google 把你当成中国大陆用户：跳转 `google.com.hk`、强制中文界面、
频繁弹人机验证。

### 原因：客户端先在本地把域名解析了

Google 判断你在哪，看的是**它看到你从哪个 IP 来**。出问题的链路长这样：

1. 你在国内，客户端用系统 DNS（运营商 / 114）解析 `google.com`
2. 拿到一个国内 CDN 地址，或者被污染过的 IP
3. 把那个 **IP** 交给代理，而不是域名
4. 服务端只能连这个 IP，Google 看到的对端就成了国内节点

只要第 3 步发的是域名、由服务端在境外解析，Google 看到的就是 VPS 的 IP，不会送中。

但客户端不总是听话：`UseIP` 策略、GEOIP 分流、App 自带 DoH，都会让它把 IP 发过来。
所以服务端必须有一层兜底——**从 TLS ClientHello 里把域名捞回来，自己重新解析**。

三种协议各有一个对应开关，脚本现在都开了：

| 协议 | 服务端域名还原 |
|---|---|
| VLESS-REALITY（xray） | inbound `sniffing` + `destOverride` + `routeOnly: false` |
| Hysteria2 | `sniff` + `rewriteDomain`（老版本不认时自动去掉，不让安装失败） |
| SS2022 / AnyTLS / TUIC（sing-box） | 1.11+ 用 route 的 `{ "action": "sniff" }`；1.8~1.10 自动退回 inbound 的 `sniff` + `sniff_override_destination` |

sing-box 那三种写法是**按新到旧依次试**的：写完配置先跑 `sing-box check`，
新写法不认就换成旧写法，两种都不认才放弃（这时会明确警告「已跳过域名还原」）。
只试新写法的话，老内核上等于直接把这一层丢了 —— 所以这里必须两种都试。

这一层不需要客户端配合，客户端发什么过来都能救回来。

### 脚本的修法：订阅里强制 fake-ip

`clash.yaml`、`singbox.json`、`singbox-compat.json` 现在都带 DNS 配置：

| 配置 | 作用 |
|---|---|
| `dns.enhanced-mode: fake-ip`（Clash）/ `dns.final: remote`（sing-box） | 域名先拿一个 `198.18.x.x` 的假地址，**真域名原样送到服务端解析** |
| `ipv6: false` / `strategy: ipv4_only` | 客户端有公网 v6 时，部分应用会绕过代理直连 AAAA 记录，真实位置就漏了 |
| `nameserver` 用国内 DoH | 只用来解析局域网和系统探测域名（`fake-ip-filter` 里那几条），不会被墙 |

sing-box 侧的 DNS 接管实测过：路由规则必须写 `"port": 53, "action": "hijack-dns"`，
写 `"protocol": "dns"` **匹配不到 UDP/53**，流量会直接走 `final` 出站，等于没接管；
DNS 规则那边则必须用裸 `"server": "local"`，加 `"action": "route"` 反而失效。

手动导入链接（不用订阅）时这两项得自己配，否则等于没修。

### 小火箭（Shadowrocket）要核对七项

`base64.txt` 是纯节点列表，不带 DNS 配置。小火箭自己**有** fake-ip（返回
`198.18.0.2` 假地址），不需要额外配 fake-ip；但下面七项默认值不一定对。
路径都在底部 **配置** 标签里。

**① 配置 → 通用 → DNS 覆写：留空，或填国内 DNS**

这一项和 v2rayN 完全不同，别照搬 v2rayN 的配法。

v2rayN 有「直连 DNS / 远程 DNS」两个入口，能按规则分开走。小火箭只有**一个**
DNS 覆写，而且它是**全局生效**的：不管域名是国内还是国外，都拿它去解析。

填境外 DNS（`1.1.1.1` / `8.8.8.8`）会出事：你的规则里只要有 `GEOIP,CN,DIRECT`，
小火箭就必须先解析域名才知道是不是国内——用 `1.1.1.1` 解析 `taobao.com`，拿到的是
境外 CDN 的 IP，判定「不是 CN」，于是国内流量也进了代理。症状就是**国外正常，
淘宝 / B站 / 微信 / 国内 App 打不开**。

```
DNS 覆写：留空（用系统 DNS）   或   223.5.5.5
备用 DNS：留空
```

**防送中不靠这一项。** 小火箭自带 fake-ip（返回 `198.18.0.2`），走代理的域名本来
就不会被真正解析，域名原样发到服务端；就算被解析了，服务端 inbound 的 `sniffing`
也会从 TLS SNI 里把域名捞回来重新解析。两头都有兜底。

真正要防的是「某些 App 绕过 fake-ip 自己用系统 DNS 解析 `google.com`」——那种情况
改小火箭的 DNS 覆写也拦不住（它压根不经过小火箭的 DNS），要靠关掉 App 自带的 DoH，
见下文「客户端自己带 DoH 的必须关掉」。

**② 配置 → 通用 → 启用 IPv6** → 关

手机拿到公网 v6 后，部分 App 会绕过代理直连 AAAA 记录，真实位置就漏了。
只关「首选 IPv6」不够，「启用 IPv6」本身也要关。

**③ 配置 → UDP → 禁用 STUN** → 开

打开等于关掉 WebRTC 泄漏，比在桌面浏览器里改注册表省事。不开的话浏览器 WebRTC
可能绕过代理暴露真实 IP。

**④ 配置 → UDP → 启用转发** → 必须开

hysteria2 / TUIC 全部走 UDP，这项关了这两个协议直接不通。默认开，别关。

**⑤ 配置 → TCP → 指纹** → 保持默认

iOS 上默认是 `Safari26_x`，这**比 chrome 更自然**——iOS 设备本来就该发出 Safari 的
ClientHello，改成 chrome 反而违和。REALITY 服务端不校验指纹具体值，只要 ClientHello
能原样转发就行。别动它。

**⑥ 私有 IP 应答** → 保持开

关掉会让内网域名（路由器后台、NAS）强制走代理，反而访问不了。

**⑦ 全局路由：选「配置」，不要选「代理」**

首页 → 全局路由。`配置` 按规则分流；`代理` 是全部走代理，国内站点也会绕出国。

> 如果你确认一直用的是「配置」、国内网站还是打不开，那问题不在这一项，在 **①**
> ——DNS 覆写填了境外 DNS，导致 GEOIP 把国内域名判成国外。两项要分开查。

界面里找不到这些项时，也可以直接编辑配置文件，在 `[General]` 段写：

```
[General]
dns-server = 223.5.5.5
ipv6 = false
prefer-ipv6 = false
```

`dns-server` 这一行干脆不写也行（用系统 DNS）。写境外 DNS 会破坏 GEOIP 分流，
原因见 ①。

### v2rayN（Windows）要核对七项

v2rayN 各版本界面差异比小火箭大，下面按**功能**写，标签名可能略有不同。
菜单基本都在顶部「设置」里。

**① 订阅用 `v2rayn-safe.txt`，别用 `base64.txt`**

`v2rayn-safe.txt` 只含 REALITY / SS2022，不含任何「跳过证书验证」，新版 v2rayN
导入后不会弹「不安全」提示，也不会踩 Xray 移除 `allowInsecure` 的坑。
旧的 `v2rayn.txt` 仍保留，只为兼容老客户端 —— 它含 HY2 / AnyTLS / TUIC 三条
`insecure` 链接，能连但没有证书校验。

> `fp` 在分享链接标准里是 **uTLS 浏览器指纹**（`fp=chrome`），**不是证书指纹**。
> 旧版本文档误写成「带 `fp=` 就有证书校验」，已更正：v2rayN 的 HY2 / AnyTLS / TUIC
> 界面没有证书指纹字段，URI 里的 `pinSHA256` 它也不识别。要真固定请导入
> `singbox.json`（1.13+）；`clash.yaml` 只有 Hysteria2 带 `fingerprint`，另外两条仍是
> `skip-cert-verify: true`。`base64.txt` 是全部节点，其中 hy2 / anytls / tuic 三条是兼容链接，能连但没有身份验证。

**② TUN 模式：MTU 填 1500，关掉「严格路由」**

默认 MTU 是 sing-box 的 9000，家宽/Wi-Fi 实际只有 1500 或 1492，大包会被丢弃，
典型症状是「显示已连接但网页打不开」。严格路由开着时出站一断就整机断网，
DNS 也会被一起劫持进 TUN。

**③ `bin\sing_box\wintun.dll` 必须存在**

v2rayN 的 TUN 由 sing-box 内核实现，缺这个文件虚拟网卡根本创建不出来。
若没有，把 `bin\xray\wintun.dll` 复制过去即可。TUN 还要以管理员身份运行。

**④ DNS 设置：远程 DNS 用境外 DoH**

`设置 → DNS 设置 → DNS 基础设置`：

```
直连 DNS   ：223.5.5.5 或 119.29.29.29    国内域名走直连，用国内的最快
远程 DNS   ：https://1.1.1.1/dns-query    走代理的域名，必须是境外
Bootstrap  ：223.5.5.5                    只用来解析上面那个域名，必须填 IP
```

远程 DNS 写成 IP 形式（`https://1.1.1.1/dns-query`）可以绕开 Bootstrap，链路少一环；
写成域名形式（`https://cloudflare-dns.com/dns-query`）也能用，Bootstrap 被污染时
TLS 证书校验会拦住，不会真的被中间人。

**代理目标解析策略保持 `Default` —— 这项最关键**

界面上写得很清楚：「当未选择或 AsIs 时，由远程服务器端 DNS 解析」。`Default` 就是
我们要的：域名原样发到服务端再解析。

一旦改成 `UseIP` / `UseIPv4`，就变成客户端本地解析——域名先被解析成国内 CDN 的 IP
再发出去，**这就是送中**。

直连目标解析策略同样保持 `Default`，直连域名交给系统 DNS 最快。

另外三个标签页（DNS 进阶设置 / v2ray 自定义 DNS / sing-box 自定义 DNS）保持默认，
不要在里面再配一套——会覆盖上面的基础设置，症状是「改了没生效」。

**⑤ 路由设置里的域名解析策略：选 `IPIfNonMatch`，不要选 `AsIs`**

`设置 → 路由设置 → 域名解析策略`。这一项和 ④ 不是同一件事，别混：

| 取值 | 效果 |
|---|---|
| `IPIfNonMatch` | 前面的域名规则都没命中时，才在本地解析一次跑 geoip 分流。**选这个** |
| `AsIs` | 完全不解析。基于 IP 的分流规则（`geoip:cn`）会全部失效 |
| `IPOnDemand` | 每次连接都解析，没必要，还慢 |

早期版本文档里写的是 `AsIs`，那是错的。它的前提是「全部流量都走代理」，
而你要同时访问国内网站和 App 时，`AsIs` 会让 geoip 分流失效——淘宝 / B站 / 微信
也跟着绕出国再回来，表现就是**「开了代理，国内网站打不开」**。

会不会因为本地解析而送中？不会。域名被本地解析成 IP 发到服务端之后，服务端
inbound 的 `sniffing` 会从 TLS SNI 里把域名捞回来，再用服务端 DNS 重新解析一次
（见 `write_xray_config` 的 `destOverride` 与 `routeOnly: false`）。多这一层兜底，
本地解析不会把地区带偏。

**⑥ 路由模式用「绕过大陆」，不要用「全局」**

`设置 → 路由设置 → 路由`。选全局的话国内站点一样走代理，和上一条是同一类问题。

**⑦ 系统代理：TUN 模式下选「不改变系统代理」**

TUN 已经接管全部流量，再叠加一层系统代理属于重复代理。通常不会坏，但会让排障
变复杂，部分应用也会因此走错路径。

### 客户端自己带 DoH 的，必须关掉

fake-ip 只在**域名经过代理的 DNS 映射**时才有效。浏览器 / App 自带的加密 DNS
会绕过系统 DNS 和 fake-ip 映射，自己在本地把域名解析成国内 CDN 的 IP —— 
这种路径 fake-ip 救不了，因为域名压根没进代理。

| 客户端 | 关在哪 |
|---|---|
| Chrome / Edge | 设置 → 隐私和安全 → 安全 → 使用安全 DNS → 关 |
| Firefox | 设置 → 隐私与安全 → 网络设置 → 加密 DNS → 关或改「手动」 |
| Safari (macOS/iOS) | 系统设置 → 网络 → DNS → 关「加密 DNS」 |

### 还有三项在客户端，脚本管不到

| 项 | 正确值 |
|---|---|
| 浏览器语言 | 英文或目标地区语言，不要 `zh-CN` |
| 系统时区 | 与节点地区一致 |
| WebRTC | 关闭 |

### Clash 客户端必须用 mihomo 内核

`clash.yaml` 里的 `enhanced-mode: fake-ip` 是 Clash Meta / mihomo 才有的功能。
老版 Clash 不支持，导入后会**静默回退到系统 DNS** —— 症状是「节点能连、
Google 还是判中国」。这时候要换内核（Clash Verge Rev / FlClash / mihomo），
不要去改别的地方。

### 怎么确认

```bash
proxy audit
```

看 `Google 地区` 那一行。判定是**拿出口国家做基准**的，不是见着 `google.com.hk`
就报「送中」——香港、澳门的机器 Google 本来就该跳 `.com.hk`，一律当送中等于 100% 误报。

| 输出 | 含义 |
|---|---|
| `未跳转` | Google 按正常归属地对待，IP 本身没问题 |
| `跳 google.com.hk —— 出口在 HK` | **正常**。出口就在香港，这是当地域名 |
| `跳 google.co.jp / google.de / … 与出口 XX 一致` | **正常**。各国本地域名，和出口国家对得上 |
| `被判为中国大陆（跳 google.com.hk），出口登记在 US` | 这个 IP 在 Google 库里的归属有问题——客户端怎么配都没用，只能换 IP。通常出现在被大量中国用户用过的 IP 段上，和你自己的配置无关 |
| `跳 google.XX，但出口在 YY（预期 google.ZZ）` | 出口国家和 Google 认定的地区不一致，多半也是 IP 库的问题 |
| `连不上（HTTP 000）` | 服务端本身出不去，先修出口（`proxy status`），这时候判不了地区 |

这一项探测本身也踩过坑，现在的做法是：**真实浏览器 UA + zh-CN 和 en-US 各探一次
+ 同时看 HTTP 跳转和页面内域名**。原因是 Google 现在多数情况不再回 302，而是回
200 加页面里的 JS 跳转——只看响应头会漏报，出现「浏览器明明跳了 hk，审计却说未跳转」
的情况。两种语言都试也是为了贴近真实浏览器：中文系统发出的就是 `zh-CN`，
而 Google 对「IP 归属模糊 + 中文用户」会额外偏向港区。

`IP 类型` 那一行（`hosting`）是**参考口径**，来自 ip-api 的公开库，
和平台自己的风控库不一定一致——同一台机器这里显示 `hosting=false`，
平台侧照样按机房处理。真正的结论以平台实际表现为准。

---

## TikTok / 多账号运营

脚本能优化的是**链路质量**，但账号安全有一大半在服务端之外。分开说。

### 服务端能做的（脚本已做）

- 出口 IP 稳定不漂移：出站强制 IPv4、屏蔽 IPv6 目标，不会今天走 v4 明天走 v6
- 一条线路一个出口：不套 WARP、不套 CDN，TikTok 看到的就是这台机器的 IP
- 时间同步：REALITY 需要，TikTok 的风控也会看请求时间是否合理
- 时区对齐：`proxy audit` 会对比「系统时区」和「出口 IP 时区」，不一致提示一句。
  注意这只是**本机日志可读性**，平台看不到 VPS 的系统时区（详见「时区」一节）
- 独立凭据：每个 VPS 单独生成 UUID，不会像共享节点那样几十个人共用一个出口
- 伪装目标不扎堆也不将就：`pick_dest` 先按 TLS 版本分档、档内按握手耗时排序，
  再只在**前三名里随机**。全网都取第一会让 SNI 集中到一个域名上（最好批量识别
  的一类特征），纯随机又会挑到几百毫秒的慢站 —— 前三名随机两头都照顾到
- 服务端二次解析：xray 用 `sniffing` + `routeOnly: false`、hysteria2 用
  `sniff.rewriteDomain`，客户端即使在本地解析了域名，服务端也会从 TLS SNI
  里把域名捞回来重新解析
- 订阅里配好 fake-ip DNS 并关掉 IPv6，避免客户端本地解析把位置漏出去（见「Google 送中」）
- `proxy audit` 直接查 `hosting` 标记和 Google 地区判定，不用自己猜

### 服务端改不了的硬伤

| 问题 | 说明 |
|---|---|
| **机房 IP** | 数据中心网段会被直接归类为 `hosting`，权重天然低于住宅 IP。`proxy audit` 会直接打出来 |
| **无 PTR 记录** | 提高可疑度，部分服务商会免费给加，值得问一句 |
| **共享 IP 历史** | 这个 IP 之前有没有被人跑过黑产，你无法知道 |

想彻底解决只有换住宅 IP / 原生 IP 线路，成本高一个量级。机房 IP 更适合做
「环境稳定、操作频率低」的辅助节点，不适合当主力养号线路。

> `proxy audit` 里的 `hosting` 只是一个**参考口径**，和平台各自的数据源并不完全一致。
> 实测同一台机器 ip-api 给 `hosting=false`，平台侧仍按机房处理 —— 最终以平台实际表现为准。

#### 进阶：再接一层住宅出口

唯一的技术解法是**让最终出口不是机房 IP**。如果你手上有另一台机器
（家宽宽带、运营商的动态 IP 盒子、或者朋友的家用宽带），可以把它放在最外层：

```
你的设备  →  VPS(中转, REALITY/HY2)  →  住宅出口机器  →  目标网站
```

TikTok 看到的是住宅 IP，Google 也按那个地区判。VPS 只承担加密隧道，不再直接对外。

**脚本已经内置这一步**，不用手改 JSON：

```bash
proxy egress socks5://用户:密码@住宅机IP:1080     # 接上（支持 socks5 / http）
proxy egress                                     # 查看当前出口 + 实测出口 IP
proxy egress off                                 # 关掉，恢复本机直连
```

它会做四件事：测试这个上游能不能连通 → 写进 xray 和 sing-box 的配置 →
重启服务 → 用真实隧道查一次出口 IP。**客户端配置和分享链接完全不用改**，
因为改的是服务端默认出站。

住宅机那边跑一个 socks5 就行（`danted`，或者 sing-box 的 socks inbound）：

```json
{ "type": "socks", "tag": "in", "listen": "0.0.0.0", "listen_port": 1080,
  "users": [{ "username": "用户", "password": "密码" }] }
```

> 一定要加 `users`。裸 socks5 放到公网上，几小时内就会被扫到并当成开放代理。

几点注意：

- 中转机不再直接暴露在公网，IP 被封的损失小很多
- 住宅出口如果是动态 IP，要配 DDNS
- 两跳延迟会明显上升，跨境链路下可能从 150ms 变成 250ms 以上
- 上游代理挂了不会自动回落直连（那样等于静默降级，反而更难查），
  `proxy audit` 会直接报「上游出口当前不通」
- 用 Cloudflare WARP 做出口**解决不了**：WARP 的段同样被标成机房，而且用的人太多，风控等级比普通 VPS 还高

### 客户端必须做的

```
[ ] 关闭 WebRTC           浏览器里 WebRTC 会绕过代理暴露真实 IP
[ ] 关闭 IPv6             手机/电脑网络设置里关掉
[ ] DNS 用订阅里配好的     订阅已开 fake-ip, 别在客户端另配成 8.8.8.8 明文
[ ] 关闭浏览器自带 DoH     Chrome/Edge 的"安全 DNS"、Firefox 的"加密 DNS"要关, 否则绕过 fake-ip
[ ] Clash 用 mihomo 内核   老版 Clash 不支持 fake-ip, 会静默回退到系统 DNS
[ ] 时区/语言/地区一致     做哪个区就全设那个区
[ ] 一号一 IP             多账号共用同一出口 IP 是最典型的关联信号
[ ] 固定不切换             频繁换 IP 会触发异常登录
[ ] 指纹浏览器             多账号别用同一个浏览器指纹
```

`proxy audit` 会把这份清单打印出来，方便对照。

---

## 常见问题

**Q: 上游已经修了 bug，我机器上还是老行为**

因为 `proxy` 跑的是**磁盘上那份 .sh**，不会自动跟着仓库走。

```bash
proxy version     # 先看自己是什么版本
proxy update      # 更新到最新
```

`proxy install` / `proxy install --clean` / 部署向导都会在动手前**自动**查远端版本、
有新版就换掉自己再继续。已经装过的机器直接敲 `proxy` 进的是**管理菜单**，不会自动
更新（只会提示有没有新版），需要显式执行 `proxy update`。查不到远端版本时现在会打一行
警告，不再静默跑旧版。真正还会踩坑的是磁盘上留着好几份不同时期的 `setup*.sh`：
从文件运行且安装成功结束时会自动清理（见「快速开始」），管道运行不会。

`proxy info` 和 `proxy diag` 里也会打印脚本版本、路径和文件修改时间——对一下
就知道手上这份是什么时候下载的。

**Q: 磁盘上的 setup 文件是很早以前的老副本，`proxy update` 一直拒绝更新，怎么办**

`proxy update` 跑的是磁盘上那份老代码；老代码没有世代判断，会认为 1.3.x 比远端的
1.0.x 新而拒绝更新。这一步**任何新版代码都救不了**，必须手工覆盖一次：

```bash
PN_TMP=$(mktemp /tmp/pn.XXXXXXXXXX) \
  && curl -fsSL https://raw.githubusercontent.com/smallji666/proxy-node/main/setup.sh -o "$PN_TMP" \
  && [ -f "$PN_TMP" ] && [ ! -L "$PN_TMP" ] \
  && bash -n "$PN_TMP" \
  && mv -f "$PN_TMP" /root/setup-proxy.sh \
  && chmod 755 /root/setup-proxy.sh \
  && ln -sf /root/setup-proxy.sh /usr/local/bin/proxy
```

国内 VPS 拉不动 `raw.githubusercontent.com` 时，给 URL 加 `https://ghfast.top/` 前缀。
覆盖完 `proxy version` 应显示 `v1.0.0`；之后 `proxy update` 就走世代判断了。
想连磁盘上的脚本一起删掉再重装：`proxy clean --all`（本版也会清掉改名过的副本）。

**Q: 同一条命令，为什么每次在 VPS 里看到的选项不一样**

界面顶部现在会印两行：标题里的版本号（当前 `v1.0.0`），和下面那行 `脚本 /root/setup-proxy.sh`。
先对这两样，基本就能定位：

| 现象 | 原因 |
|---|---|
| 一次是「部署向导」（`1~9`、`c`、`0`），一次是「管理菜单」（`1~0`、`l n v d a r b t z y f c u`） | 这是**两个不同的界面**，不是选项变了。没装过进向导，装过进菜单 |
| 版本号不一样 | 跑到了不同版本的脚本。各台 VPS 装的时间不同，或者磁盘上留着旧副本 |
| 菜单只到 `9)` 就没了，时区只有「美国六个城市」 | 跑的是很早以前的老副本（新版菜单有 `l`/`n`/`v`/`d`/`a`/`r`/`b`/`t`/`z`/`y`/`f`/`c`/`u`，时区也按地区分组） |

自查一条命令：

```bash
bash /root/setup-proxy.sh version    # 或者 proxy version
```

> 自动更新的**版本检测**和下载都必须走镜像。只给下载配镜像、检测直连
> `raw.githubusercontent.com` 的话，国内 VPS 上这条请求时通时不通 —— 通的那天自动
> 更新到新版，不通的那天退回磁盘上的旧版。历史上后者是静默的，表现就是「同一台机器，
> 今天一个新界面、明天一个旧界面」；现在会明确打印一行
> 「无法获取远端脚本版本(网络不通或被拦截), 本次按本地 vX 执行」，不再让人靠猜。

**Q: 开了代理，国内网站和 App 反而打不开了**

典型症状：国外站点正常，淘宝 / B站 / 微信 / 国内 App 转圈或直接报错。

不是线路坏了，是**国内流量被误判成国外、也送进了代理**。绕一圈出国再回来，
很多国内服务会直接拒绝境外 IP。三个常见入口，按你的客户端对号：

**小火箭：DNS 覆写填了境外 DNS**

小火箭只有一个 DNS 覆写，且**全局生效**。规则里有 `GEOIP,CN,DIRECT` 时，它要先
解析出 IP 才能判断国内国外——用 `1.1.1.1` 解析 `taobao.com` 拿到境外 CDN 的 IP，
判定「不是 CN」，于是走了代理。

改法：`配置 → 通用 → DNS 覆写` **留空**（或填 `223.5.5.5`），备用 DNS 也留空。

**v2rayN：路由的域名解析策略选了 `AsIs`**

`AsIs` 完全不解析域名，`geoip:cn` 这类基于 IP 的规则全部失效。
改成 `IPIfNonMatch`（`设置 → 路由设置 → 域名解析策略`）。

**两边都可能是：路由模式选了「全局」/「代理」**

v2rayN 改成「绕过大陆」；小火箭首页 → 全局路由 → 选「配置」。

如果你用的是订阅里的 `clash.yaml`，它已经自带分流规则
（局域网 + `GEOSITE,cn` + `GEOIP,CN` 直连，其余走代理），重新拉一次订阅即可。

> 改回分流会不会导致送中？不会。服务端 inbound 的 `sniffing` 会从 TLS SNI 里
> 把域名捞回来重新解析，客户端本地解析那一步被兜住了。

**Q: 敲 `proxy` 提示 Permission denied**

装完直接敲 `proxy` 报 `/usr/local/bin/proxy: Permission denied`，是因为下载下来的
`setup.sh` 没有执行权限（`curl -o` 存盘是 644），而 `proxy` 只是指向它的软链——
软链本身能执行，但目标文件没有 x 位，内核会拒绝，root 也一样。

一行修好：

```bash
chmod +x /root/setup-proxy.sh
```

不知道软链指向哪的话：

```bash
chmod +x "$(readlink -f /usr/local/bin/proxy)"
```

新版安装脚本在创建软链前会自动补上执行位，重跑一次 `install` 也能修好。

**Q: 用不了 / 连不上，不知道哪一环出问题**

在服务器上跑一条命令：

```bash
proxy diag
```

它会一次性收集系统信息、服务状态与重启次数、实际监听端口、配置校验结果、
出口 IP 与伪装站握手、系统时间偏差、防火墙规则、逐协议实测、最近告警日志，
写到 `/root/proxy-diag-<时间>.txt`。**UUID、密码、token 在落盘前已全部替换成 `<已隐去>`**，
所以整份内容可以直接贴出来求助，不用担心泄露凭据。

报告里最该先看的三处：

- `[7] 与 CF 时差` —— 超过 60 秒 TLS 握手就会失败，`proxy optimize time` 校时
- `[9] 协议实测` —— 哪个协议「不通」，就去看对应服务那一段日志
- `[3] 服务状态` —— 重启次数一直涨说明进程在反复崩溃，不是配置问题

**Q: 手机显示已连接但打不开网页**

先确认服务端 Xray 版本是不是被升到了 26.9.8 以上。是的话执行
`XRAY_VERSION=26.3.27 bash /root/setup-proxy.sh install` 回滚。

**Q: 开了 TUN 模式就完全没网**

按这四项核对，顺序就是出错概率：

1. **MTU 填 1500** —— sing-box 默认 9000，家宽/Wi-Fi 实际只有 1500 或 1492，大包会被丢弃
2. **关掉"严格路由"** —— 开着时出站一断就全黑洞，DNS 也被一起劫持进 TUN
3. **管理员权限运行** —— 建不了虚拟网卡时会静默失败，而系统代理此时已被关掉
4. **DNS 别只押一个 DoH** —— 所有域名走同一个远程 DoH，节点一抖就全部超时

定位方法：TUN 开着时 `ping 1.1.1.1`，通说明路由没问题、问题在 DNS；不通说明网卡或路由没起来。

Windows 上 v2rayN 的 TUN 由 sing-box 内核实现，还需要 `bin\sing_box\wintun.dll`。
缺了就把它从 `bin\xray\wintun.dll` 复制过去，否则虚拟网卡根本创建不出来。

**Q: 换端口后连不上**

云安全组要跟着改。另外 Hysteria2 是 UDP，安全组里容易只放行了 TCP。

**Q: 想换 UUID**

`proxy reset`，会重新生成全部凭据并重新验证伪装站。

**Q: 端口跳跃开了但客户端没生效**

客户端也要支持。Hysteria2 链接里带 `mport` 参数，部分客户端会忽略它。

---

## 卸载

```bash
proxy clean          # 清服务与配置，保留 proxy 命令方便重装
proxy clean --all    # 连管理命令和脚本一起删
```

会停止并删除服务、配置、凭据、订阅目录、状态文件，撤回本脚本加过的防火墙端口与
端口跳跃规则，并还原 sysctl / 句柄数 / journald 设置。
swap 文件会保留——它不影响重装，删了反而下次还得重建。

---

## 版本记录

**v1.0.0（2026-11-10，世代 4）** —— 全量复查后的缺陷修复，不含新功能：

- **P0**：`state.env` 不再被 `source`。以前写值只包一层单引号，值里带一个引号就
  会在下次 `load_state` / 健康检查里以 root 执行任意命令。现在写入统一做单引号
  转义、读取只按白名单键逐行解析成纯字符串；`proxy-healthcheck.sh`、
  `proxy restore`、`proxy clean` 全部走同一套解析，不留旁路。
- **P1**：端口跳跃改区间前先停旧 unit 并枚举清理历史 REDIRECT 规则；
  `ufw`/`firewalld` 换端口或 `clean` 时会撤回旧规则；无托管防火墙时会检测原生
  iptables 的 INPUT 默认策略而不是笼统说「未启用」；TUIC 按 UDP-only 处理；
  `sysctl -p` 的错误不再被吞掉，并逐项回读确认参数真的生效。
- **P2/P3**：订阅 token 从 unit 挪到 0600 的 `EnvironmentFile`；一键命令改用
  `mktemp` 随机路径；`base64.txt` 生成失败即中止；所有 `mktemp` 检查失败；
  自更新增加多源哈希交叉比对；`clean` 补删句柄数配置与旧 `hysteria.service`；
  去掉不必要的 `ip_forward=1`；备份包内 `state.env` 增加逐行格式校验。
- 工程化：新增 `test/run.sh` 回归套件与 GitHub Actions CI。

---

## License

[MIT](LICENSE)

## 免责声明

本项目仅供学习与网络技术研究使用。请遵守你所在地区的法律法规以及服务提供商的使用条款。
使用者需自行承担因使用本工具产生的一切后果。
