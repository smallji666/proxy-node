# proxy-node

> 一条命令在 VPS 上部署 **VLESS + REALITY (xtls-rprx-vision)** 与 **Hysteria2**，
> 自带幂等安装、订阅生成、端口跳跃和日常管理命令。

专为「小内存 VPS + iOS 小火箭 / v2rayN / Clash」这种常见组合调过参数，
把几个实际会踩的坑提前处理掉了（见下方[设计取舍](#设计取舍)）。

---

## 特性

| 能力 | 说明 |
|---|---|
| 双协议 | VLESS + REALITY（TCP 443）+ Hysteria2（UDP 443），互不冲突 |
| 证书固定 | Hysteria2 自签证书用 `pinSHA256` 固定指纹，客户端**不需要 `insecure`** |
| 自动选伪装站 | 遍历候选站点，**用真实 REALITY 握手验证**通过才采用 |
| 幂等安装 | 凭据持久化，重跑脚本不会重置 UUID，已有客户端不失效 |
| 多设备凭据 | 每台设备一条 UUID，可单独吊销；丢手机不影响其他设备 |
| 订阅生成 | 自动产出 `clash.yaml` / `singbox.json` / `base64` 通用订阅 / 原始链接 |
| 端口跳跃 | Hysteria2 UDP 端口区间跳跃，绕开单端口 QoS |
| 管理命令 | 安装后可用 `proxy` 打开菜单，或用子命令直接操作 |
| 配置备份 | 每次改动前自动备份，保留最近 5 份 |
| 内置 DNS 解析 | Xray 自带 DNS 缓存 + 强制 IPv4，解析更快、不依赖系统解析器 |
| IPv6 防泄漏 | 出站强制 IPv4 + 路由层屏蔽 IPv6 目标 |
| 系统调优 | BBR + fq、TCP Fast Open、长连接不重慢启动、journald 限容、自动 1GB swap |
| 健康检查 | systemd timer 每 5 分钟检查，服务或端口异常自动重启 |
| 线路体检 | `proxy audit` 实测出口 IP、PTR、时间同步，并给出客户端检查清单 |

---

## 快速开始

在 VPS 上以 **root** 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/smallji666/proxy-node/main/setup.sh -o /root/setup-proxy.sh && bash /root/setup-proxy.sh
```

> 为什么不直接 `curl | bash`：下载成文件再执行，脚本才能把自己软链成 `proxy` 管理命令。
> 直接管道执行也能跑通，只是没有 `proxy` 命令。

跑完会打印两套链接和终端二维码，同时把纯文本信息存到 `/root/proxy-info.txt`。

### 部署后必做

**云厂商安全组放行** `TCP 443` 和 `UDP 443`。脚本只能改本机防火墙，改不了云控制台。

---

## 管理命令

安装完成后，任意目录直接输入 `proxy`：

```bash
proxy                # 打开交互菜单
proxy info           # 查看节点信息、链接、二维码
proxy sub            # 重新生成订阅文件
proxy status         # 服务状态与监听端口
proxy restart        # 重启 xray 与 hysteria2
proxy logs           # 实时日志（proxy logs hy2 看 hysteria2）
proxy audit          # 线路体检：出口 IP / PTR / 时间同步 / 客户端清单
proxy user           # 设备凭据：list / add <名字> / link <名字> / rm <名字>
proxy reset          # 重置凭据（会作废所有已导入客户端）
proxy uninstall      # 卸载
```

也可以继续用脚本本身：`bash /root/setup-proxy.sh info`

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

## 环境变量

首次安装时通过环境变量定制，安装后写入 `/etc/proxy-node/state.env` 复用：

| 变量 | 默认 | 说明 |
|---|---|---|
| `VLESS_PORT` | `443` | VLESS 监听 TCP 端口 |
| `HY2_PORT` | `443` | Hysteria2 监听 UDP 端口（可与 TCP 443 共存） |
| `REALITY_DEST` | 自动 | 伪装目标站，留空则自动挑选并验证 |
| `ENABLE_OBFS` | `0` | `1` 开启 Hysteria2 salamander 混淆 |
| `HY2_HOP` | 空 | 端口跳跃区间，如 `20000-30000` |
| `HY2_INSECURE` | `0` | `1` 关闭证书固定、退回 `insecure`，**仅调试用** |
| `SUB_HTTP` | `0` | `1` 起一个订阅 HTTP 服务 |
| `SUB_PORT` | 随机 | 订阅 HTTP 端口 |
| `NODE_NAME` | `Node` | 节点名（订阅与链接里的显示名） |
| `XRAY_VERSION` | `26.3.27` | Xray 版本，**不建议改动**，见下文 |
| `ASSUME_YES` | `0` | `1` 全程不询问 |

示例：

```bash
# 换端口 + 开混淆 + 开端口跳跃
VLESS_PORT=8443 HY2_PORT=8443 ENABLE_OBFS=1 HY2_HOP=20000-30000 \
  bash /root/setup-proxy.sh install

# 指定伪装站（会先验证握手，不通过会自动换下一个）
REALITY_DEST=www.samsung.com bash /root/setup-proxy.sh install
```

---

## 订阅文件

默认输出到 `/var/www/proxy-sub/<随机token>/`：

```
links.txt      原始链接（两行）
base64.txt     通用订阅，小火箭 / v2rayN / v2rayNG 直接导入
clash.yaml     Clash / mihomo / Clash Verge
singbox.json   sing-box
client-guide.md 客户端配置指南（证书固定 / TUN 参数 / 排障）
```

加 `SUB_HTTP=1` 会起一个静态 HTTP 服务提供订阅链接。目录里放了 `index.html`
遮住目录列表，必须知道完整 token 路径才能取到文件。不需要时：

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

正确做法是**指纹固定**：客户端不验证 CA 链，只验证"这张证书的公钥哈希必须等于我记下的值"。
指纹只能来自你这台服务器，中间人换不掉，安全性等同于正式证书，且不需要域名、不需要续期。

脚本在部署时会用**真实握手自测**指纹形式（SPKI / 整证书），确认能通才写进链接，
所以不会出现"配了指纹反而连不上"的情况。确实要退回时用 `HY2_INSECURE=1`。

| 客户端 | 字段 |
|---|---|
| hysteria2 链接 | `pinSHA256`（脚本自动带上） |
| sing-box | `tls.certificate_public_key_sha256` |
| mihomo / Clash | `skip-cert-verify: false` + `fingerprint` |

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

这类问题光看「网站能不能访问」发现不了 —— 微软站 curl 返回 200、TLS 1.3 也支持，
但 REALITY 就是握手不过。所以脚本会真的起一个本地客户端做完整握手，通了才算数。

### 为什么没启用 VLESS Encryption

Xray 新版支持给 VLESS 头部加密（`"decryption": "mlkem768x25519plus.native.600s.xxx"`），
能消除 TLS-in-TLS 的特征，理论上抗检测更强。

但它要求**客户端也支持**。Shadowrocket 目前不支持，启用后手机直接连不上。
对一个以「iOS 小火箭能用」为前提的脚本来说，这是负收益。

如果你的客户端是 v2rayN 新版或 sing-box，可以自己改 `decryption` 字段尝鲜。

### 为什么不做 WARP / Argo / 多协议

- **WARP 出站**：出口 IP 会变成 Cloudflare WARP 段，被大量滥用者共用，风控判定比普通机房 IP 更差
- **Argo 隧道**：依赖 CF 域名、绕行边缘节点增加延迟；它的价值是 IP 被封后的保命通道，平时属于多余依赖
- **tuic / anytls / naive / ss2022**：每多一个协议就多一份配置和故障面，本脚本只保留最常用的两个

需要其中任何一项，建议直接用更完整的集成方案。

---

## 安全说明

- 脚本**不含任何硬编码凭据**，UUID、x25519 密钥、shortId、Hysteria2 密码全部在服务器本地生成
- 不向任何第三方上报信息；公网 IP 优先从本地路由表读取，读不到才查询公共 IP 回显服务
- 反垃圾库查询（`proxy audit --dnsbl`）**默认关闭**，因为它会把 IP 交给第三方 DNSBL，需要你显式开启
- 敏感文件权限：`/etc/proxy-node/state.env` 600、`/root/proxy-info.txt` 600、Hysteria2 私钥 600
- Hysteria2 使用自签证书 + 指纹固定，**不依赖 `insecure`**；订阅里带的是公钥指纹，不是私钥
- 设备凭据独立存放于 `/etc/proxy-node/users.txt`（600），每条可单独吊销
- systemd 单元启用沙箱：`NoNewPrivileges`、`PrivateTmp`、`ProtectHome`、`ProtectKernelTunables`、
  `RestrictAddressFamilies` 等，服务被攻破后能动手的范围被压到最小
- 部署日志：`/var/log/proxy-deploy.log`

---

## TikTok / 多账号运营

脚本能优化的是**链路质量**，但账号安全有一大半在服务端之外。分开说。

### 服务端能做的（脚本已做）

- 出口 IP 稳定不漂移：出站强制 IPv4、屏蔽 IPv6 目标，不会今天走 v4 明天走 v6
- 一条线路一个出口：不套 WARP、不套 CDN，TikTok 看到的就是这台机器的 IP
- 时间同步：REALITY 需要，TikTok 的风控也会看请求时间是否合理
- 独立凭据：每个 VPS 单独生成 UUID，不会像共享节点那样几十个人共用一个出口

### 服务端改不了的硬伤

| 问题 | 说明 |
|---|---|
| **机房 IP** | 数据中心网段会被直接归类为 `hosting`，权重天然低于住宅 IP |
| **无 PTR 记录** | 提高可疑度，部分服务商会免费给加，值得问一句 |
| **共享 IP 历史** | 这个 IP 之前有没有被人跑过黑产，你无法知道 |

想彻底解决只有换住宅 IP / 原生 IP 线路，成本高一个量级。机房 IP 更适合做
「环境稳定、操作频率低」的辅助节点，不适合当主力养号线路。

### 客户端必须做的

```
[ ] 关闭 WebRTC           浏览器里 WebRTC 会绕过代理暴露真实 IP
[ ] 关闭 IPv6             手机/电脑网络设置里关掉
[ ] DNS 走远程            客户端设 8.8.8.8 / 1.1.1.1
[ ] 时区/语言/地区一致     做哪个区就全设那个区
[ ] 一号一 IP             多账号共用同一出口 IP 是最典型的关联信号
[ ] 固定不切换             频繁换 IP 会触发异常登录
[ ] 指纹浏览器             多账号别用同一个浏览器指纹
```

`proxy audit` 会把这份清单打印出来，方便对照。

---

## 常见问题

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
proxy uninstall
```

会停止并删除服务、配置、订阅目录与状态文件。BBR 与 swap 属于系统级设置，不会还原。

---

## License

[MIT](LICENSE)

## 免责声明

本项目仅供学习与网络技术研究使用。请遵守你所在地区的法律法规以及服务提供商的使用条款。
使用者需自行承担因使用本工具产生的一切后果。
