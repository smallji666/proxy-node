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
| 自动选伪装站 | 遍历候选站点，**用真实 REALITY 握手验证**通过才采用 |
| 幂等安装 | 凭据持久化，重跑脚本不会重置 UUID，已有客户端不失效 |
| 订阅生成 | 自动产出 `clash.yaml` / `singbox.json` / `base64` 通用订阅 / 原始链接 |
| 端口跳跃 | Hysteria2 UDP 端口区间跳跃，绕开单端口 QoS |
| 管理命令 | 安装后可用 `proxy` 打开菜单，或用子命令直接操作 |
| 配置备份 | 每次改动前自动备份，保留最近 5 份 |
| IPv6 防泄漏 | 出站强制 IPv4 + 路由层屏蔽 IPv6 目标 |
| 系统调优 | BBR + fq、TCP Fast Open、自动 1GB swap |

---

## 快速开始

在 VPS 上以 **root** 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB/proxy-node/main/setup.sh -o /root/setup-proxy.sh && bash /root/setup-proxy.sh
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
proxy reset          # 重置凭据（会作废所有已导入客户端）
proxy uninstall      # 卸载
```

也可以继续用脚本本身：`bash /root/setup-proxy.sh info`

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

### 伪装目标站黑名单

| 域名 | 原因 |
|---|---|
| `cloudflare.com` / `1.1.1.1` | Anycast CDN 边缘，TLS 在 CDN 侧终结，`session_id` 回显不稳定；证书链被海量站点共用，伪装反而更假 |
| `apple.com` / `icloud.com` | Xray 官方警告：用作目标站易导致 IP 被封 |
| `microsoft.com` | 不回显 `session_id`，REALITY 握手直接失败 |

这类问题光看「网站能不能访问」发现不了 —— 微软站 curl 返回 200、TLS 1.3 也支持，
但 REALITY 就是握手不过。所以脚本会真的起一个本地客户端做完整握手，通了才算数。

### 为什么不做 WARP / Argo / 多协议

- **WARP 出站**：出口 IP 会变成 Cloudflare WARP 段，被大量滥用者共用，风控判定比普通机房 IP 更差
- **Argo 隧道**：依赖 CF 域名、绕行边缘节点增加延迟；它的价值是 IP 被封后的保命通道，平时属于多余依赖
- **tuic / anytls / naive / ss2022**：每多一个协议就多一份配置和故障面，本脚本只保留最常用的两个

需要其中任何一项，建议直接用更完整的集成方案。

---

## 安全说明

- 脚本**不含任何硬编码凭据**，UUID、x25519 密钥、shortId、Hysteria2 密码全部在服务器本地生成
- 不向任何第三方上报信息；公网 IP 优先从本地路由表读取，读不到才查询公共 IP 回显服务
- 敏感文件权限：`/etc/proxy-node/state.env` 600、`/root/proxy-info.txt` 600、Hysteria2 私钥 600
- 部署日志：`/var/log/proxy-deploy.log`

---

## 常见问题

**Q: 手机显示已连接但打不开网页**

先确认服务端 Xray 版本是不是被升到了 26.9.8 以上。是的话执行
`XRAY_VERSION=26.3.27 bash /root/setup-proxy.sh install` 回滚。

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
