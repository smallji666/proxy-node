#!/usr/bin/env bash
# ============================================================
#  Proxy Node Installer  (版本号见 SCRIPT_VERSION)
#  Reality / Hysteria2 / SS2022 / AnyTLS / TUIC v5 任选组合
#  一键部署 + 部署向导 + VPS 优化 + 日常管理 + 订阅生成
# ------------------------------------------------------------
#  适用: Debian 11/12  Ubuntu 20/22/24  CentOS/Rocky/Alma 8/9
#  用法:
#     bash setup-proxy.sh              部署向导(选协议/优化/清理), 已装=管理菜单
#     bash setup-proxy.sh install      直接安装(幂等, 不重置凭据)
#     bash setup-proxy.sh install --clean  清理旧实例后全新安装(端口冲突用)
#     bash setup-proxy.sh fresh        等同 install --clean
#     bash setup-proxy.sh optimize     一键优化 VPS(BBR/内核/swap/时间同步)
#     bash setup-proxy.sh timezone     设置时区(按出口IP自动 / 分组选择 / 手动输入)
#     bash setup-proxy.sh info         查看节点信息与链接
#     bash setup-proxy.sh sub          重新生成订阅文件
#     bash setup-proxy.sh status       服务状态
#     bash setup-proxy.sh restart      重启服务
#     bash setup-proxy.sh logs         实时日志
#     bash setup-proxy.sh reset        重置凭据(换 UUID / 密钥)
#     bash setup-proxy.sh backup       打包状态/凭据/证书, 用于迁移
#     bash setup-proxy.sh restore <f>  从备份恢复(换 VPS 时用)
#     bash setup-proxy.sh clean        清除所有配置与服务(端口占用时用这个)
#     bash setup-proxy.sh uninstall    卸载(等同 clean)
#     bash setup-proxy.sh upgrade [版本]  升级内核, --rollback 回滚
#  环境变量(首次安装生效):
#     PROTOCOLS=reality,hy2   协议组合(可选 reality hy2 ss2022 anytls tuic)
#     VLESS_PORT=443  HY2_PORT=443  REALITY_DEST=www.bing.com
#     REALITY_DEST=random  重新随机挑一个伪装站(已装好的机器换 SNI 用这个)
#     SS2022_PORT=8445  ANYTLS_PORT=8444  TUIC_PORT=8443
#     ENABLE_OBFS=1   开启 hy2 salamander 混淆
#     HY2_HOP=20000-30000   hy2 UDP 端口跳跃
#     HY2_INSECURE=1  关闭证书固定, 退回 insecure (不推荐, 仅临时调试)
#     HY2_BW_UP=50 HY2_BW_DOWN=300   Hysteria2 Brutal 带宽(Mbps), 留空=默认 BBR
#     DEFAULT_NODE=hy2  客户端默认节点改走 HY2(UDP, 速度优先); 留空=REALITY(稳妥)
#     NODE_NAME=xxx   节点备注名
#     SUB_PORT=38080  订阅 HTTP 端口(留空=随机 30000-39999)
#     SUB_HTTP=1      起一个订阅 HTTP 服务(默认关)
#     SUB_BIND=0.0.0.0  订阅服务监听地址(默认 127.0.0.1, 只允许本机/SSH 隧道)
#     HY2_VERSION=2.13.0  固定 hysteria 版本(留空=追官方最新 2.x, 用官方 hashes.txt 校验)
#     XRAY_VERSION=26.3.27  SB_VERSION=1.14.4  固定内核版本(留空=追官方最新)
#     ALLOW_UNVERIFIED_BIN=1  跳过二进制校验(不推荐, 自定义版本时才需要)
#     CLEAN=1         安装前先彻底清理旧实例(解决端口被占用)
#     ASSUME_YES=1    全程不询问
# ============================================================
set -uo pipefail

# 默认 077: 新建文件只有 root 可读。凭据/私钥/临时配置散落在 /tmp 和 /etc,
# 默认 022 会让同机普通用户读到 UUID 与密码。需要公开的目录(订阅、证书)
# 在创建处显式 chmod, 不受这里影响。
umask 077

APP_NAME="proxy"
# 版本号必须和 tag 对得上 —— proxy update 靠它判断"本地是不是旧的"。
# 版本号: 对外唯一版本标识, 严格递增, 只增不减(1.0 -> 1.1 -> 1.2 ...)。
# proxy update 只比这个号判断新旧。v1.0 是重写后的单一发布基线, 变更记录见 CHANGELOG.md。
# 这次是"清掉旧历史、只留最新"的全新发布: 仓库从单一根提交重建, 没有需要
# 兼容的旧版, 所以版本回到 1.0 而不是 1.0.1 —— 版本号必须和 v1.0 tag 一致。
SCRIPT_VERSION="1.0"
BUILD_DATE="2026-11-27"
STATE_DIR="/etc/proxy-node"
STATE_FILE="${STATE_DIR}/state.env"
USERS_FILE="${STATE_DIR}/users.txt"
BACKUP_DIR="${STATE_DIR}/backup"
# 本脚本曾经放行过的防火墙端口(每行一个 port/proto)。换端口/关协议时靠它
# 把上一轮的规则撤掉, 否则旧端口会永久留在 ufw/firewalld 里。
FW_RULES="${STATE_DIR}/firewall.ports"
SUB_DIR="/var/www/proxy-sub"
LOG_FILE="/var/log/proxy-deploy.log"
REPO_URL="https://github.com/smallji666/proxy-node"
SCRIPT_URL="${REPO_URL}/raw/main/setup.sh"
# 国内直连规则数据源(纯域名清单)。proxy rule update 从这里拉取, 官方源优先,
# 不可达时退镜像且要求交叉核对, 与脚本自更新同一套安全模型(见 fetch_rules_verified)。
RULES_URL="${REPO_URL}/raw/main/cn-direct.txt"
# 一键命令。四条硬约束(改动前先读):
#   1) 下到 mktemp 临时文件, 不直接 -o 目标 —— 半截文件会顶掉磁盘上能用的那份
#   2) bash -n 过了才 install 到 /root, 再执行 —— 防半截文件/错误页
#   3) curl 必须带超时 —— 这是用户敲的第一条命令, 不能让他对着光标等 SYN
#   4) 必须落盘后再 bash —— 脚本用 readlink -f "$0" 找自己, 跑 /tmp 会把 proxy
#      软链指到 /tmp, 紧接着被 cleanup_stale_scripts 清掉
ONELINER="f=\$(mktemp)&&curl -fsSL --connect-timeout 10 -m 120 ${SCRIPT_URL} -o \"\$f\"&&bash -n \"\$f\"&&install -m755 \"\$f\" /root/setup-proxy.sh&&rm \"\$f\"&&bash /root/setup-proxy.sh"

# ---------------- 记录用户显式传入的环境变量 ----------------
# 未传时置为哨兵值, 以便 load_state 之后判断是否需要覆盖
_RAW_VLESS_PORT="${VLESS_PORT-__unset__}"
_RAW_HY2_PORT="${HY2_PORT-__unset__}"
_RAW_XRAY_VERSION="${XRAY_VERSION-__unset__}"
_RAW_HY2_VERSION="${HY2_VERSION-__unset__}"
_RAW_REALITY_DEST="${REALITY_DEST-__unset__}"
_RAW_ENABLE_OBFS="${ENABLE_OBFS-__unset__}"
_RAW_HY2_HOP="${HY2_HOP-__unset__}"
_RAW_HY2_INSECURE="${HY2_INSECURE-__unset__}"
_RAW_SUB_HTTP="${SUB_HTTP-__unset__}"
_RAW_SUB_PORT="${SUB_PORT-__unset__}"
_RAW_SUB_BIND="${SUB_BIND-__unset__}"
_RAW_NODE_NAME="${NODE_NAME-__unset__}"
_RAW_PROTOCOLS="${PROTOCOLS-__unset__}"
_RAW_SS2022_PORT="${SS2022_PORT-__unset__}"
_RAW_ANYTLS_PORT="${ANYTLS_PORT-__unset__}"
_RAW_TUIC_PORT="${TUIC_PORT-__unset__}"
_RAW_EGRESS="${EGRESS_URL-__unset__}"
_RAW_HY2_BW_UP="${HY2_BW_UP-__unset__}"
_RAW_HY2_BW_DOWN="${HY2_BW_DOWN-__unset__}"
_RAW_DEFAULT_NODE="${DEFAULT_NODE-__unset__}"
_RAW_REALITY_FP="${REALITY_FP-__unset__}"

# ---------------- 默认参数 ----------------
VLESS_PORT="${VLESS_PORT:-443}"
HY2_PORT="${HY2_PORT:-443}"
# Xray 默认追官方最新版, 不再锁死某个版本。解析逻辑在 resolve_xray_version:
#   - 用户显式 XRAY_VERSION=x.y.z   -> 固定该版本(可复现 / 回退用)
#   - 否则每次部署解析一次官方 release, 装最新; API 不通时沿用 state 里记录的
#     版本, 再用 XRAY_FALLBACK_VERSION 兜底(该版本内置哈希仍在 pinned_sha 里)
# 版本不是"锁死"的, 但哈希校验绝不省: 见 xray_sha_for / xray_dgst_sha。
XRAY_VERSION="${XRAY_VERSION:-latest}"
XRAY_FALLBACK_VERSION="26.3.27"
# Hysteria2 也改成默认追最新版, 与 Xray 同一套策略:
#   - 用户显式 HY2_VERSION=2.13.0 -> 固定该版本(可复现 / 回退用)
#   - 否则解析官方最新 release, 用官方 hashes.txt 动态取 SHA-256 校验
#   - API 不通时沿用本机版本, 再退 HY2_FALLBACK_VERSION(内置哈希仍在 pinned_sha)
# 只接受 2.x: 生成的服务端配置是 hysteria2 的格式, 一旦官方出 3.x 换了配置结构,
# 盲目追最新会直接把在跑的节点弄挂 —— 所以大版本不变才追, 变了就停在基线并告警。
HY2_VERSION="${HY2_VERSION:-latest}"
HY2_FALLBACK_VERSION="2.13.0"
# sing-box 同样默认追最新版, 但校验来源和前两个不一样, 所以单独说清楚:
#   官方从**不**发布 hashes.txt, 唯一的官方哈希来源是 GitHub Release API 里每个
#   asset 的 digest 字段(服务端对上传产物现算的 sha256:...)。已逐字节核对
#   1.14.4 的 linux-amd64 / linux-arm64 两个 digest 与脚本内置值完全一致,
#   说明它就是官方那份来源, 不是我们自算的。
#   - 用户显式 SB_VERSION=1.14.4 -> 固定该版本(可复现 / 回退用)
#   - 否则解析官方最新 release, 用 assets[].digest 动态校验
#   - API 不通时沿用本机版本, 再退 SB_FALLBACK_VERSION(内置哈希仍在 pinned_sha)
# 和前两个唯一的差别: sing-box 每个小版本都可能删改配置字段(1.11 弃用、1.12 删除
# legacy inbound 与 geoip), 所以换内核前会先用新二进制 check 一遍现有配置,
# 不通过就不换 —— 见 ensure_singbox 里的兼容闸门。追最新但不拿在跑的节点赌。
SB_VERSION="${SB_VERSION:-latest}"
SB_FALLBACK_VERSION="1.14.4"
REALITY_DEST="${REALITY_DEST:-}"
ENABLE_OBFS="${ENABLE_OBFS:-0}"
HY2_HOP="${HY2_HOP:-}"
HY2_INSECURE="${HY2_INSECURE:-0}"
# Hysteria2 Brutal 带宽(Mbps)。留空 = 用官方默认 BBR, 不主动抢带宽。
# 只有客户端订阅会用到这两个值, 服务端**不写 bandwidth** —— 官方文档明确说
# 自建自用可以删掉服务端 bandwidth, 由客户端指定即可; 服务端写了反而变成限速。
# 数值是"你这台客户端到 VPS 这条链路"的实际上下行, 不是 VPS 的标称带宽。
# 填高了会因补偿机制导致速度慢且不稳定, 填低了等于限速 —— 不确定就留空。
HY2_BW_UP="${HY2_BW_UP:-}"
HY2_BW_DOWN="${HY2_BW_DOWN:-}"
# 客户端订阅里默认选中的节点。reality = TCP/抗封锁优先(保持历史行为);
# hy2 = UDP/速度优先。只在确实启用了 hy2 时才允许切换, 不改服务端任何配置。
DEFAULT_NODE="${DEFAULT_NODE:-reality}"
# 客户端 uTLS 指纹。官方 REALITY 默认就是 chrome, 保持它 = 行为不变。
# 只有当你确认某客户端指纹不兼容时才改(白名单: chrome/firefox/safari/ios/
# android/edge/360/qq 等 Xray 内置值)。这是"可配置"而非"随机化" —— 随机换
# 指纹反而可能和伪装站行为对不上, 更容易被识别。
REALITY_FP="${REALITY_FP:-chrome}"
SUB_HTTP="${SUB_HTTP:-0}"
SUB_PORT="${SUB_PORT:-}"
SUB_BIND="${SUB_BIND:-127.0.0.1}"
CLEAN="${CLEAN:-0}"

# ======================= 客户端防护规则: 单一数据源 =======================
# 架构约定: 三端(小火箭/Clash/sing-box)的同一条防护规则只在这里声明一次,
# 由下面的 render_* 函数渲染成各端语法。改规则只改这里, 不允许在生成器里
# 再写一遍域名/端口 —— 历史上三份硬编码已经漂移过(Claude 域名清单 4 处
# 内容不一致), 单一数据源 + 校验器共用是防漂移的根本手段。
STUN_DOMAINS=(stun.l.google.com stun1.l.google.com stun2.l.google.com stun3.l.google.com stun4.l.google.com stun.services.mozilla.com stun.cloudflare.com)
STUN_WEBRTC_PORTS=(3478 5349 19302-19309)   # 区间用 -, 三端语法在 render_* 里各自转换
DNS_DOH_FOREIGN="https://cloudflare-dns.com/dns-query"
DNS_DOH_FOREIGN2="https://dns.google/dns-query"
DNS_DOH_CN="https://doh.pub/dns-query"
DNS_DOH_CN2="https://dns.alidns.com/dns-query"
DNS_CN_GEOSITE="geosite:cn,private"

# ---- 国内直连域名(单一数据源, 三端共用) ----
# 为什么要这份清单: GEOIP,CN 是 IP 规则, 加了 no-resolve 后域名请求根本不命中它,
# 国内站会一路掉到 FINAL 走代理 —— 表现为"国外正常, 淘宝/B站打不开"或属地显示境外。
# 必须用域名规则在 FINAL 之前兜住。三端语法不同(小火箭/Clash/JSON), 所以只在这里
# 存纯域名, 由 render_cn_* 各自渲染, 不允许在生成器里再写一份 —— 以前三份硬编码
# 已经漂移过, 这是防漂移的根本手段。
#
# 收录标准(比"多多益善"重要得多, 收错一个的代价是 DNS 直连泄露):
#   1) 100% 确定是境内服务, 且其 DNS 解析落在中国大陆。
#   2) 绝收境外域名 —— 一个境外域名进了这份名单, 它的 DNS 就会走国内明文,
#      属地检测立刻看到中国运营商, 比多漏几个国内站严重得多。
#   3) 关键词只收"独创品牌词", 绝不收短词/通用英文词:
#      oppo 会误伤 opposite.com, mi/vip/honor/dji/cn/com 更不能进 —— 那等于把
#      一大片境外域名判成国内直连。
# 清单可校准: proxy rule update 从官方源拉取更新, 用户也能自己加
# /etc/proxy-node/user-direct.txt(见 load_cn_direct), 两者都不用改脚本。
# 变量里只能放纯域名: 它是被 for 分词消费的, 任何 # 注释文字都会变成一条
# DOMAIN-SUFFIX 垃圾规则。分组只在这里说明, 变量内部按组换行, 不写 #。
#   第1组 电商   第2组 门户资讯  第3组 社区  第4组 视频音乐  第5组 搜索
#   第6组 支付金融  第7组 出行旅游  第8组 生活服务  第9组 招聘  第10组 汽车
#   第11组 科技企业  第12组 邮箱/运营商  第13组 物流  第14组 游戏  第15组 教育医疗
#   第16组 静态资源/CDN
# 第16组为什么必须单列: 国内站点的主域名和它的图片/JS/CSS 往往**不同域**
# (淘宝页面 taobao.com, 图片却在 alicdn.com)。本配置的 GEOIP,CN 带 no-resolve,
# 域名类请求根本不查 IP, 只认这份白名单 —— 主域名进了名单、资源域名没进, 结果
# 就是"页面能开, 图片转圈", 而且全部走代理白烧流量。这类域名只加确定的境内
# CDN(阿里/腾讯/百度/字节/网易/B站/知乎/小红书等), 不认识的宁可不加。
CN_DIRECT_SUFFIXES="
cn
taobao.com tmall.com jd.com jd.hk pinduoduo.com yangkeduo.com douyin.com kuaishou.com
xiaohongshu.com meituan.com dianping.com ele.me suning.com vip.com dewu.com smzdm.com
mogujie.com
baidu.com sina.com.cn sohu.com 163.com netease.com qq.com ifeng.com toutiao.com
people.com.cn xinhuanet.com cctv.com chinadaily.com.cn thepaper.cn
ithome.com qdaily.com sspai.com zaker.com
zhihu.com weibo.com bilibili.com douban.com hupu.com jianshu.com
lofter.com qidian.com
iqiyi.com youku.com mgtv.com ixigua.com ximalaya.com kugou.com kuwo.cn
qiyi.com douyu.com huya.com maoyan.com
sogou.com so.com qihoo.com youdao.com alidns.com dns.pub doh.pub
alipay.com tenpay.com unionpay.com 95516.com
icbc.com.cn abchina.com boc.cn ccb.com bankcomm.com cmbchina.com spdb.com.cn
citicbank.com cebbank.com cmbc.com.cn hxb.com.cn cib.com.cn psbc.com
pingan.com chinalife.com.cn cpic.com.cn
eastmoney.com dfcfw.com cailianpress.com tianyancha.com
ctrip.com qunar.com fliggy.com ly.com tuniu.com mafengwo.cn amap.com gaode.com
xiaojukeji.com
58.com ganji.com lianjia.com ke.com anjuke.com fang.com
zhaopin.com 51job.com lagou.com bosszhipin.com
autohome.com.cn bitauto.com dongchedi.com
dingtalk.com aliyun.com qcloud.com huaweicloud.com tencent.com
huawei.com vmall.com mi.com xiaomi.com oppo.com honor.com meizu.com dji.com
iflytek.com kingsoft.com wps.cn
meitu.com servicewechat.com snwx.com aaplimg.com hicloud.com
cainiao.com haier.com lenovo.com
126.com yeah.net 139.com 189.cn 10086.cn chinaunicom.com.cn
sf-express.com yto.net.cn sto.cn yundaex.com zto.com ems.com.cn
mihoyo.com
xueersi.com zuoyebang.com yuanfudao.com dxy.cn haodf.com
alicdn.com aliyuncs.com
bdstatic.com bstatic.com bdatu.com yunjiasu-cdn.net
gtimg.com qpic.cn qcloudimg.com myqcloud.com tencent-cloud.net
hdslb.com bilivideo.com acgvideo.com biliapi.net
zhimg.com xhscdn.com sinaimg.cn 360buyimg.com
pstatp.com snssdk.com byteimg.com douyinpic.com gifshow.com
qhimg.com qhres.com mi-img.com meituan.net dxycdn.com ykimg.com
cmbimg.com cctvpic.com 126.net 127.net 163yun.com
wangsu.com chinanetcenter.com
"
# jd.hk 是京东香港站: 域名后缀 .hk, 但服务主体和 DNS 都在境内, 实测直连更快。
# 重复域名在渲染时去重(见 load_cn_direct)。
# cainiao.com / haier.com / lenovo.com: 这几个品牌原先只在 CN_DIRECT_KEYWORDS
# (关键词兜底)里, 主域名没进后缀清单。mihomo 的 nameserver-policy 键不支持关键词
# 子串(只支持 +./*. 通配与 geosite), 于是 Clash 里它们走 DIRECT 路由却用境外 DoH
# = 路由/DNS 分裂。补进后缀清单让三端路由与 DNS 都覆盖, 消除这条漂移。
# (vipshop 关键词的主域名是 vip.com, 已在上面电商段, 不重复列。)
# 注意: 变量内部只能放域名, 不能写 # 注释 —— 遍历时按空格分词, # 不是注释符。

# 关键词兜底长尾国内域名: 零 DNS 查询, 但误伤面比后缀大, 所以只收"独创品牌词"。
# 绝不能收 58 / sto / ems / zto / wps / dxy 这类数字或通用缩写 —— 会误伤一大片
# 境外域名, 等于把它们的 DNS 也导到国内明文。这些只用后缀规则, 不做关键词。
CN_DIRECT_KEYWORDS="
taobao tmall pinduoduo meituan dianping eleme suning dewu smzdm vipshop
mogujie cainiao anjuke lianjia weibo douyin kuaishou xiaohongshu bilibili zhihu douban
jianshu hupu iqiyi youku ximalaya kugou kuwo netease sohu ifeng toutiao ixigua
baidu sogou qihoo youdao gaode alipay tenpay unionpay huawei xiaomi vmall meizu
iflytek kingsoft lenovo haier ctrip qunar fliggy tuniu mafengwo zhaopin lagou
bosszhipin autohome bitauto dongchedi mihoyo xueersi zuoyebang yuanfudao haodf
"

# 加载国内直连域名: 内置清单 + 用户自定义文件 + 远程更新文件。
# 用户文件一行一个域名, # 开头是注释; 只收合法域名(不收 IP/通配/路径), 非法行
# 跳过并 warn, 绝不让一行 "*.com" 之类的东西进配置。三份来源合并后去重。
# STATE_DIR 在脚本顶部已定义; 这里的 :- 兜底只为"单独抽取本块跑测试"时不被
# set -u 打断(测试不读写这两个文件, 兜底路径不会被真的创建)。
CN_DIRECT_FILE="${STATE_DIR:-/etc/proxy-node}/user-direct.txt"
CN_DIRECT_REMOTE_FILE="${STATE_DIR:-/etc/proxy-node}/remote-direct.txt"
# 合并去重后的生效域名(空格分隔)。顶层先声明, 避免 shellcheck 判"只读未赋值"。
CN_DIRECT_ACTIVE=""

load_cn_direct(){
  local f d
  CN_DIRECT_ACTIVE=""
  for d in $CN_DIRECT_SUFFIXES; do
    case " ${CN_DIRECT_ACTIVE} " in *" ${d} "*) continue ;; esac
    CN_DIRECT_ACTIVE="${CN_DIRECT_ACTIVE:+$CN_DIRECT_ACTIVE }${d}"
  done
  for f in "$CN_DIRECT_REMOTE_FILE" "$CN_DIRECT_FILE"; do
    [ -f "$f" ] || continue
    while IFS= read -r d || [ -n "$d" ]; do
      d="${d%%#*}"; d="${d//[[:space:]]/}"
      [ -n "$d" ] || continue
      d="${d,,}"
      # 只接受"后缀域名"形状: 至少一个点、无通配、无路径、无逗号(会破坏规则语法)。
      # 这里不能 warn —— 本函数被订阅生成器调用, warn 走 stdout 会污染配置内容。
      # 非法行只静默跳过, 需要提示时用 proxy rule check 显式检查文件。
      valid_domain "$d" || continue
      case " ${CN_DIRECT_ACTIVE} " in *" ${d} "*) continue ;; esac
      CN_DIRECT_ACTIVE="${CN_DIRECT_ACTIVE:+$CN_DIRECT_ACTIVE }${d}"
    done < "$f"
  done
  return 0
}

# 三端渲染。每次都现调 load_cn_direct, 保证用户刚加的域名立刻生效。
render_cn_sr_suffix(){
  load_cn_direct
  local d
  for d in $CN_DIRECT_ACTIVE; do echo "DOMAIN-SUFFIX,${d},DIRECT"; done
}
render_cn_sr_keyword(){
  local k
  for k in $CN_DIRECT_KEYWORDS; do echo "DOMAIN-KEYWORD,${k},DIRECT"; done
}
render_cn_clash(){
  load_cn_direct
  local d
  for d in $CN_DIRECT_ACTIVE; do echo "  - DOMAIN-SUFFIX,${d},DIRECT"; done
  local k
  for k in $CN_DIRECT_KEYWORDS; do echo "  - DOMAIN-KEYWORD,${k},DIRECT"; done
}
# sing-box 用 JSON 字符串数组。JSON 里域名不含需要转义的字符(valid_domain 保证)。
render_cn_sb_suffix(){
  load_cn_direct
  local d out=""
  for d in $CN_DIRECT_ACTIVE; do out="${out}\".${d}\","; done
  printf '%s' "${out%,}"
}
render_cn_sb_keyword(){
  local k out=""
  for k in $CN_DIRECT_KEYWORDS; do out="${out}\"${k}\","; done
  printf '%s' "${out%,}"
}

# DNS 分流专用: 国内直连域名的 DNS 必须也走国内解析, 否则会出现
# "域名走直连、DNS 却经代理出境外" 的分裂 —— 抖音的 CDN 域名
# (snssdk.com / byteimg.com / pstatp.com / douyinpic.com / gifshow.com)
# 不在 geosite:cn 里, 只配 geosite:cn 会让它们用境外 DoH, 拿到境外节点,
# 表现为 "开着 VPN 抖音打不开"。TikTok 等境外域名不在白名单, 仍走境外 DNS。
# 三端共用同一份 CN_DIRECT_ACTIVE, 避免路由规则与 DNS 规则漂移。
# Clash nameserver-policy 的键用 "+.domain" 通配(官方文档支持域名通配)。
render_cn_dns_clash(){
  load_cn_direct
  local d
  for d in $CN_DIRECT_ACTIVE; do echo "    '+.${d}':"; echo "      - ${DNS_DOH_CN}"; echo "      - ${DNS_DOH_CN2}"; done
}
# sing-box dns.rules 的 domain_suffix 数组; 与 route.rules 用同一份数据。
render_cn_dns_sb_suffix(){
  load_cn_direct
  local d out=""
  for d in $CN_DIRECT_ACTIVE; do out="${out}\".${d}\","; done
  printf '%s' "${out%,}"
}
# 关键词域名: sing-box dns.rules 的 domain_keyword 数组。
render_cn_dns_sb_keyword(){
  local k out=""
  for k in $CN_DIRECT_KEYWORDS; do out="${out}\"${k}\","; done
  printf '%s' "${out%,}"
}

# 渲染 STUN 域名为小火箭规则(REJECT-NO-DROP: 快速失败, 不等超时)
render_stun_sr(){
  local d
  for d in "${STUN_DOMAINS[@]}"; do echo "DOMAIN-SUFFIX,${d},REJECT-NO-DROP"; done
}
# 渲染 STUN 域名 + UDP 端口为 Clash 规则
render_stun_clash(){
  local d p
  for d in "${STUN_DOMAINS[@]}"; do echo "  - DOMAIN-SUFFIX,${d},REJECT"; done
  for p in "${STUN_WEBRTC_PORTS[@]}"; do echo "  - AND,((NETWORK,udp),(DST-PORT,${p})),REJECT"; done
}
# 渲染 STUN 域名为 sing-box 的 JSON 数组(供 route.rules.domain_suffix 用)
render_stun_sb_domains(){
  local d out=""
  for d in "${STUN_DOMAINS[@]}"; do
    out="${out}\"${d}\","
  done
  printf '%s' "${out%,}"
}
# 渲染 STUN 端口为 sing-box 的两个字段: 单端口走 "port", 区间走 "port_range"
# (语法不同, 区间用 : 而不是 -)。以前这里是一段手写的常量, 等于把
# STUN_WEBRTC_PORTS 抄了第二遍 —— 上面加一个端口、这里忘了改, sing-box 端就
# 少拦一个, WebRTC 照样漏真实 IP, 而三端"看起来"都配好了。现算, 永不漂移。
render_stun_sb_ports(){
  local p ports="" ranges=""
  for p in "${STUN_WEBRTC_PORTS[@]}"; do
    case "$p" in
      *-*) ranges="${ranges}\"${p/-/:}\", " ;;
      *)   ports="${ports}${p}, " ;;
    esac
  done
  # 分隔符用 ", " 而不是 ",": 与改造前手写的常量逐字节一致, 订阅产物不变。
  printf '"port": [%s], "port_range": [%s]' "${ports%, }" "${ranges%, }"
}
# 校验器: 从单一数据源算出"第一条 STUN 规则长什么样", 避免校验器里再硬编码一份
stun_sr_first(){ printf 'DOMAIN-SUFFIX,%s,REJECT-NO-DROP' "${STUN_DOMAINS[0]}"; }
stun_clash_first(){ printf '  - DOMAIN-SUFFIX,%s,REJECT' "${STUN_DOMAINS[0]}"; }
# ===================== 单一数据源结束 =====================

# REALITY 伪装目标 / 证书 CN 会进 JSON、分享链接和 openssl 命令行参数。
# 用户显式传的 REALITY_DEST 必须先是"一个域名", 否则带引号会写坏配置,
# 带空格/分号会拆开 openssl 的参数, 带 & 会在链接里多出参数。
valid_domain(){
  local d="${1:-}"
  [ -n "$d" ] && [ "${#d}" -le 253 ] || return 1
  case "$d" in
    *.*) ;;
    *) return 1 ;;
  esac
  case "$d" in
    # *. 不能漏: IFS=. 循环会吞掉尾部空字段, "a.com." 只会被切成 a / com,
    # 光靠逐段检查拦不住末尾的点。带尾点的绝对域名当 SNI / 证书 CN 会与
    # 客户端实际发的 SNI 对不上, REALITY 握手直接失败。
    # 模式顺序有讲究, 后面两个已被前面覆盖, 不再重复写:
    #   *-   已覆盖 *.-  (都以 - 结尾)
    #   *.   已覆盖 *-.  (都以 . 结尾)
    # 写成 `*-|*.-` 时 shellcheck 会报 SC2221/SC2222 —— 那不是误报, 是真的有
    # 两条永远匹配不到的模式, 留着只会让人以为多拦了一种情况。
    *[!A-Za-z0-9.-]*|*'..'*|.*|*.|*-) return 1 ;;
  esac
  # 每段都要有内容、不以 - 开头结尾
  local seg
  local IFS=.
  for seg in $d; do
    [ -n "$seg" ] || return 1
    case "$seg" in -*|*-) return 1 ;; esac
  done
  return 0
}

# uTLS 客户端指纹白名单。这个值会进 VLESS 分享链接的 fp= 参数和三份客户端
# 配置(JSON), 必须限制在 Xray uTLS 认识的取值内 —— 随便填会写坏链接/配置,
# 也可能被用来注入。留空按官方默认 chrome。
valid_reality_fp(){
  case "${1:-}" in
    chrome|firefox|safari|ios|android|edge|360|qq|random|randomized|"") return 0 ;;
    *) return 1 ;;
  esac
}

# 备注名会同时进 state.env(单引号包裹, 之后会被 source)、clash.yaml(双引号)、
# sing-box/xray 的 JSON 和分享链接。单引号能逃出 state.env 的引号被 load_state
# 当命令执行, $ ` ; | & 同理; " 和 \ 会写坏配置。这里统一去掉这些字符,
# 中英文、数字、空格(转 -)、点、下划线、连字符都保留。
sanitize_node_name(){
  local n
  n=$(printf '%s' "${1:-}" | tr -d '"\\' | tr -d "'" | tr -d '\000-\037\177' \
      | tr -d '$`;|&<>()!#' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$n" ] || n="Node"
  n="${n// /-}"
  # 节点名会进分享链接的 fragment 和客户端配置的 name 字段, 过长会让整条 URI
  # 超出部分客户端的长度上限。64 字符对正常命名足够, 超出直接截断。
  printf '%s' "${n:0:64}"
}
# 分享链接里 # 后面是 URI fragment。sanitize_node_name 只保证"不写坏 state.env
# 与配置", 不保证是合法 URI: 非 ASCII 字节和 '%' 都会让严格解析器拒收整条链接
# (节点名里写 "100%" 时, '%' 会被当成残缺的百分号转义)。按 RFC 3986 只保留
# unreserved 字符, 其余逐字节 %XX; 主流客户端会解码后显示原名字。
uri_fragment(){
  local s="${1:-}" out="" i=0 c n
  local LC_ALL=C
  while [ "$i" -lt "${#s}" ]; do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~\-]) out="${out}${c}" ;;
      *)
        n=$(printf '%d' "'$c" 2>/dev/null) || n=63
        n=$(( n & 255 ))
        printf -v c '%%%02X' "$n"
        out="${out}${c}" ;;
    esac
    i=$((i+1))
  done
  printf '%s' "$out"
}
NODE_NAME=$(sanitize_node_name "${NODE_NAME:-Node}")
ASSUME_YES="${ASSUME_YES:-0}"
# 协议组合, 逗号分隔. 默认与旧版行为一致(reality + hy2)
PROTOCOLS="${PROTOCOLS:-reality,hy2}"
SS2022_PORT="${SS2022_PORT:-8445}"
ANYTLS_PORT="${ANYTLS_PORT:-8444}"
TUIC_PORT="${TUIC_PORT:-8443}"
# 上游出口代理(住宅 IP / 中转), 形如 socks5://user:pass@host:port
EGRESS_URL="${EGRESS_URL:-}"

XRAY_BIN=/usr/local/bin/xray
XRAY_CFG=/usr/local/etc/xray/config.json
HY2_BIN=/usr/local/bin/hysteria
HY2_CFG=/etc/hysteria/config.yaml
SB_BIN=/usr/local/bin/sing-box
SB_CFG=/etc/sing-box/config.json
SB_CERT=/etc/sing-box/cert.pem
SB_KEY=/etc/sing-box/key.pem
SB_DIR=/etc/sing-box

# ---------------- 样式 ----------------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;36m'
M='\033[0;35m'; D='\033[0;90m'; N='\033[0m'

log_line(){
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}
info(){ echo -e "${B}[*]${N} $*"; log_line "INFO $*"; }
ok(){   echo -e "${G}[OK]${N} $*"; log_line "OK   $*"; }
warn(){ echo -e "${Y}[!]${N} $*"; log_line "WARN $*"; }
err(){  echo -e "${R}[X]${N} $*"; log_line "ERR  $*"; }
die(){  err "$*"; echo; err "部署中止。完整日志: ${LOG_FILE}"; exit 1; }
hr(){ echo -e "${D}------------------------------------------------------------${N}"; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "请用 root 运行"; }

# 安装/升级/重置/清理互斥。
# 一次安装要下载三个二进制, 慢的时候好几分钟; 用户以为卡住了就再开一个窗口重跑,
# 是很常见的事。两个进程会各自写 state.env(里面是 UUID 和私钥)、各自改 systemd
# 单元、各自往 iptables 里加规则, 最后留下哪一份取决于谁后退出 —— 最坏的情况是
# 凭据对不上, 客户端全部失效。
# 用 flock 而不是 mkdir 锁: flock 在进程退出(包括被 kill -9)时由内核释放, 不会
# 留下"僵尸锁"把用户挡在门外。拿不到锁就直接报错退出, 不排队等 —— 等待会让人
# 以为卡死, 而重跑一次的成本很低。
acquire_lock(){
  # 同一进程内幂等: main 已在命令行入口加过锁, cmd_clean / wizard 内部再加一次
  # 时不能在新 fd 上重复 flock(同进程另一 fd 会拿不到锁而误报"有人在装")。
  [ "${_PROXY_LOCK_HELD:-0}" = 1 ] && return 0
  # 路径可被 PROXY_LOCK_FILE 覆盖: 回归套件要在临时目录里验"锁被占时是否立刻失败",
  # 写死 /run 的话测试要么没权限、要么得动真文件, 只能跳过 —— 那等于没测。
  local lf="${PROXY_LOCK_FILE:-/run/proxy-node.lock}"
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>>"$lf" 2>/dev/null || return 0
  if flock -n 9; then _PROXY_LOCK_HELD=1; return 0; fi
  die "另一个 proxy 进程正在安装/升级(锁: ${lf})。等它结束后再试;
若确认没有别的进程在跑, 用 lsof ${lf} 查一下占用者"
}

# 协议开关: proto_on reality / proto_on ss2022 ...
proto_on(){
  case ",${PROTOCOLS}," in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}

# 规范化协议列表: 去空格, 去重, 校验合法性
normalize_protocols(){
  local raw="${1:-}" out="" p
  raw="${raw// /}"; raw="${raw//;/,}"
  local IFS=','
  for p in $raw; do
    [ -n "$p" ] || continue
    case "$p" in
      reality|hy2|ss2022|anytls|tuic) ;;
      *) die "未知协议: ${p} (可选: reality hy2 ss2022 anytls tuic)" ;;
    esac
    case ",${out}," in
      *",$p,"*) ;;
      *) out="${out:+${out},}${p}" ;;
    esac
  done
  unset IFS
  [ -n "$out" ] || die "PROTOCOLS 不能为空"
  PROTOCOLS="$out"
}

# 把协议组合归一化成固定顺序, 用于"协议是否变更"的比较。
# 直接比字符串会把 `hy2,reality` 和 `reality,hy2` 判成不同组合, 于是向导以为
# 用户换了协议 -> 触发 do_clean -> users.txt 被删、UUID 全部重生成, 所有客户端
# 一起失效。只是输入顺序不同而已, 绝对不能走到清理那一步。
canon_protocols(){
  local raw="${1:-}" out="" p
  raw="${raw// /}"; raw="${raw//;/,}"
  for p in reality hy2 ss2022 anytls tuic; do
    case ",${raw}," in *",${p},"*) out="${out:+${out},}${p}" ;; esac
  done
  printf '%s' "$out"
}

# 从终端读一行。
# 关键: read -p 的提示符走 stderr, 一旦调用方 2>/dev/null 就会把提示吞掉,
# 用户只看到光标不动 -> 误判为"卡死"。所以提示符必须自己写到 /dev/tty。
# 用法: read_tty "提示语" 变量名 [默认值]
read_tty(){
  local prompt="$1" __var="$2" __def="${3:-}" __ans="" __rc=0
  # 先屏蔽 stderr 再打开 /dev/tty: 打不开时 bash 的报错才不会污染输出
  if ! { printf '%b' "$prompt" 2>/dev/null >/dev/tty; }; then
    printf -v "$__var" '%s' "$__def"
    return 1
  fi
  IFS= read -r __ans 2>/dev/null </dev/tty || __rc=$?
  # read 返回 >128 是被信号打断(Ctrl-C = 130), 不是普通 EOF。以前一律当 EOF
  # 处理、把默认值塞回去继续跑: 用户在部署中途按了 Ctrl-C, 脚本却接着装完,
  # 这是最不能接受的一种"没停住"。这里显式退出, 让 EXIT trap 照常清理。
  if [ "$__rc" -gt 128 ]; then
    printf '\n' >/dev/tty 2>/dev/null || true
    exit "$__rc"
  fi
  if [ "$__rc" -ne 0 ]; then
    printf -v "$__var" '%s' "$__def"
    return 1
  fi
  [ -n "$__ans" ] || __ans="$__def"
  printf -v "$__var" '%s' "$__ans"
  return 0
}

ask_yes(){
  [ "$ASSUME_YES" = "1" ] && return 0
  local ans=""
  read_tty "${Y}?${N} $1 [y/N]: " ans "" || return 1
  case "$ans" in y|Y|yes|YES|是|好) return 0 ;; *) return 1 ;; esac
}

# ---------------- 状态持久化 ----------------
# state.env 是**数据**, 不是 shell 代码。
# 旧版用 echo "KEY='${VAL}'" 写、用 . "$STATE_FILE" 读: 只要某个值里
# 带一个单引号(EGRESS_URL / SUB_BIND / NODE_NAME 等都可能来自环境变量或手改),
# 写出来的就是一行合法 shell, 下次 load_state / healthcheck 以 root source 时
# 会执行里面的命令 —— 持久化的 RCE。本版起:
#   1) 写入: sh_quote 做单引号转义, 并把换行/控制字符换成空格;
#   2) 读取: 只按白名单键逐行解析成纯字符串, **绝不 source / eval**;
#   3) healthcheck / restore / do_clean 全部走同一套解析, 不留旁路。
# 格式仍是 KEY='value', 兼容旧安装与备份包。
STATE_KEYS="INSTALLED_AT XRAY_VERSION NODE_NAME SERVER_IP UUID PRIV PUB SID DEST VLESS_PORT HY2_PORT HY2_PASS ENABLE_OBFS OBFS_PASS HY2_HOP HY2_PIN HY2_INSECURE HY2_BW_UP HY2_BW_DOWN DEFAULT_NODE REALITY_FP CERT_SPKI_B64 CERT_HEX SUB_TOKEN SUB_PORT SUB_BIND SUB_HTTP PROTOCOLS SS2022_PORT ANYTLS_PORT TUIC_PORT SS2022_PASS ANYTLS_PASS TUIC_PASS TUIC_UUID XRAY_BIN_SHA HY2_BIN_SHA SB_BIN_SHA SB_PIN EGRESS_URL"

# 单引号转义: ' -> '\'' ; 换行/回车/制表符统一换成空格, 保证一行一个键。
sh_quote(){
  local s="${1-}"
  s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; s="${s//$'\t'/ }"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

# 还原 sh_quote 的结果。旧版/手改的未加引号行按纯字符串原样返回。
state_decode(){
  local s="${1-}"
  case "$s" in
    \'*\') s="${s#\'}"; s="${s%\'}"; s="${s//\'\\\'\'/\'}" ;;
  esac
  printf '%s' "$s"
}

state_line(){ printf '%s=%s\n' "$1" "$(sh_quote "${2-}")"; }

# 从 state.env 读一个键; 不存在返回 1。全程不执行文件内容。
state_get(){
  local f="${1:-$STATE_FILE}" k="${2:-}" ln
  [ -n "$k" ] && [ -f "$f" ] || return 1
  case " $STATE_KEYS " in *" $k "*) ;; *) return 1 ;; esac
  while IFS= read -r ln || [ -n "$ln" ]; do
    case "$ln" in "${k}="*) state_decode "${ln#*=}"; return 0 ;; esac
  done < "$f"
  return 1
}

# 所有状态标量都不许带控制字符/换行: 这类字符能跨行写坏 state.env、
# JSON 与 systemd unit。纯 bash 模式判断, 不引入管道。
safe_state_scalars(){
  local k v
  for k in $STATE_KEYS; do
    v="${!k-}"
    case "$v" in
      *[[:cntrl:]]*)
        warn "state.env / 环境变量里的 ${k} 含控制字符或换行, 已忽略该值"
        printf -v "$k" '%s' "" ;;
    esac
  done
  return 0
}

# 凭据会直接插进 Clash YAML / sing-box JSON / 分享链接 / systemd unit。
# 只清控制字符不够: 手改过的 state.env 或旧备份里带引号、空格、分号的值
# 会写坏配置甚至拼出额外参数。统一在读入后卡死字符集, 非法就丢弃重生成。
# SID / PRIV / PUB 虽然不是"密码", 但同样直插 REALITY 的 JSON 配置。
# 以前它们只在 apply_env_overrides 里校验环境变量来源, 从 state.env / 备份
# 恢复的值绕过了 safe_cred_scalars —— 带引号或逗号就能拼出额外 JSON 字段。
CRED_KEYS="HY2_PASS OBFS_PASS SS2022_PASS ANYTLS_PASS TUIC_PASS TUIC_UUID SB_PIN HY2_PIN CERT_SPKI_B64 CERT_HEX SUB_TOKEN SID PRIV PUB"
safe_cred_scalars(){
  local k v
  for k in $CRED_KEYS; do
    v="${!k-}"
    [ -n "$v" ] || continue
    case "$v" in
      *[!A-Za-z0-9_=+/-]*)
        # REALITY 的 shortId / 密钥不能像密码那样"清空重生成": ensure_creds
        # 只补缺项, 换掉 PUB 会连带换 PRIV, 所有已分发客户端瞬间失效 ——
        # 而脚本还会照常报"凭据已就绪", 用户根本不知道要重新导入全部设备。
        # 与其制造这种隐性故障, 不如停下来让人明确决定。
        case "$k" in
          SID|PRIV|PUB)
            die "state.env 里的 REALITY 凭据 ${k} 含非法字符。请人工核对 ${STATE_FILE}; 确认要重新生成则从文件中删掉 SID/PRIV/PUB 三项后重试(届时所有客户端需重新导入)。" ;;
        esac
        warn "凭据 ${k} 含不允许的字符(可能来自手改的 state.env), 已丢弃并重新生成"
        printf -v "$k" '%s' "" ;;
    esac
  done
  # EGRESS_URL 是 socks5:// URL, 用宽一点的白名单, 但绝不留 shell 元字符/引号/空格。
  # 正则放进变量: 字符类里的 & 直接写在 case 模式里会被 bash 当成控制符,
  # 整份脚本直接语法错。
  local _egress_ere='[^A-Za-z0-9_.:/?@=&%+-]'
  if [ -n "${EGRESS_URL:-}" ] && [[ "$EGRESS_URL" =~ $_egress_ere ]]; then
    warn "EGRESS_URL 含非法字符(空格/引号/shell 元字符), 已忽略"
    EGRESS_URL=""
  fi
  return 0
}

# 非法端口一律回退到该服务的默认值, 绝不能清空 —— 空值会被 validate_ports
# 的 [ -n ] 短路放行, 最后写出 "port": , 这种非法 JSON。单独成函数便于回归测试。
port_default(){
  case "${1:-}" in
    VLESS_PORT)  echo 443 ;;
    HY2_PORT)    echo 443 ;;
    SS2022_PORT) echo 8445 ;;
    ANYTLS_PORT) echo 8444 ;;
    TUIC_PORT)   echo 8443 ;;
    SUB_PORT)    echo "" ;;
    *)           echo "" ;;
  esac
}

# 监听地址会拼进 systemd 的 ExecStart 参数, 只允许地址字面量。
valid_bind(){
  local b="${1:-}" o
  [ -n "$b" ] && [ "${#b}" -le 45 ] || return 1
  # 先挡掉空格/引号/分号/斜杠等能拆开命令行或穿越路径的字符
  case "$b" in *[!A-Za-z0-9.:]*) return 1 ;; esac
  case "$b" in 127.0.0.1|0.0.0.0|::|::1|localhost) return 0 ;; esac
  case "$b" in
    *:*) case "$b" in *[!0-9A-Fa-f:]*|*:::*) return 1 ;; esac
         # 只验字符集会放过 :::: 或 9 组地址。冒号数 2-7 对应合法组数范围,
         # 连续三个冒号已在上面拒绝。
         local _col="${b//[^:]/}"
         [ "${#_col}" -ge 2 ] && [ "${#_col}" -le 7 ] || return 1
         return 0 ;;
  esac
  # IPv4 字面量: 必须四段, 每段 0-255 (光靠正则会放过 999.1.1.1)
  local IFS=.
  set -- $b
  [ "$#" -eq 4 ] || return 1
  for o in "$@"; do
    case "$o" in ''|*[!0-9]*) return 1 ;; esac
    # 与 valid_ipv4 同一条规则: 前导零的段一律拒绝(八进制歧义)。
    # 这个值会进 systemd 的 ExecStart, 写错了服务只会静默起不来。
    case "$o" in 0) ;; 0*) return 1 ;; esac
    [ "$o" -le 255 ] || return 1
  done
  return 0
}

load_state(){
  [ -f "$STATE_FILE" ] || return 1
  # 绝不 source / eval: 逐行按白名单键读成纯字符串。即便文件里被塞了
  # "'; rm -rf /; #" 也只是一段字符, 不会变成命令。
  local ln key val found=0
  while IFS= read -r ln || [ -n "$ln" ]; do
    case "$ln" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="${ln%%=*}"
    case " $STATE_KEYS " in *" $key "*) ;; *) continue ;; esac
    val=$(state_decode "${ln#*=}")
    printf -v "$key" '%s' "$val"
    found=1
  done < "$STATE_FILE"
  [ "$found" = "1" ] || return 1
  safe_state_scalars
  safe_cred_scalars
  # 老版本写进 state.env 的备注名可能带引号/反斜杠, 读回来必须再过一遍,
  # 否则 clash.yaml 里那行 name: "..." 会直接把整份 YAML 写坏
  NODE_NAME=$(sanitize_node_name "${NODE_NAME:-Node}")
  # DEST 会进证书 CN / JSON / 分享链接, 手改坏的值必须在这里就丢掉
  if [ -n "${DEST:-}" ] && ! valid_domain "$DEST"; then
    warn "state.env 里的 DEST 不是合法域名, 已忽略(重新挑选)"
    DEST=""
  fi
  # 全局统一兜底: 证书 CN / SNI / 分享链接 / 健康检查都直接用 $DEST,
  # 以前只在少数函数里局部兜底, 只开 ss/anytls/tuic 时会出现 CN=www.bing.com
  # 但 sni= 空、客户端连不上的不一致。
  DEST="${DEST:-www.bing.com}"
  SUB_BIND="${SUB_BIND:-127.0.0.1}"
  valid_bind "$SUB_BIND" || { warn "state.env 里的 SUB_BIND 不是合法监听地址, 改用 127.0.0.1"; SUB_BIND="127.0.0.1"; }
  return 0
}

save_state(){
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  # 先写临时再 mv: 中途失败不会留下被截断的 state.env。
  # 所有值统一过 sh_quote, 单引号/换行都不可能逃出这一行。
  local tmp
  tmp=$(mktemp "${STATE_DIR}/.state.XXXXXXXX") || die "无法创建 state.env 临时文件"
  # 安装时间先落到变量里再写文件。只在 state_line 里内联 $(date) 的话, 时间
  # 只进了文件、没进变量 —— 同一个进程后面再打印"安装时间"就是空的
  # (全新安装结束时 proxy install 会打印一次, 那时看着像丢了数据)。
  INSTALLED_AT="${INSTALLED_AT:-$(date '+%Y-%m-%d %H:%M:%S')}"
  {
    echo "# 由 proxy-installer 自动生成, 请勿手工编辑"
    echo "# 数据文件: 只按白名单键逐行解析, 从不被 source / eval"
    state_line INSTALLED_AT "${INSTALLED_AT:-}"
    state_line XRAY_VERSION "${XRAY_VERSION:-}"
    state_line NODE_NAME "${NODE_NAME:-Node}"
    state_line SERVER_IP "${SERVER_IP:-}"
    state_line UUID "${UUID:-}"
    state_line PRIV "${PRIV:-}"
    state_line PUB "${PUB:-}"
    state_line SID "${SID:-}"
    state_line DEST "${DEST:-}"
    state_line VLESS_PORT "${VLESS_PORT:-}"
    state_line HY2_PORT "${HY2_PORT:-}"
    state_line HY2_PASS "${HY2_PASS:-}"
    state_line ENABLE_OBFS "${ENABLE_OBFS:-}"
    state_line OBFS_PASS "${OBFS_PASS:-}"
    state_line HY2_HOP "${HY2_HOP:-}"
    state_line HY2_PIN "${HY2_PIN:-}"
    state_line HY2_INSECURE "${HY2_INSECURE:-}"
    state_line HY2_BW_UP "${HY2_BW_UP:-}"
    state_line HY2_BW_DOWN "${HY2_BW_DOWN:-}"
    state_line DEFAULT_NODE "${DEFAULT_NODE:-reality}"
    state_line REALITY_FP "${REALITY_FP:-chrome}"
    state_line CERT_SPKI_B64 "${CERT_SPKI_B64:-}"
    state_line CERT_HEX "${CERT_HEX:-}"
    state_line SUB_TOKEN "${SUB_TOKEN:-}"
    state_line SUB_PORT "${SUB_PORT:-}"
    state_line SUB_BIND "${SUB_BIND:-127.0.0.1}"
    state_line SUB_HTTP "${SUB_HTTP:-}"
    state_line PROTOCOLS "${PROTOCOLS:-}"
    state_line SS2022_PORT "${SS2022_PORT:-}"
    state_line ANYTLS_PORT "${ANYTLS_PORT:-}"
    state_line TUIC_PORT "${TUIC_PORT:-}"
    state_line SS2022_PASS "${SS2022_PASS:-}"
    state_line ANYTLS_PASS "${ANYTLS_PASS:-}"
    state_line TUIC_PASS "${TUIC_PASS:-}"
    state_line TUIC_UUID "${TUIC_UUID:-}"
    state_line XRAY_BIN_SHA "${XRAY_BIN_SHA:-}"
    state_line HY2_BIN_SHA "${HY2_BIN_SHA:-}"
    state_line SB_BIN_SHA "${SB_BIN_SHA:-}"
    state_line SB_PIN "${SB_PIN:-}"
    state_line EGRESS_URL "${EGRESS_URL:-}"
  } > "$tmp" || { rm -f "$tmp"; die "写入 state.env 失败"; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE" || { rm -f "$tmp"; die "写入 state.env 失败"; }
}

# 只改 state.env 里的一个键。
# 为什么不用 save_state: 它会把内存里所有变量整体写回去, 而 upgrade / 换内核这类
# 操作根本没有 load_state, 直接调 save_state 等于用一堆空值把凭据抹掉。
update_state_kv(){
  local k="${1:-}" v="${2:-}" f="$STATE_FILE" tmp ln found=0 newline
  [ -n "$k" ] || return 1
  case "$k" in *[!A-Z0-9_]*) return 1 ;; esac
  case " $STATE_KEYS " in *" $k "*) ;; *) return 1 ;; esac
  [ -f "$f" ] || return 1
  # 逐行重写, 不用 sed 替换串 —— 值里带 \ | & / 单引号时 sed 会解释成语法,
  # 之前正是这样把带引号的值写成了可执行的一行。
  newline="${k}=$(sh_quote "$v")"
  tmp=$(mktemp "$(dirname "$f")/.state.XXXXXXXX" 2>/dev/null) || return 1
  # 整份重定向并接住返回码。逐行 >> 不查错的话, 磁盘满 / 目录只读时截断的
  # 临时文件会被 mv 成 state.env, 等于把 UUID 与私钥弄丢一半。
  if ! {
    while IFS= read -r ln || [ -n "$ln" ]; do
      case "$ln" in
        "${k}="*) printf '%s\n' "$newline"; found=1 ;;
        *) printf '%s\n' "$ln" ;;
      esac
    done < "$f"
    [ "$found" = "1" ] || printf '%s\n' "$newline"
  } > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
  return 0
}

# load_state 之后, 把用户本次显式传入的环境变量覆盖回来
apply_env_overrides(){
  # _d 也要声明成 local: 漏了就会写进全局, 之后任何同名局部变量都会被它污染。
  local _k _v _d
  [ "$_RAW_VLESS_PORT"   != "__unset__" ] && VLESS_PORT="$_RAW_VLESS_PORT"
  [ "$_RAW_HY2_PORT"     != "__unset__" ] && HY2_PORT="$_RAW_HY2_PORT"
  # Xray 版本: 用户显式传了就固定; 没传则一律追最新, 不信任 state.env 里的
  # 历史值 —— 否则老机器 state 里存着 26.3.27, load_state 读回后又把新版锁死。
  # upgrade 写入 state 的版本也只当"当前已装版本"参考, 不阻止下次部署追最新。
  if [ "$_RAW_XRAY_VERSION" != "__unset__" ]; then
    XRAY_VERSION="$_RAW_XRAY_VERSION"
  else
    XRAY_VERSION="latest"
  fi
  # Hysteria2 同理: 没显式传就一律追最新, 不信任 state.env 里的历史值。
  # 否则老机器 state 存着 2.13.0, load_state 读回后又把新版锁死 —— 和 Xray
  # 当初那个"名义能升、实际卡死"的毛病一模一样。
  if [ "$_RAW_HY2_VERSION" != "__unset__" ]; then
    HY2_VERSION="$_RAW_HY2_VERSION"
  else
    HY2_VERSION="latest"
  fi
  [ "$_RAW_ENABLE_OBFS"  != "__unset__" ] && ENABLE_OBFS="$_RAW_ENABLE_OBFS"
  [ "$_RAW_HY2_HOP"      != "__unset__" ] && HY2_HOP="$_RAW_HY2_HOP"
  [ "$_RAW_HY2_INSECURE" != "__unset__" ] && HY2_INSECURE="$_RAW_HY2_INSECURE"
  [ "$_RAW_SUB_HTTP"     != "__unset__" ] && SUB_HTTP="$_RAW_SUB_HTTP"
  [ "$_RAW_SUB_PORT"     != "__unset__" ] && SUB_PORT="$_RAW_SUB_PORT"
  if [ "$_RAW_SUB_BIND" != "__unset__" ]; then
    if valid_bind "$_RAW_SUB_BIND"; then SUB_BIND="$_RAW_SUB_BIND"
    else warn "SUB_BIND='${_RAW_SUB_BIND}' 不是合法监听地址, 已忽略(沿用 ${SUB_BIND})"; fi
  fi
  [ "$_RAW_PROTOCOLS"    != "__unset__" ] && PROTOCOLS="$_RAW_PROTOCOLS"
  [ "$_RAW_SS2022_PORT"  != "__unset__" ] && SS2022_PORT="$_RAW_SS2022_PORT"
  [ "$_RAW_ANYTLS_PORT"  != "__unset__" ] && ANYTLS_PORT="$_RAW_ANYTLS_PORT"
  [ "$_RAW_TUIC_PORT"    != "__unset__" ] && TUIC_PORT="$_RAW_TUIC_PORT"
  [ "$_RAW_EGRESS"       != "__unset__" ] && EGRESS_URL="$_RAW_EGRESS"
  if [ "$_RAW_HY2_BW_UP" != "__unset__" ]; then
    if [ -z "$_RAW_HY2_BW_UP" ] || hy2_bw_ok "$_RAW_HY2_BW_UP"; then HY2_BW_UP="$_RAW_HY2_BW_UP"
    else warn "HY2_BW_UP='${_RAW_HY2_BW_UP}' 非法, 已忽略"; fi
  fi
  if [ "$_RAW_HY2_BW_DOWN" != "__unset__" ]; then
    if [ -z "$_RAW_HY2_BW_DOWN" ] || hy2_bw_ok "$_RAW_HY2_BW_DOWN"; then HY2_BW_DOWN="$_RAW_HY2_BW_DOWN"
    else warn "HY2_BW_DOWN='${_RAW_HY2_BW_DOWN}' 非法, 已忽略"; fi
  fi
  [ "$_RAW_DEFAULT_NODE" != "__unset__" ] && DEFAULT_NODE="$_RAW_DEFAULT_NODE"
  # 指纹: 环境变量显式传入或 state.env 读回后都过白名单, 非法一律回退 chrome。
  if [ "$_RAW_REALITY_FP" != "__unset__" ]; then REALITY_FP="$_RAW_REALITY_FP"; fi
  if ! valid_reality_fp "$REALITY_FP"; then
    warn "REALITY_FP='${REALITY_FP}' 不是 Xray 认识的指纹, 已回退 chrome"
    REALITY_FP="chrome"
  fi
  [ -z "${REALITY_FP:-}" ] && REALITY_FP="chrome"
  if [ "$_RAW_NODE_NAME" != "__unset__" ]; then
    NODE_NAME=$(sanitize_node_name "$_RAW_NODE_NAME")
  fi
  # 显式指定伪装站时, 丢弃旧值重新挑选验证。
  # random 是保留字(重新随机挑), 其余必须是合法域名 —— 它会进 JSON、链接与 openssl 参数。
  if [ "$_RAW_REALITY_DEST" != "__unset__" ]; then
    if [ "$_RAW_REALITY_DEST" = "random" ] || valid_domain "$_RAW_REALITY_DEST"; then
      REALITY_DEST="$_RAW_REALITY_DEST"
      DEST=""
    else
      warn "REALITY_DEST='${_RAW_REALITY_DEST}' 不是合法域名, 已忽略(改用自动挑选)"
    fi
  fi
  # state.env 里读回来的 DEST 同样要过一遍: 手改坏的值会写进证书 CN 和分享链接。
  if [ -n "${DEST:-}" ] && ! valid_domain "$DEST"; then
    warn "state.env 里的 DEST 不是合法域名, 已忽略(重新挑选)"
    DEST=""
  fi
  # 端口在 validate_ports 里还会再查一次并去掉前导零; 这里先拦住明显不是
  # 数字的值, 免得它们先被写进 state.env / 订阅链接 / JSON。
  # 非法值必须回退默认值: 以前是清空, 结果 validate_ports 因为 [ -n ] 直接
  # 放行空值, 最后写出 "port": , 这种 xray/sing-box 都解析不了的 JSON。
  for _k in VLESS_PORT HY2_PORT SS2022_PORT ANYTLS_PORT TUIC_PORT SUB_PORT; do
    _v="${!_k-}"
    # 空值也要回退默认值(SUB_PORT 除外, 空=随机): 用户显式写 VLESS_PORT=
    # 时 _RAW 是空串, 下面两处校验都会因 [ -n ] 跳过, 最后写出 "port": ,。
    if [ -z "$_v" ]; then
      _d=$(port_default "$_k")
      [ -n "$_d" ] && printf -v "$_k" '%s' "$_d"
      continue
    fi
    if ! valid_port "$_v"; then
      _d=$(port_default "$_k")
      warn "${_k}='${_v}' 不是合法端口, 已改用默认值 ${_d:-随机}"
      printf -v "$_k" '%s' "$_d"
    fi
  done
  # HY2_HOP 会同时进 state.env、分享链接(&mport)、clash.yaml、singbox.json
  # 和 hy2-hop.service。只在 setup_hy2_hop 里判格式太晚: 非法值早就被拼进
  # 链接与订阅里了。这里统一清掉, 让所有下游看到的值都是干净的。
  if [ -n "${HY2_HOP:-}" ]; then
    local _hs _he _hop_bad=0
    # 必须恰好一个 '-': 原来直接用 %%-* / ##*- 截取, 遇到 20000-30000-40000
    # 这种多段值会取首尾两段, 中间的被静默忽略, 一个畸形值就被当成合法区间
    # 拼进链接和 service。这里先把"多段"和"无区间"挡掉, 再做数字校验。
    case "$HY2_HOP" in
      *-*-*) _hop_bad=1 ;;
      *-*)   : ;;
      *)     _hop_bad=1 ;;
    esac
    if [ "$_hop_bad" = "0" ]; then
      _hs="${HY2_HOP%%-*}"; _he="${HY2_HOP##*-}"
      case "${_hs}${_he}" in
        ''|*[!0-9]*) _hop_bad=1 ;;
      esac
    fi
    if [ "$_hop_bad" = "0" ]; then
      # start==end 不是区间; 起点必须 <= 终点。
      [ "$_hs" != "$_he" ] || _hop_bad=1
      valid_port "$_hs" || _hop_bad=1
      valid_port "$_he" || _hop_bad=1
    fi
    if [ "$_hop_bad" = "0" ] && [ "$((10#$_hs))" -gt "$((10#$_he))" ]; then
      _hop_bad=1
    fi
    if [ "$_hop_bad" = "1" ]; then
      warn "HY2_HOP='${HY2_HOP}' 不是合法的端口区间(应为 20000-30000), 已忽略"
      HY2_HOP=""
    fi
  fi
  safe_state_scalars
  safe_cred_scalars
  return 0
}

backup_config(){
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local ts; ts=$(date +%Y%m%d%H%M%S)
  [ -f "$XRAY_CFG" ] && cp -f "$XRAY_CFG" "$BACKUP_DIR/xray-${ts}.json" 2>/dev/null
  [ -f "$HY2_CFG" ]  && cp -f "$HY2_CFG"  "$BACKUP_DIR/hy2-${ts}.yaml" 2>/dev/null
  # sing-box 也留一份: 重装/换协议时它会被整份重写, 写坏了得有东西能对照
  [ -f "$SB_CFG" ]   && cp -f "$SB_CFG"   "$BACKUP_DIR/singbox-${ts}.json" 2>/dev/null
  ls -1t "$BACKUP_DIR"/xray-*.json 2>/dev/null | tail -n +6 | xargs -r rm -f
  ls -1t "$BACKUP_DIR"/hy2-*.yaml  2>/dev/null | tail -n +6 | xargs -r rm -f
  ls -1t "$BACKUP_DIR"/singbox-*.json 2>/dev/null | tail -n +6 | xargs -r rm -f
}

# ---------------- 系统探测 ----------------
PKG=""
detect_pkg(){
  if command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PKG=yum
  else die "未识别的包管理器(需要 apt/dnf/yum)"; fi
}

install_deps(){
  info "安装依赖 (curl unzip openssl iptables)..."
  local rc=0
  if [ "$PKG" = apt ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || rc=1
    [ "$rc" = "0" ] && { apt-get install -y -qq curl unzip openssl ca-certificates iptables >/dev/null 2>&1 || rc=1; }
  else
    $PKG install -y -q curl unzip openssl ca-certificates iptables >/dev/null 2>&1 || rc=1
  fi
  # 不直接 die: 镜像常常已经预装了全部依赖, 让下面逐项校验来判。
  # 但必须说一声, 否则源坏了也会一路报"依赖就绪", 最后把下载失败归咎于 GitHub。
  [ "$rc" = "0" ] || warn "包管理器执行失败(软件源不可达 / 锁占用 / 磁盘满), 改用本机已有命令继续校验"
  local missing="" c
  for c in curl unzip openssl; do
    command -v "$c" >/dev/null 2>&1 || missing="${missing} ${c}"
  done
  # 缺 CA 根证书时所有 https 下载都会报证书错, 却会被误判成"服务器访问不了 GitHub"
  if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -f /etc/pki/tls/certs/ca-bundle.crt ]; then
    missing="${missing} ca-certificates"
  fi
  [ -z "$missing" ] || die "缺少必需依赖:${missing} —— 先修好系统软件源再重跑 (apt-get update / dnf makecache)"
  # iptables 不是硬依赖: 用 nftables 或云安全组的机器没有它也能装, 但本机防火墙
  # 那一段就托管不了, 得明确提示而不是静默不放行端口。
  command -v iptables >/dev/null 2>&1 || warn "未找到 iptables, 本机防火墙不会被托管; 请确认云安全组已放行代理端口"
  if ! command -v qrencode >/dev/null 2>&1; then
    if [ "$PKG" = apt ]; then apt-get install -y -qq qrencode >/dev/null 2>&1 || true
    else $PKG install -y -q qrencode >/dev/null 2>&1 || true; fi
  fi
  ok "依赖就绪"
}

get_server_ip(){
  local ip="" o
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
       | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [ -z "$ip" ] || echo "$ip" | grep -qE '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'; then
    ip=$(curl -s4 --max-time 10 https://api.ipify.org 2>/dev/null \
      || curl -s4 --max-time 10 https://ifconfig.me 2>/dev/null || echo "")
  fi
  # 以前只做 tr -d '[:space:]': captive portal / 错误页 / 超时残留会被压成
  # 一长串文本写进 SERVER_IP, 订阅与分享链接全指向垃圾地址。必须是合法 IPv4。
  # 统一走 valid_ipv4: 以前这里内联一份校验, 漏了尾点/双点, 异常响应会把
  # "1.2.3.4." 之类写进 SERVER_IP, 污染订阅和链接。
  ip=$(printf '%s' "$ip" | tr -d '[:space:]')
  valid_ipv4 "$ip" || ip=""
  printf '%s' "$ip"
}

# 端口参数必须是 1-65535 的整数。写错的话 xray / sing-box 只会回一句
# "failed to load config", 用户根本看不出是哪个变量错了, 所以提前拦。
valid_port(){
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

validate_ports(){
  local p v tl="" ul="" dup
  for p in VLESS_PORT HY2_PORT SS2022_PORT ANYTLS_PORT TUIC_PORT SUB_PORT; do
    v="${!p:-}"
    [ -n "$v" ] || continue
    valid_port "$v" || die "${p}=\"${v}\" 不合法, 端口必须是 1-65535 的整数"
    # 去掉前导零: 0443 会让 JSON 里出现 "port": 0443, 而 JSON 不允许前导零,
    # xray/sing-box 会直接报配置解析失败
    printf -v "$p" '%d' "$((10#$v))"
  done

  # 同协议族里端口撞车, 第二个服务必然 bind 失败, 提前拦住
  proto_on reality && tl="${tl} ${VLESS_PORT}:Reality"
  proto_on ss2022  && tl="${tl} ${SS2022_PORT}:SS2022" && ul="${ul} ${SS2022_PORT}:SS2022"
  proto_on anytls  && tl="${tl} ${ANYTLS_PORT}:AnyTLS"
  # TUIC v5 只跑 UDP(QUIC): 不占 TCP, 也不该跟 TCP 服务撞端口
  proto_on tuic    && ul="${ul} ${TUIC_PORT}:TUIC"
  proto_on hy2     && ul="${ul} ${HY2_PORT}:HY2"
  if [ "$SUB_HTTP" = "1" ] && [ -n "${SUB_PORT:-}" ]; then tl="${tl} ${SUB_PORT}:订阅"; fi

  dup=$(printf '%s\n' $tl | awk -F: 'NF{print $1}' | sort | uniq -d | head -1)
  [ -z "$dup" ] || die "TCP 端口 ${dup} 被多个服务占用: $(printf '%s\n' $tl | awk -F: -v p="$dup" '$1==p{printf "%s ", $2}')"
  dup=$(printf '%s\n' $ul | awk -F: 'NF{print $1}' | sort | uniq -d | head -1)
  [ -z "$dup" ] || die "UDP 端口 ${dup} 被多个服务占用: $(printf '%s\n' $ul | awk -F: -v p="$dup" '$1==p{printf "%s ", $2}')"
  return 0
}

port_in_use(){
  local proto="${2:-tcp}" flag="-tln" out
  [ "$proto" = "udp" ] && flag="-uln"
  # pipefail 下 grep -q 命中就退出, ss/awk 会吃 SIGPIPE 令整条管道判失败,
  # 结果是"端口明明被占用却查成没占用"。ensure_xray 那段注释里踩过同一个坑。
  # awk 不提前 exit, 读完整个输入, ss 才不会收到 SIGPIPE。
  out=$(ss "$flag" 2>/dev/null | awk -v p="${1}" '$4 ~ "[:.]" p "$" {print "1"}') || return 1
  [ -n "$out" ]
}

# 占用端口的进程, 输出 "名字(pid)"; 查不到返回空
port_owner(){
  local proto="${2:-tcp}" flag="-tlnp" out
  [ "$proto" = "udp" ] && flag="-ulnp"
  out=$(ss "$flag" 2>/dev/null | awk -v p=":${1}" '$4 ~ (p "$") {print $NF; exit}')
  [ -n "$out" ] || return 1
  echo "$out" | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1(\2)/p'
}

kill_port_owner(){
  local proto="${2:-tcp}" flag="-tlnp" pid
  [ "$proto" = "udp" ] && flag="-ulnp"
  pid=$(ss "$flag" 2>/dev/null | awk -v p=":${1}" '$4 ~ (p "$") {print $NF; exit}' \
        | sed -n 's/.*pid=\([0-9]*\).*/\1/p')
  [ -n "$pid" ] || return 1
  kill "$pid" 2>/dev/null || true
  sleep 1
  kill -9 "$pid" 2>/dev/null || true
  return 0
}

# ---------------- 下载 ----------------
# 官方发布产物的 SHA-256, 按 "工具-架构" 索引。
# 为什么要硬编码: 下载失败时会退回 ghfast.top / gh-proxy.com 这类第三方镜像,
# 光比对"镜像自己给的哈希"没有任何意义(两个都能被换)。只有把期望值写死在脚本里,
# 镜像投毒/中间人换包才会在安装前就失败。
# 取值来源: Xray 的 *.dgst、hysteria 的 hashes.txt(均已逐字节核对);
# sing-box 不发校验文件, 取的是 GitHub Release API 里 assets[].digest
# (已核对 1.14.4 的 amd64/arm64 与官方 digest 完全一致), 见 sb_api_sha。
# 这里的内置值不是"唯一来源", 而是"离线兜底 + 防篡改基准": 官方值取不到时用它,
# 取到了就拿来和官方值比对, 不一致直接拒绝。
pinned_sha(){
  case "$1" in
    xray-64-26.3.27)       echo "23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae" ;;
    xray-arm64-26.3.27)    echo "4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c" ;;
    hy2-amd64-2.13.0)      echo "907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691" ;;
    hy2-arm64-2.13.0)      echo "a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7" ;;
    singbox-amd64-1.14.4)  echo "699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968" ;;
    singbox-arm64-1.14.4)  echo "436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26" ;;
    *)                     echo "" ;;
  esac
}

# 从官方 release 的 .dgst 文件解析指定资产的 SHA-256。
# 解析方式与 Xray 官方 install-release.sh 完全一致: awk -F '= ' '/256=/ {print $2}'。
# 返回空 = 拿不到(网络不通 / 老版本无校验文件 / 错误页), 交由上层回退。
xray_dgst_sha(){
  local url="$1" tmp dg
  tmp=$(mktemp 2>/dev/null) || return 0
  if ! curl -fsSL --connect-timeout 10 --max-time 40 -H 'Cache-Control: no-cache' \
       -o "$tmp" "$url" 2>/dev/null; then
    rm -f "$tmp"; return 0
  fi
  dg=$(awk -F '= ' '/256=/ {print $2}' "$tmp" 2>/dev/null | head -1 | tr -d ' \t\r\n')
  rm -f "$tmp"
  case "$dg" in ''|*[!0-9a-fA-F]*) return 0 ;; esac
  [ "${#dg}" -eq 64 ] || return 0
  printf '%s' "$dg"
}

# 从 sha256sum 格式的校验文件(如 hysteria 的 hashes.txt)里取指定资产的哈希。
# 行格式: `<64hex>  build/hysteria-linux-amd64`
#   - 路径带 build/ 前缀, 所以按 basename 比对, 不写死整条路径
#   - sha256sum 的二进制模式会在路径前多一个 `*`, 要剥掉
#   - 老版本 coreutils 可能用单空格分隔, 所以不依赖列数, 只认 $1=hash / $2=path
# 返回空 = 拿不到 / 文件里没这个资产 / 格式不对, 一律交由上层回退, 绝不猜。
sha_from_sumfile(){
  local url="$1" want="$2" tmp got
  [ -n "$want" ] || return 0
  tmp=$(mktemp 2>/dev/null) || return 0
  if ! curl -fsSL --connect-timeout 10 --max-time 40 -H 'Cache-Control: no-cache' \
       -o "$tmp" "$url" 2>/dev/null; then
    rm -f "$tmp"; return 0
  fi
  got=$(awk -v want="$want" '
    {
      h = $1; f = $2
      if (h == "" || f == "") next
      sub(/^\*/, "", f)              # 二进制模式的 * 前缀
      n = split(f, seg, "/")
      if (f == want || seg[n] == want) { print h; exit }
    }' "$tmp" 2>/dev/null | head -1 | tr -d ' \t\r\n')
  rm -f "$tmp"
  case "$got" in ''|*[!0-9a-fA-F]*) return 0 ;; esac
  [ "${#got}" -eq 64 ] || return 0
  printf '%s' "$got"
}

# 某版本某资产的期望 SHA-256: 官方 .dgst 优先, 内置值兜底。
# 之所以能从官方动态取: Xray 每个 release 都附带 .dgst, 官方安装脚本本身就是
# 这么校验的 —— 这就解开了"想升级到新版但脚本里没内置该版本哈希"的死结。
# 安全约束:
#   1) 官方 .dgst 与内置值都在且不一致 -> 拒绝, 不自动放行可疑二进制
#   2) 官方不可达 -> 两个镜像的 .dgst 必须一致才采用(挡单镜像投毒)
#   3) 都拿不到 -> 用内置值(仅已知版本有); 仍为空则 verify_sha256 按策略拒绝
#
# 本函数的 stdout 只有一个 64 位 hex —— 调用方是 `_want_sha=$(xray_expected_sha ...)`。
# 所以里面的所有提示必须写 stderr: info/ok/warn/err 默认都走 stdout, 一旦漏一条,
# 提示文字就会拼进哈希串, verify_sha256 拿它去比对必然不等, 于是"官方被墙、镜像
# 能用"这种最常见的情况下反而装不上, 还只报一句莫名的"校验未通过"。
xray_expected_sha(){
  local ver="$1" sha_arch="$2" asset="$3"
  local builtin dg_off dg_a dg_b
  builtin=$(pinned_sha "xray-${sha_arch}-${ver}")
  local base="https://github.com/XTLS/Xray-core/releases/download/v${ver}"

  dg_off=$(xray_dgst_sha "${base}/${asset}.dgst")
  if [ -z "$dg_off" ]; then
    dg_a=$(xray_dgst_sha "https://ghfast.top/${base}/${asset}.dgst")
    dg_b=$(xray_dgst_sha "https://gh-proxy.com/${base}/${asset}.dgst")
    if [ -n "$dg_a" ] && [ -n "$dg_b" ] && [ "$dg_a" = "$dg_b" ]; then
      dg_off="$dg_a"
      ok "官方校验文件不可达, 已用两个镜像交叉核对 Xray v${ver} 哈希" >&2
    fi
  fi

  if [ -n "$dg_off" ]; then
    if [ -n "$builtin" ] && [ "$dg_off" != "$builtin" ]; then
      # 这条 return 1 后调用方会 die, 但 die 的话术是"校验值获取失败",
      # 真正的原因(官方值与内置值不一致)必须打出来, 否则无从核对。
      err "Xray v${ver} 官方校验值与脚本内置值不一致, 拒绝安装:" >&2
      err "  官方 .dgst: ${dg_off}" >&2
      err "  内置      : ${builtin}" >&2
      err "  请人工核对官方 release 页后再决定, 不自动放行" >&2
      return 1
    fi
    printf '%s' "$dg_off"
    return 0
  fi
  if [ -n "$builtin" ]; then
    warn "官方校验文件不可达, 改用脚本内置哈希校验 Xray v${ver}" >&2
    printf '%s' "$builtin"
    return 0
  fi
  return 0
}

# Hysteria2 的期望 SHA-256: 官方 hashes.txt 优先, 内置值兜底。
# 结构与 xray_expected_sha 完全一致(同样的三道安全约束、同样的 stderr 规矩),
# 只是校验文件的格式不同: hysteria 用 sha256sum 风格的 hashes.txt,
# 路径带 build/ 前缀, 由 sha_from_sumfile 按 basename 匹配。
#
# 为什么不能只靠内置值: 内置值只在"已知版本"上存在, 官方一发新版就装不上,
# 和 Xray 当初锁死 26.3.27 是同一个死结。hashes.txt 从 v2.13.0 起就有, 已核对
# 2.13.0 的 amd64/arm64 两个值与脚本内置值完全一致, 说明它就是官方那份来源。
#
# stdout 只输出 64 位 hex, 所有提示一律 >&2 —— 调用方是 $(hy2_expected_sha ...)。
hy2_expected_sha(){
  local ver="$1" sha_arch="$2" asset="$3"
  local builtin dg_off dg_a dg_b
  builtin=$(pinned_sha "hy2-${sha_arch}-${ver}")
  local base="https://github.com/HyNetworks/hysteria/releases/download/app/v${ver}"

  dg_off=$(sha_from_sumfile "${base}/hashes.txt" "$asset")
  if [ -z "$dg_off" ]; then
    dg_a=$(sha_from_sumfile "https://ghfast.top/${base}/hashes.txt" "$asset")
    dg_b=$(sha_from_sumfile "https://gh-proxy.com/${base}/hashes.txt" "$asset")
    if [ -n "$dg_a" ] && [ -n "$dg_b" ] && [ "$dg_a" = "$dg_b" ]; then
      dg_off="$dg_a"
      ok "官方校验文件不可达, 已用两个镜像交叉核对 Hysteria2 v${ver} 哈希" >&2
    fi
  fi

  if [ -n "$dg_off" ]; then
    if [ -n "$builtin" ] && [ "$dg_off" != "$builtin" ]; then
      err "Hysteria2 v${ver} 官方校验值与脚本内置值不一致, 拒绝安装:" >&2
      err "  官方 hashes.txt: ${dg_off}" >&2
      err "  内置           : ${builtin}" >&2
      err "  请人工核对官方 release 页后再决定, 不自动放行" >&2
      return 1
    fi
    printf '%s' "$dg_off"
    return 0
  fi
  if [ -n "$builtin" ]; then
    warn "官方校验文件不可达, 改用脚本内置哈希校验 Hysteria2 v${ver}" >&2
    printf '%s' "$builtin"
    return 0
  fi
  return 0
}

# 从 GitHub Release API 的 assets[].digest 里取指定资产的 SHA-256。
#
# 为什么 sing-box 只能用这条路: 它官方从不发布 hashes.txt / .dgst 之类的校验文件
# (1.14.4 的 168 个资产里一个都没有), 但 GitHub 在 release 元数据里给每个资产都
# 带了一个 digest 字段(sha256:<64hex>), 由 GitHub 服务端对上传的文件现算。它和
# 脚本内置值逐字节一致, 所以是可用的官方来源, 不是我们自算的"自己证明自己"。
#
# 解析方式: 资产对象是平铺 JSON, 元素之间是 `},{`, 而对象内部的 uploader 是嵌套
# 对象(它后面跟的是 `,"content_type"`, 不会出现 `},{`), 所以按 `},{` 切分不会
# 串行。不引 jq / python —— VPS 上不一定有, 而且这里只需要一个字段。
#
# 切分前必须把**所有空白**都去掉: 原始响应是缩进过的, 只删换行会留下
# `}      ,      {`, 按 `},{` 切一刀都切不开(第一版就是这么写成空值的, 结果
# 静默退回内置哈希, 看起来"能用", 实际动态校验根本没生效)。资产名和 digest
# 里都不含空白, 整体去空白不会影响要匹配的字段。
#
# 匹配必须带引号卡死全名: 资产名互为前缀(…-linux-arm64.tar.gz 与
# …-linux-arm64-glibc.tar.gz), 只做子串匹配会取到别的资产。
# 返回空 = 拿不到(API 不通 / 该 tag 不存在 / 资产名对不上), 交由上层回退, 绝不猜。
sb_api_sha(){
  local ver="$1" asset="$2" tmp dg
  [ -n "$ver" ] && [ -n "$asset" ] || return 0
  tmp=$(mktemp 2>/dev/null) || return 0
  if ! curl -fsSL --connect-timeout 10 --max-time 40 -H 'Cache-Control: no-cache' \
       -o "$tmp" "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${ver}" 2>/dev/null; then
    rm -f "$tmp"; return 0
  fi
  dg=$(tr -d '[:space:]' < "$tmp" | awk -v want="$asset" '
    { buf = buf $0 }
    END {
      n = split(buf, seg, "},{")
      for (i = 1; i <= n; i++) {
        if (index(seg[i], "\"name\":\"" want "\"") == 0) continue
        if (!match(seg[i], /"digest":"sha256:[0-9a-f]+"/)) continue
        s = substr(seg[i], RSTART, RLENGTH)
        sub(/^.*sha256:/, "", s)
        gsub(/"/, "", s)
        print s
        exit
      }
    }' 2>/dev/null | head -1 | tr -d ' \t\r\n')
  rm -f "$tmp"
  case "$dg" in ''|*[!0-9a-fA-F]*) return 0 ;; esac
  [ "${#dg}" -eq 64 ] || return 0
  printf '%s' "$dg"
}

# sing-box 的期望 SHA-256: 官方 release digest 优先, 内置值兜底, 冲突拒绝。
# 三道安全约束与 xray_expected_sha / hy2_expected_sha 完全一致, 不再重复解释。
#
# 和它们唯一的区别: API 只能直连 api.github.com, 没有可用的镜像前缀(ghfast.top
# 只代理 github.com 的下载, 不代理 API), 所以"官方不可达时用两个镜像交叉核对"
# 这一步在这里做不了。后果可控: API 不通时 sb_latest_version 也一定不通, 版本会
# 停在 SB_FALLBACK_VERSION, 而那个版本是有内置哈希的 —— 最常见的国内 VPS 场景
# 走的正是这条路, 不会卡住。
#
# stdout 只输出 64 位 hex, 所有提示一律 >&2 —— 调用方是 $(sb_expected_sha ...)。
sb_expected_sha(){
  local ver="$1" arch="$2" asset="$3"
  local builtin dg_off
  builtin=$(pinned_sha "singbox-${arch}-${ver}")

  dg_off=$(sb_api_sha "$ver" "$asset")
  if [ -n "$dg_off" ]; then
    if [ -n "$builtin" ] && [ "$dg_off" != "$builtin" ]; then
      err "sing-box v${ver} 官方 digest 与脚本内置值不一致, 拒绝安装:" >&2
      err "  官方 digest: ${dg_off}" >&2
      err "  内置       : ${builtin}" >&2
      err "  请人工核对官方 release 页后再决定, 不自动放行" >&2
      return 1
    fi
    printf '%s' "$dg_off"
    return 0
  fi
  if [ -n "$builtin" ]; then
    warn "GitHub API 不可达, 改用脚本内置哈希校验 sing-box v${ver}" >&2
    printf '%s' "$builtin"
    return 0
  fi
  return 0
}

# 取文件的 sha256。
# 必须清掉可能的前导反斜杠: GNU coreutils 在文件名含 \ 或换行时会给整行加 \ 转义前缀,
# 直接 awk 取第一列会得到 "\abc123..." 这种带前缀的串, 和基准值永远比不相等。
file_sha256(){
  sha256sum "$1" 2>/dev/null | awk '{print $1}' | tr -d '\\'
}

# 校验失败一律中止: 装上一个被换过的二进制, 比装不上严重得多
verify_sha256(){
  local file="$1" want="$2" label="$3" got
  if [ -z "$want" ]; then
    if [ "${ALLOW_UNVERIFIED_BIN:-0}" = "1" ]; then
      warn "${label}: 该版本没有内置校验值, 已按 ALLOW_UNVERIFIED_BIN=1 跳过校验"
      return 0
    fi
    err "${label}: 当前版本没有内置校验值, 无法确认完整性"
    err "  下载到的文件 sha256: $(file_sha256 "$file")"
    err "  先去官方 release 页核对这个值, 一致后再跳过校验:"
    err "    ALLOW_UNVERIFIED_BIN=1 bash setup-proxy.sh install"
    err "    ALLOW_UNVERIFIED_BIN=1 proxy upgrade <版本>"
    return 1
  fi
  got=$(file_sha256 "$file")
  if [ "$got" = "$want" ]; then
    ok "${label} 完整性校验通过 (sha256 ${got:0:16}…)"
    return 0
  fi
  err "${label} 完整性校验失败, 已拒绝安装"
  err "  期望: ${want}"
  err "  实际: ${got:-读取失败}"
  err "  说明: 下载到的文件与官方发布不一致(镜像投毒 / 中间人 / 断点续传损坏)"
  err "  处理: 重跑一次; 仍然失败请换网络, 或核对官方 release 页的哈希"
  return 1
}

download_with_mirror(){
  local url="$1" out="$2" p
  for p in "" "https://ghfast.top/" "https://gh-proxy.com/"; do
    if curl -fsSL --connect-timeout 15 --max-time 600 -o "$out" "${p}${url}"; then
      [ -s "$out" ] && return 0
    fi
    warn "下载失败, 换源重试: ${p:-官方}"
  done
  return 1
}

# 自更新专用: 下载 + 校验。
# 脚本自身没有内置哈希(二进制有), 语法/体积/版本号/身份这些校验全部来自
# 下载物自证 —— 一个被替换过的镜像完全可以把这几行都写对。
#
# 策略分两层, 不要再合并回"所有源必须一致":
#   1) 官方 raw 走 TLS + HSTS, 被替换的概率最低。只要官方成功就直接采用, 不再
#      因为第三方镜像缓存滞后而误拒更新 —— 刚发版时镜像往往还是旧内容, 旧实现
#      会在这里判"哈希不一致"直接放弃, 导致正常情况下 proxy update 也失败。
#   2) 官方不可达时才退到镜像, 且要求至少两个镜像哈希一致, 防止单个镜像被替换。
fetch_script_verified(){
  local out="$1" p tmp first="" h hs="" n=0
  tmp=$(mktemp 2>/dev/null) || return 1
  # 1) 官方源优先: 成功即采用, 不与镜像比对
  if curl -fsSL --connect-timeout 8 --max-time 90 -o "$tmp" "${SCRIPT_URL}" 2>/dev/null \
     && [ -s "$tmp" ]; then
    if cp -f "$tmp" "$out" 2>/dev/null; then
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
    return 1
  fi
  # 2) 官方不可达: 退到镜像, 至少两个镜像一致才采用。
  #    关键: 交叉核对完成前绝不写 $out —— 之前第一个镜像一到就 cp 进 $out,
  #    若第二个不一致/只有一个镜像, return 1 时 $out 已被单份未核对内容污染,
  #    万一调用方忘了删就直接以 root 执行了投毒脚本。核对通过再落盘。
  for p in "https://ghfast.top/" "https://gh-proxy.com/"; do
    if curl -fsSL --connect-timeout 8 --max-time 90 -o "$tmp" "${p}${SCRIPT_URL}" 2>/dev/null \
       && [ -s "$tmp" ]; then
      h=$(file_sha256 "$tmp" 2>/dev/null) || h=""
      [ -n "$h" ] || continue
      n=$((n + 1))
      if [ -z "$hs" ]; then
        hs="$h"
        # 第一份留在 $tmp 之外的独立临时文件, 不碰 $out
        first=$(mktemp 2>/dev/null) || { rm -f "$tmp"; return 1; }
        cp -f "$tmp" "$first" 2>/dev/null || { rm -f "$tmp" "$first"; return 1; }
      elif [ "$h" != "$hs" ]; then
        rm -f "$tmp" "$first"
        warn "两个镜像源给出的脚本哈希不一致, 已放弃本次更新(镜像被替换或缓存不同步)"
        return 1
      fi
      [ "$n" -ge 2 ] && break
    fi
  done
  rm -f "$tmp"
  if [ "$n" -ge 2 ] && [ -n "$first" ] && cp -f "$first" "$out" 2>/dev/null; then
    ok "官方源不可达, 已用 ${n} 个镜像交叉核对脚本哈希"
    rm -f "$first"
    return 0
  fi
  [ -n "$first" ] && rm -f "$first"
  # 只有一个镜像能拿到时不能放过去: 无法交叉核对的下载物一旦以 root 执行,
  # 单个被投毒的镜像就等于完全控制机器。宁可不更新。此时 $out 未被写入。
  warn "官方源不可达且镜像交叉核对未完成, 本次放弃更新"
  return 1
}

# ---- 国内直连规则文件的远程更新(与脚本自更新同一套安全模型) ----
# 规则文件是纯数据, 但它决定"哪些域名的 DNS 走国内明文", 投毒的后果是 DNS
# 泄露(把境外域名塞进直连名单)。所以校验比"下载成功"严格得多:
#   1) 官方 raw 源走 TLS, 成功且通过强校验即采用;
#   2) 官方不可达才退镜像, 要求两个镜像哈希一致;
#   3) 交叉核对完成前绝不写目标文件 —— 失败时现有名单保持原样。
RULES_MAX_BYTES=131072   # 128KB, 防塞几万条规则撑爆订阅
RULES_MAX_LINES=5000
RULES_MIN_LINES=20       # 下载到空文件/截断文件不能把现有名单清空
RULES_MAGIC="# proxy-node cn-direct"

# 规则文件强校验: 大小/行数上限 + 格式自证头 + 每条非空行都是合法域名。
# 只校验"域名形状", 不判断域名归属(那是数据源的责任); 形状不过整份拒绝。
validate_rule_file(){
  local f="$1" sz lines n=0 d bad=0
  [ -f "$f" ] || return 1
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
  if [ -z "$sz" ] || [ "$sz" -gt "$RULES_MAX_BYTES" ]; then return 1; fi
  lines=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  if [ -z "$lines" ] || [ "$lines" -gt "$RULES_MAX_LINES" ]; then return 1; fi
  # 自证头防把错误页/HTML 当规则装进去(配合下面的逐行域名校验, 错误页过不了)
  grep -qF "$RULES_MAGIC" "$f" 2>/dev/null || return 1
  while IFS= read -r d || [ -n "$d" ]; do
    d="${d%%#*}"; d="${d//[[:space:]]/}"
    [ -n "$d" ] || continue
    d="${d,,}"
    valid_domain "$d" || { bad=$((bad + 1)); continue; }
    n=$((n + 1))
  done < "$f"
  [ "$n" -ge "$RULES_MIN_LINES" ] && [ "$bad" -eq 0 ] || return 1
  return 0
}

# 下载规则文件到 $out: 官方源优先, 不可达则镜像交叉核对。失败不写 $out。
fetch_rules_verified(){
  local out="$1" p tmp first="" h hs="" n=0
  tmp=$(mktemp 2>/dev/null) || return 1
  # 1) 官方源优先: 下载成功且通过强校验才采用
  if curl -fsSL --connect-timeout 8 --max-time 60 -o "$tmp" "$RULES_URL" 2>/dev/null \
     && [ -s "$tmp" ] && validate_rule_file "$tmp"; then
    if cp -f "$tmp" "$out" 2>/dev/null; then rm -f "$tmp"; return 0; fi
    rm -f "$tmp"; return 1
  fi
  # 2) 官方不可达/校验不过: 退镜像, 至少两个镜像各自通过强校验且哈希一致。
  for p in "https://ghfast.top/" "https://gh-proxy.com/"; do
    if curl -fsSL --connect-timeout 8 --max-time 60 -o "$tmp" "${p}${RULES_URL}" 2>/dev/null \
       && [ -s "$tmp" ] && validate_rule_file "$tmp"; then
      h=$(file_sha256 "$tmp" 2>/dev/null) || h=""
      [ -n "$h" ] || continue
      n=$((n + 1))
      if [ -z "$hs" ]; then
        hs="$h"
        first=$(mktemp 2>/dev/null) || { rm -f "$tmp"; return 1; }
        cp -f "$tmp" "$first" 2>/dev/null || { rm -f "$tmp" "$first"; return 1; }
      elif [ "$h" != "$hs" ]; then
        rm -f "$tmp" "$first"
        warn "两个镜像源给出的规则文件哈希不一致, 已放弃本次更新(现有名单不变)"
        return 1
      fi
      [ "$n" -ge 2 ] && break
    fi
  done
  rm -f "$tmp"
  if [ "$n" -ge 2 ] && [ -n "$first" ] && cp -f "$first" "$out" 2>/dev/null; then
    ok "官方源不可达, 已用 ${n} 个镜像交叉核对规则文件哈希"
    rm -f "$first"; return 0
  fi
  [ -n "$first" ] && rm -f "$first"
  warn "官方源不可达且镜像交叉核对未完成, 本次放弃更新(现有名单不变)"
  return 1
}

ensure_xray(){
  local arch asset sha_arch
  # "latest" 是哨兵: 每次部署动态解析官方最新版, 解析不到才退回内置基线。
  # 显式 XRAY_VERSION=x.y.z 仍走固定版本, 供复现 / 排障回退。
  if [ "$XRAY_VERSION" = "latest" ] || [ -z "${XRAY_VERSION:-}" ]; then
    local lv
    lv=$(xray_latest_version)
    # 版本号会拼进下载 URL 和 state.env: 只接受 x.y.z 形状, 其余按"API 不可达"处理。
    case "$lv" in
      ''|*[!0-9.]*|.*|*.|*..*) lv="" ;;
    esac
    if [ -n "$lv" ]; then
      if [ "$lv" != "$XRAY_VERSION" ]; then
        info "Xray 追踪最新版: ${lv}"
      fi
      XRAY_VERSION="$lv"
    else
      # API 不通(国内 VPS 常见): 沿用本机已在跑的版本, 绝不降级回内置基线。
      local cur="" vout=""
      if [ -x "$XRAY_BIN" ]; then
        vout=$("$XRAY_BIN" version 2>/dev/null) || vout=""
        cur=$(printf '%s\n' "$vout" | head -1 | awk '{print $2}' | tr -d 'v')
      fi
      [ -z "$cur" ] && cur="${XRAY_VERSION:-}"
      case "$cur" in latest|'') cur="$XRAY_FALLBACK_VERSION" ;; esac
      warn "查询 Xray 最新版失败(GitHub API 不可达), 沿用本机版本 v${cur}, 不降级"
      XRAY_VERSION="$cur"
    fi
  fi
  # 版本号还决定两件事: clash.yaml 要不要写 MLKEM 开关、sing-box 客户端能不能
  # 连上新服务端。完整时间线与实测矩阵见 write_clash_yaml 上方。
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  asset="Xray-linux-64.zip";         sha_arch="64" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip";  sha_arch="arm64" ;;
    *) die "不支持的架构: $arch" ;;
  esac

  # 注意: xray version 输出形如 "Xray 26.3.27 (...)", 版本号不带 v 前缀
  #
  # 这里不能写 `xray version | head -1 | grep -qF`: 脚本开了 pipefail,
  # head/grep 提前退出会让 xray 吃到 SIGPIPE, 整条管道判失败, 结果是"明明装着
  # 也要重新下载一遍"。先整段读进变量, 再做字符串匹配。
  # 匹配时两边补空格, 避免 26.3.2 误配到 26.3.27。
  local vout="" vall=""
  if [ -x "$XRAY_BIN" ]; then
    # 整段读进来再截第一行, 不在管道里用 head: pipefail 下 xray 吃到 SIGPIPE
    # 会让"已装且版本正确"的分支判失败, 白白重下一遍内核。
    vall=$("$XRAY_BIN" version 2>/dev/null) || vall=""
    vout="${vall%%$'\n'*}"
  fi
  case " ${vout} " in
    *" ${XRAY_VERSION} "*)
      ok "Xray v${XRAY_VERSION} 已安装, 跳过"
      return 0 ;;
  esac

  info "下载 Xray v${XRAY_VERSION} ..."
  local tmp; tmp=$(mktemp -d) || die "无法创建临时目录"
  download_with_mirror \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${asset}" \
    "$tmp/x.zip" || { rm -rf "$tmp"; die "Xray 下载失败(检查服务器能否访问 GitHub)"; }
  local _want_sha
  _want_sha=$(xray_expected_sha "$XRAY_VERSION" "$sha_arch" "$asset") \
    || { rm -rf "$tmp"; die "Xray 校验值获取失败, 已中止"; }
  verify_sha256 "$tmp/x.zip" "$_want_sha" "Xray v${XRAY_VERSION}" \
    || { rm -rf "$tmp"; die "Xray 校验未通过, 已中止"; }
  unzip -o -q "$tmp/x.zip" -d "$tmp/pkg" || { rm -rf "$tmp"; die "Xray 解压失败"; }
  [ -f "$tmp/pkg/xray" ] || { rm -rf "$tmp"; die "压缩包内未找到 xray"; }
  systemctl stop xray >/dev/null 2>&1 || true
  mkdir -p /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  # 装失败(磁盘满/只读/权限)必须当场中止: 上面已经 stop 了服务, 这里再静默
  # 失败就是"节点停摆 + 屏幕报已安装", 而且后面算出来的是旧二进制的哈希。
  install -m 755 "$tmp/pkg/xray" "$XRAY_BIN" \
    || { rm -rf "$tmp"; die "安装 Xray 二进制失败(磁盘空间或权限?), 服务已停止, 请排查后重跑 install"; }
  cp -f "$tmp/pkg/geoip.dat"   /usr/local/share/xray/ 2>/dev/null || true
  cp -f "$tmp/pkg/geosite.dat" /usr/local/share/xray/ 2>/dev/null || true
  rm -rf "$tmp"
  XRAY_BIN_SHA=$(file_sha256 "$XRAY_BIN")
  [ -n "$XRAY_BIN_SHA" ] || die "无法计算 Xray 二进制哈希, 安装不可信"
  local _iv=""
  if [ -x "$XRAY_BIN" ]; then _iv=$("$XRAY_BIN" version 2>/dev/null) || _iv=""; fi
  [ -n "$_iv" ] || die "Xray 安装后无法执行, 请检查架构是否匹配: uname -m"
  ok "Xray 已安装: $(printf '%s\n' "$_iv" | head -1)"
}

# 用 openssl 生成 X25519 密钥对, 结果写入全局 PRIV / PUB (base64url, 无 padding)
# REALITY 要的就是标准的 X25519 原始 32 字节, 和 xray x25519 的输出等价
gen_x25519_openssl(){
  local tmp k priv pub
  PRIV=""; PUB=""
  command -v openssl >/dev/null 2>&1 || return 1
  tmp=$(mktemp -d 2>/dev/null) || return 1
  k="${tmp}/k.pem"
  if ! openssl genpkey -algorithm X25519 -out "$k" >/dev/null 2>&1; then
    rm -rf "$tmp"; return 1
  fi
  # PKCS#8 DER 末 32 字节 = 私钥标量; SPKI DER 末 32 字节 = 公钥
  priv=$(openssl pkey -in "$k" -outform DER 2>/dev/null | tail -c 32 \
         | base64 2>/dev/null | tr -d '\n\r' | tr '+/' '-_' | tr -d '=')
  pub=$(openssl pkey -in "$k" -pubout -outform DER 2>/dev/null | tail -c 32 \
        | base64 2>/dev/null | tr -d '\n\r' | tr '+/' '-_' | tr -d '=')
  rm -rf "$tmp"
  # base64url(32 字节) 固定 43 字符, 长度不对说明 openssl 输出异常
  [ "${#priv}" = "43" ] && [ "${#pub}" = "43" ] || return 1
  PRIV="$priv"; PUB="$pub"
  return 0
}

# 读自签证书的 CN。openssl 1.1 输出 "CN = x", 3.0 输出 "CN=x", 两种都吃掉。
# 读不到(文件缺失/损坏)返回空串。
cert_cn(){
  [ -f "${1:-}" ] || return 0
  openssl x509 -in "$1" -noout -subject 2>/dev/null \
    | sed -n 's/.*CN *= *//p' | head -1
}

# 生成自签证书。
# 必须带 SAN: RFC 6125 之后客户端只认 subjectAltName, 只有 CN 的证书在浏览器里
# 直接拒 —— 一张"只有 CN、没有 SAN"的自签证书本身就是"手工 openssl 敲出来的"
# 的标记, 主动探测方拿到证书就能据此归类。openssl 1.1.1 以下没有 -addext,
# 那时退回只写 CN(功能不受影响, 客户端本来就靠指纹验身份)。
make_self_signed_cert(){
  local crt="$1" key="$2" cn="$3"
  openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null || return 1
  openssl req -new -x509 -days 3650 -key "$key" -out "$crt" \
    -subj "/CN=${cn}" -addext "subjectAltName=DNS:${cn}" 2>/dev/null && return 0
  openssl req -new -x509 -days 3650 -key "$key" -out "$crt" -subj "/CN=${cn}" 2>/dev/null
}

# 生成标准 v4 UUID; 容器里 /proc 不完整时手工拼一个
gen_uuid(){
  local u
  u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
  if [ -z "$u" ]; then
    u=$(openssl rand -hex 16)
    u="${u:0:12}4${u:13:3}a${u:17:15}"
    u="${u:0:8}-${u:8:4}-${u:12:4}-${u:16:4}-${u:20:12}"
  fi
  printf '%s' "$u"
}

# ensure_creds 真换了主 UUID 时置 1, 由 ensure_users_file 同步 users.txt 首行。
CREDS_UUID_CHANGED=0

ensure_creds(){
  local need_uuid=0 need_sid=0 need_keys=0 keys rc
  [ -n "${UUID:-}" ] || need_uuid=1
  [ -n "${SID:-}" ]  || need_sid=1
  if [ -z "${PRIV:-}" ] || [ -z "${PUB:-}" ]; then need_keys=1; fi
  if [ "$need_uuid" = "0" ] && [ "$need_sid" = "0" ] && [ "$need_keys" = "0" ]; then
    ok "复用已有凭据 (UUID: ${UUID:0:8}...)"
    return 0
  fi

  # 只补缺的那一项, 绝不顺手换掉别的。SID 是较晚加入的字段: 老 state.env
  # 里没有它, 以前「四者全有才复用」会把 UUID / REALITY 密钥一起重生成 ——
  # 一次幂等重装就让所有已分发客户端立即失效, 这是最贵的回归。
  if [ "$need_uuid" = "1" ]; then
    info "生成 UUID ..."
    UUID=$(gen_uuid)
    CREDS_UUID_CHANGED=1
  fi
  if [ "$need_sid" = "1" ]; then
    info "补齐 shortId ..."
    SID=$(openssl rand -hex 8 2>/dev/null)
    [ -n "$SID" ] || SID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  if [ "$need_keys" = "1" ]; then
    info "生成 X25519 密钥 ..."
    PRIV=""; PUB=""
    # 优先走 openssl: 全新安装时 xray 二进制还没下载, 不能依赖它
    if ! gen_x25519_openssl; then
      keys=$("$XRAY_BIN" x25519 2>&1); rc=$?
      PRIV=$(printf '%s\n' "$keys" | grep -iE '^[[:space:]]*private' | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
      PUB=$(printf '%s\n' "$keys"  | grep -iE '^[[:space:]]*(public|password)' | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')
      if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
        PRIV=$(printf '%s\n' "$keys" | grep -oE '[A-Za-z0-9_-]{43}' | sed -n 1p)
        PUB=$(printf '%s\n' "$keys"  | grep -oE '[A-Za-z0-9_-]{43}' | sed -n 2p)
      fi
      if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
        echo -e "${D}--- xray x25519 原始输出 (退出码 ${rc}) ---${N}" >&2
        printf '%s\n' "$keys" | head -10 >&2
        die "x25519 密钥生成失败。openssl 与 xray 都没拿到可用密钥, 请检查: ${XRAY_BIN} x25519"
      fi
    fi
  fi
  ok "凭据已就绪 (UUID: ${UUID:0:8}...)"
}

# ---------------- 多设备凭据 ----------------
# 每台设备一个 UUID: 丢手机时只吊销那一条, 其他设备不受影响
ensure_users_file(){
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  if [ ! -s "$USERS_FILE" ]; then
    # 写失败必须传出去: 否则末尾的 if 条件为假会让函数隐式返回 0,
    # write_xray_config 的 `ensure_users_file || die` 不会触发, 安装照常报成功,
    # 但 users.txt 是空的/半截的, 多设备凭据静默丢失。
    printf '%s|%s|%s\n' "${UUID}" "default" "$(date '+%Y-%m-%d')" > "$USERS_FILE" \
      || return 1
    chmod 600 "$USERS_FILE" || return 1
  elif [ "${CREDS_UUID_CHANGED:-0}" = "1" ]; then
    # 主 UUID 真变了: 只改首行(default), 其余设备凭据原样保留。
    # 不改的话 gen_links 拿 users.txt 首行的旧 UUID, xray clients 列表却是新的,
    # 链接能导入但握手必失败。
    local _rest _utmp
    # 读失败必须停手: 以前 `|| true` 把 tail 的失败吞成空串, 接着原地截断重写,
    # 所有非 default 设备的 UUID 静默消失, 提示还写着"其余设备凭据保留"。
    _rest=$(tail -n +2 "$USERS_FILE" 2>/dev/null) || return 1
    _utmp=$(mktemp "${USERS_FILE}.XXXXXX" 2>/dev/null) || return 1
    {
      printf '%s|%s|%s\n' "${UUID}" "default" "$(date '+%Y-%m-%d')"
      # 全新安装时 users.txt 只有 default 一行, _rest 为空。这里原来写
      # `[ -n "$_rest" ] && printf ...`, 条件为假会让整个块的退出码变成 1,
      # 被下面的 `|| { rm; return 1; }` 当成写失败 —— 于是全新安装/ref 全在
      # write_xray_config 里 die "无法写入 users.txt"。用 if 包住, 空 _rest
      # 时块正常返回 0, 只有 printf 真出错才走 return 1。
      if [ -n "$_rest" ]; then printf '%s\n' "$_rest"; fi
    } > "$_utmp" || { rm -f "$_utmp"; return 1; }
    chmod 600 "$_utmp"
    # 同目录 mv 是原子的: 中途失败只会留下临时文件, 原 users.txt 不受影响。
    mv -f "$_utmp" "$USERS_FILE" || { rm -f "$_utmp"; return 1; }
    warn "主 UUID 已变化, 已同步 users.txt 首行; 其余设备凭据保留"
  fi
  # 末行可能没有换行(手改过, 或从备份包恢复来的)。读取侧(build_clients_json /
  # sb_users_json)都用 `|| [ -n "$u" ]` 兜住了这种状态, 但写入侧没有:
  # `proxy user add` 直接 printf >> 会粘在最后一行后面, 两台设备的凭据合成一行 ——
  # 老设备失效, 新设备在 user list 里显示成一段乱码, 而两边都不报错。
  # 这里补一个换行, 让写侧也安全。`tail -c 1` 取出的是最后一个字节, 命令替换会
  # 吃掉末尾换行, 所以"非空"恰好等价于"文件不以换行结尾"。
  if [ -s "$USERS_FILE" ] && [ -n "$(tail -c 1 "$USERS_FILE" 2>/dev/null)" ]; then
    printf '\n' >> "$USERS_FILE" || return 1
  fi
  # 显式收尾: 不让末尾 if 的隐式退出码决定函数返回值。
  return 0
}

build_clients_json(){
  local out="" u n sep=""
  # 与 sb_users_json 同理: 末行无换行时 read 返回非 0, 但 u/n 已赋值,
  # 漏掉这半句会静默丢掉最后一台设备的 Xray clients 凭据。
  while IFS='|' read -r u n _ || [ -n "$u" ]; do
    [ -n "$u" ] || continue
    # UUID 直接进 JSON 字符串: 手改 users.txt 塞进引号就能写坏整份配置。
    # 合法 UUID 只含十六进制与连字符, 不合格的行跳过(它本来也连不上)。
    case "$u" in *[!0-9A-Fa-f-]*) continue ;; esac
    n=$(json_esc "$n")
    out="${out}${sep}{ \"id\": \"${u}\", \"flow\": \"xtls-rprx-vision\", \"email\": \"${n}\" }"
    sep=", "
  done < "$USERS_FILE"
  [ -n "$out" ] || out="{ \"id\": \"${UUID}\", \"flow\": \"xtls-rprx-vision\" }"
  CLIENTS_JSON="[ ${out} ]"
}

primary_uuid(){
  local u
  u=$(head -1 "$USERS_FILE" 2>/dev/null | cut -d'|' -f1)
  echo "${u:-$UUID}"
}

# ---------------- Xray 配置 ----------------
# WITH_DNS=1 时写入内置 DNS(解析更快更稳); 若当前 Xray 版本不接受会自动回退
WITH_DNS="${WITH_DNS:-1}"
# 解析上游出口代理 URL: scheme://[user:pass@]host:port
# 输出 "scheme|host|port|user|pass"; scheme 归一成 socks 或 http。解析失败返回 1。
#
# 用途: VPS 的 IP 段是机房, TikTok / 银行这类平台会按"机房 IP"降权。想绕开,
# 唯一的技术手段是把最终出口换成一个住宅 IP —— 也就是在服务端再接一层上游代理。
# 这一层只在服务端做, 客户端配置和分享链接都不用改。
parse_egress(){
  local u scheme rest hostport host port user="" pass=""
  # 显式传参就用参数, 不传才回落到全局 EGRESS_URL —— 传空串必须判失败,
  # 否则 "关闭出口" 时会拿旧值继续用
  if [ $# -gt 0 ]; then u="$1"; else u="${EGRESS_URL:-}"; fi
  [ -n "$u" ] || return 1
  # 这个值最终是拼进 JSON 和 state.env 的, 引号/反斜杠会直接写坏配置文件,
  # 无论从环境变量还是命令行进来, 都在这里统一拦掉。
  # 控制字符(换行/制表)同样致命: JSON 字符串里出现裸换行就是非法 JSON,
  # 而写进 state.env 会多出一行, 下次 load_state 直接 source 到垃圾。
  # '|' 也必须拦: 本函数返回的是 '|' 分隔的五段记录, 用户名/密码里带一个竖线
  # 就会把下游的 `IFS='|' read -r scheme host port user pass` 拆错位 ——
  # 密码的后半截被当成主机名, 报出来的错误指向完全无关的地方。
  case "$u" in *'"'*|*"'"*|*\\*|*'|'*) return 1 ;; esac
  case "$u" in *[[:cntrl:]]*) return 1 ;; esac
  case "$u" in
    *://*) scheme="${u%%://*}"; rest="${u#*://}" ;;
    *)     return 1 ;;
  esac
  case "$scheme" in
    socks5|socks5h|socks) scheme="socks" ;;
    http|https)           scheme="http" ;;
    *) return 1 ;;
  esac
  # 凭据里可能出现 '@', 用最后一个 '@' 切分才稳
  case "$rest" in
    *@*) user="${rest%@*}"; hostport="${rest##*@}" ;;
    *)   user=""; hostport="$rest" ;;
  esac
  case "$hostport" in
    \[*\]:*) host="${hostport%]:*}"; host="${host#\[}"; port="${hostport##*]:}" ;;
    *:*)     host="${hostport%:*}"; port="${hostport##*:}" ;;
    *)       return 1 ;;
  esac
  if [ -n "$user" ]; then
    case "$user" in
      *:*) pass="${user#*:}"; user="${user%%:*}" ;;
    esac
  fi
  [ -n "$host" ] && [ -n "$port" ] || return 1
  # 端口必须 1..65535。这个值是裸数字拼进 JSON 的, 99999 会让 xray/sing-box
  # 直接起不来; 前导 0 则会写出 "port": 0123 这种非法 JSON。
  # 只做长度 + 5 位数比较, 不用 [ "$port" -gt ] 之外的大数运算: 超大数字在
  # test 里返回 2(报错), 在 if 里被当成"假", 反而把非法值放过去。
  case "$port" in
    ''|*[!0-9]*|0*) return 1 ;;
  esac
  [ "${#port}" -le 5 ] || return 1
  if [ "${#port}" -eq 5 ] && [ "$port" -gt 65535 ]; then return 1; fi
  printf '%s|%s|%s|%s|%s' "$scheme" "$host" "$port" "$user" "$pass"
}

# curl 拿到限流页 / 407 错误文本时响应照样非空。以前把它直接当出口 IP,
# 于是 "与本机一致" 误判、ip-api 的 URL 被拼进一段英文、IP 画像全错。
# 所有出口探测统一走这里: 只认合法 IPv4, 拿不到就是失败。
valid_ipv4(){
  local ip="${1:-}" o IFS=.
  case "$ip" in
    ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
  esac
  set -- $ip
  [ "$#" -eq 4 ] || return 1
  for o in "$@"; do
    [ -n "$o" ] || return 1
    # 前导零在 IPv4 里有歧义: 有的实现按八进制解析(010 = 8), 有的直接拒收。
    # 放过去就会被写进订阅链接和 JSON, 服务端与客户端各自解析成不同地址。
    case "$o" in 0) ;; 0*) return 1 ;; esac
    [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}
extract_ipv4(){
  local c
  for c in $(printf '%s\n' "${1:-}" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -5); do
    valid_ipv4 "$c" && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# 通过上游代理查一次出口 IP, 用来验证填的地址能不能用
egress_probe_ip(){
  local line scheme host port user pass args=() raw ep
  line=$(parse_egress) || return 1
  IFS='|' read -r scheme host port user pass <<< "$line"
  [ -n "$user" ] && args=(-U "${user}:${pass}")
  # 两个端点轮询。部分住宅代理按域名黑名单放行, 会拦掉 api.ipify.org ——
  # 只测一个端点就会把"代理是好的、只是拦了这个域名"误判成"代理不可用",
  # 用户于是永远配不上出口, 还查不出原因。
  for ep in https://api.ipify.org https://ifconfig.me; do
    if [ "$scheme" = "socks" ]; then
      raw=$(curl -fsS "${args[@]}" --socks5-hostname "${host}:${port}" --max-time 12 "$ep" 2>/dev/null) || continue
    else
      raw=$(curl -fsS "${args[@]}" -x "http://${host}:${port}" --max-time 12 "$ep" 2>/dev/null) || continue
    fi
    extract_ipv4 "$raw" && return 0
  done
  return 1
}

write_xray_config(){
  local dest="$1" dns_json="" cfg_tmp=""
  ensure_users_file || die "无法写入 ${USERS_FILE}, 拒绝继续生成配置"
  build_clients_json
  if [ "$WITH_DNS" = "1" ]; then
    # 不放 "localhost": Xray 内置 DNS 对无匹配规则的 server 是并发查询、取最快响应,
    # 带上 localhost 就等于给 VPS 机房的 /etc/resolv.conf 留了一条抢答通道 ——
    # 一旦它先回, 域名实际是被机房 DNS 解的, 内置 DNS 形同虚设。
    # 境外 VPS 上 1.1.1.1 / 8.8.8.8 都可达; 真全断了宁可解析失败, 也不静默降级。
    dns_json='  "dns": { "servers": [ "1.1.1.1", "8.8.8.8" ], "queryStrategy": "UseIPv4" },'
  fi
  # 配了上游出口(住宅 IP)时, 把 egress 放 outbounds 首位 —— xray 的默认出站就是
  # 第一个, 这样除下面两条黑名单规则外的流量全部走它。客户端不用改任何配置。
  local ob_json eg_line eg_scheme eg_host eg_port eg_user eg_pass eg_users=""
  if eg_line=$(parse_egress); then
    IFS='|' read -r eg_scheme eg_host eg_port eg_user eg_pass <<< "$eg_line"
    [ -n "$eg_user" ] && eg_users=", \"users\": [ { \"user\": \"${eg_user}\", \"pass\": \"${eg_pass}\" } ]"
    ob_json="    { \"protocol\": \"${eg_scheme}\", \"tag\": \"egress\", \"settings\": { \"servers\": [ { \"address\": \"${eg_host}\", \"port\": ${eg_port}${eg_users} } ] } },
    { \"protocol\": \"freedom\", \"tag\": \"direct\", \"settings\": { \"domainStrategy\": \"UseIPv4\" } },
    { \"protocol\": \"blackhole\", \"tag\": \"block\" }"
  else
    ob_json="    { \"protocol\": \"freedom\", \"tag\": \"direct\", \"settings\": { \"domainStrategy\": \"UseIPv4\" } },
    { \"protocol\": \"blackhole\", \"tag\": \"block\" }"
  fi
  # 先写同目录临时文件, 校验通过才 mv 覆盖: 直接 `cat > 正式路径` 时,
  # 磁盘满/中途失败会留下一份半截 JSON, 而正式配置已经没了 —— 下次重启
  # 节点就起不来, 且原来的可用配置不可恢复。
  mkdir -p "$(dirname "$XRAY_CFG")"
  # 文件名必须保留 .json 后缀: Xray >= 26.11 的 LoadConfig(auto) 按扩展名判断
  # 格式, 未知扩展名(config.json.aBcDeF)直接报 Failed to get format 并退出。
  # 旧版会默认当 JSON, 新版不会 —— 用 -format json 或保留后缀二选一, 这里保留后缀。
  cfg_tmp=$(mktemp "$(dirname "$XRAY_CFG")/.config.XXXXXX.json") || die "无法创建 Xray 配置临时文件"
  cat > "$cfg_tmp" <<EOF
{
  "log": { "loglevel": "warning" },
${dns_json}
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": ${CLIENTS_JSON},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}:443",
          "xver": 0,
          "serverNames": [ "${dest}" ],
          "privateKey": "${PRIV}",
          "shortIds": [ "${SID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
${ob_json}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": [ "::/0" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
EOF
  # 配置里是全部设备的 UUID —— 就是凭据本身。默认 umask 022 会留下 644,
  # 同机任何用户都能读走所有设备凭据, 所以必须收紧到 600。
  chmod 600 "$cfg_tmp"

  # 带 DNS 块的配置若不被当前版本接受, 自动去掉 DNS 块重写一次
  if [ -n "$dns_json" ] && ! $XRAY_BIN run -test -c "$cfg_tmp" >/dev/null 2>&1; then
    warn "内置 DNS 配置不被当前 Xray 版本接受, 回退为系统解析"
    rm -f "$cfg_tmp"
    WITH_DNS=0
    write_xray_config "$dest"
    return 0
  fi
  # 写完必须过一遍官方校验: 端口写错、名字里带引号这类问题会在这里暴露,
  # 而不是等到 systemctl restart 之后对着 "未启动" 猜原因
  local tlog; tlog=$(mktemp) || { rm -f "$cfg_tmp"; die "无法创建临时文件"; }
  if ! $XRAY_BIN run -test -c "$cfg_tmp" >"$tlog" 2>&1; then
    err "Xray 配置校验失败:"
    sed -n '1,5p' "$tlog" | sed 's/^/    /' >&2
    rm -f "$tlog" "$cfg_tmp"
    die "请检查端口参数 (VLESS_PORT=${VLESS_PORT}) 与设备名是否含特殊字符"
  fi
  rm -f "$tlog"
  # 校验通过才顶掉正式配置: 上面的 die 路径不会碰旧文件。
  mv -f "$cfg_tmp" "$XRAY_CFG" || { rm -f "$cfg_tmp"; die "写入 ${XRAY_CFG} 失败(磁盘满/权限?)"; }
}

# 起一个临时 xray 客户端, 走本地 REALITY 隧道探测一个 URL, 返回 HTTP 码。
# $1=URL  $2=serverName(默认 $DEST)  $3=socks 端口(默认 10899)
# 探测用的客户端是临时的: 起、测、杀, 不留常驻进程, 也不占用端口给别人复用。
reality_probe(){
  local url="$1" dest="${2:-${DEST}}" port="${3:-}" code pid tdir
  [ -x "$XRAY_BIN" ] || { printf '000'; return 0; }
  if [ -z "$port" ]; then
    # 固定 10899 会跟同机进程或上次异常残留的临时实例撞车。一旦被占,
    # curl 拿到 000, 所有候选站全判失败, pick_dest 掉进兜底分支还误报
    # "出站 443 受限/时间偏差" —— 排障方向彻底带偏。随机端口 + 查占用。
    local _i
    for _i in 1 2 3 4 5; do
      port=$((20000 + RANDOM % 20000))
      port_in_use "$port" tcp || break
    done
    if port_in_use "$port" tcp; then printf '000'; return 0; fi
  fi
  # 临时目录而不是 /tmp/_tc.json: 固定路径 + 可预测名字等于给同机普通用户
  # 留了读取 UUID 和软链接攻击的口子
  tdir=$(mktemp -d 2>/dev/null) || { printf '000'; return 0; }
  cat > "$tdir/c.json" <<EOF
{
  "log": { "loglevel": "error" },
  "inbounds": [ { "port": ${port}, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${VLESS_PORT},
      "users": [ { "id": "$(primary_uuid)", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "${dest}", "fingerprint": "${REALITY_FP:-chrome}",
        "publicKey": "${PUB}", "shortId": "${SID}", "spiderX": "/" } }
  } ]
}
EOF
  "$XRAY_BIN" -c "$tdir/c.json" >"$tdir/c.log" 2>&1 &
  pid=$!
  sleep 3
  code=$(curl -s --socks5-hostname "127.0.0.1:${port}" -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null)
  kill "$pid" >/dev/null 2>&1; wait "$pid" 2>/dev/null
  rm -rf "$tdir"
  printf '%s' "${code:-000}"
}

# 验证隧道是否真的通了。不能拿 dest 自己当探测目标: REALITY 在认证失败时会
# 把连接原样转给 dest, 探 dest 照样能拿到 200, 分不清"隧道通了"和"被降级转发了"。
# 也不能只探一个站: VPS 到自己连不上 google 时, 所有候选都会被误判成握手失败。
verify_reality(){
  local dest="$1" code u
  for u in "https://www.google.com/generate_204" "http://cp.cloudflare.com/generate_204"; do
    code=$(reality_probe "$u" "$dest")
    case "$code" in 200|204|301|302) return 0 ;; esac
  done
  return 1
}

# REALITY 伪装目标池(18 个), pick_dest / pick_dest_simple 共用这一份。
# 四个硬条件: 国内可直连 / TLS1.3+ALPN h2 / 非 Cloudflare / 稳定不敏感。
# "非教程标配"也是条件: apple、microsoft 技术上完全合格(实测 TLS1.3、自家 CA、
# 不套 CF), 但全网几十万节点压同一个 SNI, 它本身就成了指纹 —— 要的是
# "大站, 但教程不推荐"。太冷门也不行: 没人访问的站天天被你的 VPS 握手更显眼。
# 池内 13 个走 Akamai 边缘, "CDN 边缘终止 TLS"在这里是常态, 不是缺陷;
# 真正要避开的只有 Cloudflare —— dest_behind_cf 只认 server: cloudflare /
# cf-ray, 别把判据扩大到"凡是 CDN 都拦"(那会否掉一半池子)。
# 剔掉的: suse 套 CF(实测三次); bing 只协商到 TLS 1.2, 永远进不了档位 1,
# 留着只会让"池子全是 TLS1.3"变成假话; amazon 四条硬判据全过, 但加了不增加
# 分散度, 不为凑数加。
# 不用排行榜动态拉: 安装时必须能离线工作, 而"被墙"正是用户来装脚本的原因。
# 加站前对照上面条件; 剔站前至少串行复测 3 次 —— 并发探测会大量超时,
# 单次失败不足以判定(nginx / ibm 都被这样误伤过)。
# Tranco 排名(2026-11): adobe 59 / mozilla 92 / nginx 104 / samsung 122 /
#   apache 140 / oracle 217 / ibm 282 / hp 285 / debian 325 / nvidia 352 /
#   dell 361 / intel 453 / mysql 539 / python 742 / tesla 1105 / amd 1114 /
#   postgresql 1161 / kernel 1272
REALITY_DESTS="www.samsung.com www.nvidia.com www.amd.com www.ibm.com www.tesla.com www.adobe.com www.oracle.com www.dell.com www.hp.com www.intel.com www.mozilla.org www.python.org www.kernel.org www.debian.org www.apache.org www.nginx.com www.postgresql.org www.mysql.com"

# 每个伪装目标站"是什么"。为什么要这东西: SNI 是必须一字不差抄进客户端的一行,
# 而池子里有一半是 www.kernel.org / www.debian.org / www.nginx.com 这种普通用户
# 平时不会主动访问的域名 —— 看到一个陌生域名又没有任何线索, 只能靠猜, 猜错了也
# 只会得到"连接超时", 不会有人告诉他抄错了。
# 加池子成员必须在这里补一行: test/run.sh 会逐个检查, 漏了直接判红。
dest_note(){
  case "$1" in
    www.samsung.com)       echo "三星电子官网" ;;
    www.nvidia.com)        echo "英伟达官网" ;;
    www.amd.com)           echo "AMD 官网" ;;
    www.ibm.com)           echo "IBM 官网" ;;
    www.tesla.com)         echo "特斯拉官网" ;;
    www.adobe.com)         echo "Adobe(Photoshop 厂商)官网" ;;
    www.oracle.com)        echo "Oracle 数据库厂商官网" ;;
    www.dell.com)          echo "戴尔官网" ;;
    www.hp.com)            echo "惠普官网" ;;
    www.intel.com)         echo "英特尔官网" ;;
    www.mozilla.org)       echo "Mozilla(Firefox 厂商)官网" ;;
    www.python.org)        echo "Python 官网" ;;
    www.kernel.org)        echo "Linux 内核官网" ;;
    www.debian.org)        echo "Debian 发行版官网" ;;
    www.apache.org)        echo "Apache 软件基金会官网" ;;
    www.nginx.com)         echo "Nginx 官网" ;;
    www.postgresql.org)    echo "PostgreSQL 官网" ;;
    www.mysql.com)         echo "MySQL 官网" ;;
    *) return 1 ;;
  esac
}
# 黑名单: 实测不能用作 REALITY 伪装目标
# Google 系不能当 dest: 这些域名在国内本身就是被墙的, 正常中国用户不会主动连,
# GFW 看到 SNI=dl.google.com 反而更容易把连接挑出来。
# apple / microsoft 不是"不合格"(实测 TLS1.3、自家 CA、SAN 只有 2~7 个域名), 而是
# "被教程用烂了": 几乎所有 REALITY 教程都写这两个, 全网几十万节点压在同一个 SNI 上,
# 它本身就成了指纹。理由写准确, 免得下次有人照着"CDN 共用证书链"去验证, 验不过
# 就把这条删掉。
# Cloudflare 系: 边缘证书由 Google Trust Services 签发, 且 CF 的 IP 段被大量代理占用。
BLOCKED_DESTS="www.cloudflare.com cloudflare.com 1.1.1.1 www.apple.com apple.com www.icloud.com icloud.com www.microsoft.com microsoft.com dl.google.com www.google.com google.com www.youtube.com youtube.com"
is_blocked(){
  local d="$1" b
  for b in $BLOCKED_DESTS; do [ "$d" = "$b" ] && return 0; done
  return 1
}

# Google 各地本地域名。proxy audit 靠它判断"有没有被换区"。
# 只列 ccTLD, 不含裸 google.com —— 裸 .com 要单独按"Google 决定不换区"处理,
# 混在一起会被页面里满地的 google.com 链接带偏。
GOOGLE_TLD_RE='(https?://)?(www\.)?google\.(com\.hk|com\.tw|com\.sg|com\.my|com\.ph|com\.vn|com\.br|com\.mx|com\.ar|com\.au|com\.tr|com\.sa|co\.jp|co\.kr|co\.uk|co\.in|co\.nz|co\.za|co\.th|co\.id|co\.il|cn|de|fr|nl|it|es|ru|pl|se|no|dk|fi|ch|at|be|cz|ie|ae|ca|cl)[/"]'

# 判断目标站是不是套在 Cloudflare 后面。两个判据, 命中任一即算:
#   1) 证书 issuer 里带 Cloudflare —— 只覆盖 CF 自己的 CA, 现在已很少见
#   2) 响应头里有 server: cloudflare 或 cf-ray —— CF 边缘加的, 源站改不掉
#
# 为什么必须加第 2 条: CF 现在的 Universal SSL 边缘证书由 Google Trust Services
# 签发(实测 www.cloudflare.com 的 issuer 就是 "O=Google Trust Services, CN=WE1"),
# 证书里根本没有 "Cloudflare" 字样。只查 issuer 会**整片漏掉**套 CF 的站 ——
# 实测池子里 suse / redis / w3 / nodejs 四个都是 CF, 一个都没被拦下来。
#
# 为什么必须拦: CF 的 IP 段被大量代理和 VPN 占用, 是全网最"可疑"的一批地址。
# 拿 CF 站当 SNI, 等于主动把连接混进最容易被整体标记的那一堆里 —— 这是 REALITY
# 选目标站时最该避开的一类, 比"站够不够大"重要得多。
dest_behind_cf(){
  local d="$1" issuer="$2" h
  case "$issuer" in *[Cc]loudflare*) return 0 ;; esac
  h=$(curl -sI --max-time 5 "https://$d/" 2>/dev/null | tr -d '\r')
  [ -n "$h" ] || return 1
  printf '%s' "$h" | grep -qiE '^(server:[[:space:]]*cloudflare|cf-ray:)'
}
# 一次 TLS 握手同时拿三样: 协商版本、ALPN、证书签发者。
# 以前拆成 dest_behind_cloudflare + dest_tls_info 两个函数, 各跑一次
# `openssl s_client` —— 同一个站的同一个握手跑两遍, 每个候选白多一次往返。
# 候选池扩到 28 个之后这个浪费会直接乘上去: 一个不可达的站原来要白等
# 16 秒(两次 8s 超时), 合并后只要 5 秒。
# 超时从 8s 收到 5s: TLS 握手 5 秒还没完成, 这个站当回落目标也已经没意义了,
# 留着只会让"挑选伪装站"这一步转得更久。
dest_probe(){
  local d="$1" f v a i
  f=$(mktemp 2>/dev/null) || { printf 'none|none|'; return 0; }
  timeout 5 openssl s_client -connect "${d}:443" -servername "$d" -alpn h2 </dev/null >"$f" 2>/dev/null
  v=$(grep -a -m1 -E '^[[:space:]]*Protocol[[:space:]]*:' "$f" 2>/dev/null \
      | sed 's/^[[:space:]]*Protocol[[:space:]]*:[[:space:]]*//' | tr -d '\r')
  a=$(grep -a -m1 'ALPN protocol:' "$f" 2>/dev/null \
      | sed 's/.*ALPN protocol:[[:space:]]*//' | tr -d '\r')
  # 套了 Cloudflare 的站证书由 CF 签发。这类站的证书链是全站共用的,
  # 拿它当 SNI 反而更容易被识别 —— 所以要单独判出来。
  i=$(openssl x509 -noout -issuer <"$f" 2>/dev/null)
  rm -f "$f"
  printf '%s|%s|%s' "${v:-none}" "${a:-none}" "$i"
}

# 探测目标站的 TLS 版本与 ALPN, 输出 "TLSv1.3|h2" / "TLSv1.2|h2" / "none|none"。
# 一次握手取两个信息, 比开两次连接快。
#
# 两个坑都踩过:
# 1) 输出里有二进制(session ticket), 必须落文件再 grep, 直接塞进 $() 会丢 null byte。
# 2) TLS 版本行的缩进随 openssl 版本变: 3.2+ 会在摘要区多打一行顶格的
#    "Protocol: TLSv1.3"; 而 Debian 12 / Ubuntu 22.04 的 openssl 3.0 和 1.1.1
#    只有 SSL-Session 段里缩进的 "    Protocol  : TLSv1.3" (冒号前还有两个空格)。
#    所以既不能锚定行首, 也不能按 "Protocol:" 去 sed, 否则老系统上永远读到空值,
#    表现就是所有候选站都被判成 "不可达或不支持 H2(none|h2)" 而全部跳过。
# 只取"版本|ALPN"两段, 给 proxy audit 显示用。
# 解析逻辑与 dest_probe 共用一份: 以前两处各写一套 grep/sed, 改一处忘另一处
# 就会出现"audit 显示的和挑选时判定的不一致"这种最难查的漂移。
dest_tls_info(){
  local p
  p=$(dest_probe "$1")
  printf '%s|%s' "${p%%|*}" "$(printf '%s' "$p" | cut -d'|' -f2)"
}

# TLS 握手耗时(毫秒), 用来在同一档候选里排序。
# 只算 DNS 之后到 TLS 完成的这段: 排除 DNS 缓存造成的抖动, 剩下的才是
# "未认证探测被回落到目标站时, 探测方真正等的那段时间"。
# 测不到返回空串, 调用方按"排在本档最后"处理, 不淘汰 —— 探测失败不等于站不能用。
dest_rtt(){
  local d="$1" out tn ta
  out=$(curl -sI -o /dev/null --max-time 8 \
        -w '%{time_namelookup} %{time_appconnect}' "https://$d/" 2>/dev/null)
  # 必须是两个数, 少一个说明 curl 没给全(老版本不支持这些变量)
  case "$out" in *" "*) ;; *) return 0 ;; esac
  tn="${out%% *}"
  ta="${out##* }"
  case "$tn" in ''|*[!0-9.]*) return 0 ;; esac
  case "$ta" in ''|*[!0-9.]*) return 0 ;; esac
  # +0.5 是四舍五入: curl 给的是秒, 相减后浮点会留尾巴(0.06-0.01=49.9999…),
  # 直接 %d 截断会变成 49ms, 排序时同档位站点容易互相错位
  awk -v a="$ta" -v n="$tn" 'BEGIN{ v=(a-n)*1000; if (v<0) v=0; printf "%d", v+0.5 }'
}

# 给候选站打分排序。输出每行 "档位|耗时ms|域名", 已按 档位 -> 耗时 升序排好。
#
# 排序依据, 依次比较:
#   1) TLS 1.3 + ALPN h2   REALITY 的硬要求, 不满足的排到后面
#   2) TLS 握手耗时(ms)    越低越好 —— 未认证探测被回落到目标站时, 探测方等的
#                          就是这段; 300ms 和 20ms 的站, 观感完全是两回事
#
# 关键原则: 探测失败 ≠ 站点不可用。这里只是决定"先试谁", 真正的判据是后面的
# REALITY 握手。之前把探测失败当淘汰条件, 结果 openssl 3.0 上读不到版本号,
# 11 个候选站全被跳过, 安装直接死在"所有目标站握手失败"。
dest_rank(){
  local d info_t tier rtt pv pa pi
  local -a rows=() tiers=() names=()
  local seen="|" have_good=0 i
  for d in "$@"; do
    # 去重: REALITY_DEST 若填的正好是候选池里的域名, 同一个站会被探两次 ——
    # 白花两次往返, 还会在本档里产生一条重复记录
    case "$seen" in *"|${d}|"*) continue ;; esac
    seen="${seen}${d}|"
    is_blocked "$d" && { warn "$d 在排除名单(被墙域名/CDN 共用证书链), 跳过" >&2; continue; }
    # 一次握手拿全三样(版本/ALPN/签发者), 见 dest_probe 的说明。
    IFS='|' read -r pv pa pi <<< "$(dest_probe "$d")"
    dest_behind_cf "$d" "$pi" && {
      warn "$d 套了 Cloudflare(响应头 server/cf-ray 或证书), 跳过" >&2; continue; }
    info_t="${pv}|${pa}"
    case "$info_t" in
      "TLSv1.3|h2") tier=1 ;;
      *\|h2)        tier=2; warn "$d 只有 ${info_t}, 抗主动探测略弱, 列为备选" >&2 ;;
      *)            tier=3; warn "$d TLS 探测无结果(${info_t}), 交给真实握手判定" >&2 ;;
    esac
    [ "$tier" -le 2 ] && have_good=1
    tiers+=("$tier"); names+=("$d")
  done
  [ "${#names[@]}" -gt 0 ] || return 0

  for i in "${!names[@]}"; do
    d="${names[$i]}"; tier="${tiers[$i]}"; rtt=""
    # 只给档位 1/2 测耗时: 档位 3 本来就是"探测没结果"的站, 再花一次 8s 超时去量
    # 一个注定排最后的值不值得 —— 出站被封时这就是 11×8s 的纯等待。
    #
    # 但"一个能探的都没有"时必须照测: 那种情况(比如系统没装 openssl)所有行都会是
    # 9999, 排序退化成按域名首字母, 全网又挑到同一批站 —— 正是分档要避免的事。
    if [ "$tier" -le 2 ] || [ "$have_good" = "0" ]; then
      rtt=$(dest_rtt "$d")
    fi
    rows+=("${tier}|${rtt:-9999}|${d}")
  done
  printf '%s\n' "${rows[@]}" | sort -t'|' -k1,1n -k2,2n -k3,3
}

# 打散候选顺序。
# pick_dest 原来是按固定顺序试, 第一个握手通过的就用 —— 而候选列表是写死的,
# 于是每台用本脚本装的机器都会选中同一个站(大概率是 www.bing.com)。
# 几百台 VPS 的 REALITY SNI 全是 www.bing.com, 而它们的 ASN 都不属于微软:
# 只要统计"哪些 IP 在跟 bing 握手但 ASN 对不上", 就能把这批机器整段捞出来。
# 随机起点即可打散这个特征, 成本为零。
shuffle_words(){
  [ $# -gt 1 ] || { printf '%s\n' ${1+"$@"}; return 0; }
  if command -v shuf >/dev/null 2>&1; then
    printf '%s\n' "$@" | shuf
  else
    # 没有 shuf(极简系统)时用 awk 排序打散, 效果一样
    printf '%s\n' "$@" | awk 'BEGIN{srand()} {print rand()"\t"$0}' | sort -n | cut -f2-
  fi
}

# 换站时临时排除当前站: 点"随机换"却抽回同一个站, 用户会以为功能坏了。
# 不改写 REALITY_DESTS 常量本身 —— 那会让 shellcheck 把它当数组用过的变量,
# 也会把"池子内容"和"本次要跳过哪个"两件事混在一起。
DEST_EXCLUDE=""
pick_dest(){
  local cands=() d h d0
  # REALITY_DEST=random 表示"重新随机挑一个": 不把它当候选塞进去, 只走默认池。
  # 没有这个取值的话, 已装好的机器想换 SNI 只能点名指定某个站, 没法随机。
  [ -n "$REALITY_DEST" ] && [ "$REALITY_DEST" != "random" ] && cands+=("$REALITY_DEST")
  # 只用国内能直连的站: dest 若被墙, 用户发 SNI 时就先被 GFW 拦了, 根本到不了握手
  # REALITY_DESTS 是空格分隔的硬编码域名常量, 不含通配符, 这里的 word splitting
  # 就是取用方式。不用 `read -ra` 拆一次数组: 那样这个常量在两处的取用形式会
  # 不一致(一处数组一处字符串), 反而更容易被下次改坏。
  for d0 in $REALITY_DESTS; do
    [ "$d0" = "$DEST_EXCLUDE" ] && continue
    cands+=("$d0")
  done

  info "挑选伪装目标站(按 TLS 版本分档、档内测握手耗时, 需通过真实 REALITY 握手)..."

  # openssl 缺失/被裁掉时, TLS 版本探测必然拿不到值。这时不能把所有候选都判死,
  # 只能跳过排序, 全部交给第二遍的真实握手去筛。
  if ! command -v openssl >/dev/null 2>&1; then
    warn "系统没有 openssl, 跳过 TLS 预筛, 全部候选走真实握手验证"
  fi

  # 第一遍: 打分排序(见 dest_rank)。只决定"先试谁", 不做淘汰。
  #
  # 第二遍才真正起服务验证。
  #
  # 顺序 = 档位优先, 档内按握手耗时从快到慢; 但每档只取**最快的 3 个**来随机。
  #
  # 为什么不直接取最快的那个: 候选池是写死的, 全网几十万台机器都取第一, 结果
  # 所有 REALITY 机器的 SNI 会集中到同一个域名上 —— 统计"哪些机房 IP 在跟这个站
  # 握手"就能整段捞出来。
  # 为什么也不纯随机: 明明有个 20ms 的站, 随机到 300ms 的那个, 回落体验白差一截。
  # 取前三再随机, 两头都照顾到。
  #
  # 用户显式指定的 REALITY_DEST 必须排在最前, 否则会被别的站抢先命中,
  # 等于把"我就要这个站"的意图丢掉了。
  local reachable="" pin=""
  # 黑名单里的站不能当 pin: 它们要么被墙、要么是 CDN 共用证书链, 拿来当 SNI
  # 反而更容易被识别。
  if [ -n "$REALITY_DEST" ] && [ "$REALITY_DEST" != "random" ]; then
    if is_blocked "$REALITY_DEST"; then
      warn "REALITY_DEST=${REALITY_DEST} 在排除名单里, 忽略, 改用自动挑选"
    else
      pin="$REALITY_DEST"
    fi
  fi

  local -a order=() sorted=() grp=() top=()
  local line t2 r2 d2 item tier n_rand
  [ -n "$pin" ] && order+=("${pin}|?")
  while IFS= read -r line; do [ -n "$line" ] && sorted+=("$line"); done \
    < <(dest_rank "${cands[@]}")
  for tier in 1 2 3; do
    grp=()
    for line in ${sorted[@]+"${sorted[@]}"}; do
      IFS='|' read -r t2 r2 d2 <<< "$line"
      [ "$t2" = "$tier" ] && grp+=("${d2}|${r2}")
    done
    [ "${#grp[@]}" -gt 0 ] || continue
    # 每档取最快的 N 个来随机, N 随档内数量走: 档里站越多, 能分散的余地越大。
    #
    # 这里原来写死 3。池子扩到 40+ 之后问题就露出来了: 档位 1 有二十多个合格的
    # TLS1.3 站, 却只从最快的 3 个里随机 —— 等于白扩, 全网几十万台机器还是集中
    # 在那 3 个域名上, 统计"哪些机房 IP 在跟这三个站握手"照样能整段捞出来。
    #
    # 上限 8: 再多只是"看起来更分散", 而每个候选都要真握手一次, 试错成本在涨。
    n_rand=$(( ${#grp[@]} / 3 ))
    [ "$n_rand" -lt 3 ] && n_rand=3
    [ "$n_rand" -gt 8 ] && n_rand=8
    top=("${grp[@]:0:$n_rand}")
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      [ "${line%%|*}" = "$pin" ] && continue
      order+=("$line")
    done < <(shuffle_words ${top[@]+"${top[@]}"})
    # 随机到的这几个真实握手都失败时, 按耗时顺序补上本档剩下的 —— 不能因为
    # "没被随机到"就丢掉一个 TLS1.3 的站, 转头去试 TLS1.2 的
    for line in "${grp[@]:$n_rand}"; do
      [ "${line%%|*}" = "$pin" ] && continue
      order+=("$line")
    done
  done

  for item in ${order[@]+"${order[@]}"}; do
    d2="${item%%|*}"; r2="${item##*|}"
    h=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 "https://$d2/" 2>/dev/null)
    [ "$h" = "000" ] && { warn "$d2 不可达, 跳过"; continue; }
    [ -n "$reachable" ] || reachable="$d2"
    write_xray_config "$d2"
    $XRAY_BIN run -test -c "$XRAY_CFG" >/dev/null 2>&1 || { warn "$d2 配置校验失败, 跳过"; continue; }
    systemctl restart xray >/dev/null 2>&1
    # 轮询而不是固定 sleep 2: 慢机器上 xray 绑定端口可能超过 2 秒, 固定等待会把
    # 一个完全可用的 dest 判成"启动失败"跳掉 —— 而 wait_active 在正常情况下
    # 0.3 秒就返回, 快机器上反而更快。
    wait_active xray || { warn "$d2: xray 启动失败, 跳过"; continue; }
    if verify_reality "$d2"; then
      DEST="$d2"
      if [ "$r2" = "?" ]; then
        ok "$d2 握手通过 (HTTP $h)"
      else
        ok "$d2 握手通过 (HTTP $h, TLS 握手 ${r2}ms)"
      fi
      return 0
    fi
    warn "$d2 握手失败, 换下一个"
  done

  # 握手验证全挂但至少有一个站能直连: 兜底装上, 不要因为"验证手段"失效就中止整个安装。
  # 握手失败更可能是本机出站 443 受限 / 系统时间偏差 / 探测用的临时 xray 起不来,
  # 而不是 dest 不能用 —— REALITY 只在上游探测时才走 dest 回落, 认证客户端照样能连。
  if [ -n "$reachable" ]; then
    DEST="$reachable"
    warn "所有候选站的 REALITY 握手验证都没通过, 用 ${DEST} 兜底继续安装"
    warn "常见原因: 本机出站 443 受限 / 系统时间偏差 / 临时探测实例起不来"
    warn "装完请用客户端实测; 若不通, 换端口重装: VLESS_PORT=8443 bash $(self_hint) install"
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
    return 0
  fi

  # 一个都连不上: 把服务恢复到上一次能用的配置, 不要留在最后一个失败配置上
  local last
  last=$(ls -1t "$BACKUP_DIR"/xray-*.json 2>/dev/null | head -1)
  if [ -n "$last" ]; then
    # 就地 cp 有截断风险: 磁盘满时 XRAY_CFG 可能变成半截文件, 却还被告知"已回滚"。
    # 同目录临时文件 + 原子 mv, 并把失败传出去。
    local _rb_tmp
    _rb_tmp=$(mktemp "$(dirname "$XRAY_CFG")/.xray-rb.XXXXXX" 2>/dev/null) || _rb_tmp=""
    if [ -n "$_rb_tmp" ] && cp -f "$last" "$_rb_tmp" 2>/dev/null \
       && mv -f "$_rb_tmp" "$XRAY_CFG" 2>/dev/null; then
      systemctl restart xray >/dev/null 2>&1
      warn "已回滚到上一次可用配置: $(basename "$last")"
    else
      rm -f "$_rb_tmp"
      err "回滚失败: 无法用备份配置替换 ${XRAY_CFG}, 请手动检查"
    fi
  fi
  return 1
}

# 不开 REALITY 时的伪装目标挑选: 只做 HTTPS 可达性检查, 不依赖 xray。
# 用途: hy2 的 masquerade 站点 / 自签证书 CN, anytls 与 tuic 的 SNI。
pick_dest_simple(){
  local d h pin=""
  # 和 pick_dest 同一套打分: 显式指定优先, 其余按 档位 -> 握手耗时 排序,
  # 只在前三名里随机。纯 shuffle 的问题是明明有 20ms 的站却可能选到 300ms 的;
  # 固定取第一又会把全网 SNI 挤到同一个域名上。
  if [ -n "$REALITY_DEST" ] && [ "$REALITY_DEST" != "random" ] && ! is_blocked "$REALITY_DEST"; then
    pin="$REALITY_DEST"
  fi
  local -a pool=() sorted=() top=() order=()
  local line t d2 found i
  for d in $REALITY_DESTS; do
    [ "$d" = "$pin" ] && continue
    [ "$d" = "$DEST_EXCLUDE" ] && continue
    pool+=("$d")
  done
  [ -n "$pin" ] && order+=("$pin")
  while IFS= read -r line; do [ -n "$line" ] && sorted+=("$line"); done \
    < <(dest_rank ${pool[@]+"${pool[@]}"})
  # 打分后最快的 3 个, 打散再依次试
  i=0
  for line in ${sorted[@]+"${sorted[@]}"}; do
    [ "$i" -ge 3 ] && break
    top+=("${line##*|}")
    i=$((i + 1))
  done
  if [ "${#top[@]}" -gt 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      order+=("$line")
    done < <(shuffle_words ${top[@]+"${top[@]}"})
  fi
  # 前三个都不通时, 其余按打分顺序兜底
  for line in ${sorted[@]+"${sorted[@]}"}; do
    d2="${line##*|}"
    found=0
    for t in ${order[@]+"${order[@]}"}; do
      [ "$t" = "$d2" ] && { found=1; break; }
    done
    [ "$found" = "1" ] && continue
    order+=("$d2")
  done

  for d in ${order[@]+"${order[@]}"}; do
    is_blocked "$d" && { warn "$d 在排除名单, 跳过"; continue; }
    h=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 "https://$d/" 2>/dev/null)
    [ "$h" = "000" ] && { warn "$d 不可达, 跳过"; continue; }
    DEST="$d"; ok "伪装目标: ${d} (HTTP ${h})"; return 0
  done
  DEST="www.bing.com"
  warn "候选站全部不可达, 回退伪装目标: ${DEST}"
  return 0
}

# 三个服务(xray / hysteria-server / sing-box)共用的 systemd 加固段。
# 以前是三份逐字复制的 heredoc: 只给其中一个加一行(例如 ProtectProc)时,
# 另外两个会静默漏掉, 而这种漏掉没人会去逐行核对。集中成一份, 三份单元同源。
unit_hardening(){
  cat <<'HARDEN'
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
# 内核/配置/二进制目录一律只读: 服务只负责收发流量, 不需要写系统
ProtectSystem=full
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
UMask=0077
HARDEN
}

# 设开机自启, 并且验证真的设上了: systemd 在 /etc 只读、单元被 mask 或自身
# 处于降级状态时会拒绝 enable, 而这只在下次重启才暴露(装完 verify 全绿,
# 重启后节点静默消失)。enable 完立刻复查, 失败就明说该敲什么命令。
enable_unit(){
  local u="$1"
  systemctl enable "$u" >/dev/null 2>&1 || true
  systemctl is-enabled --quiet "$u" 2>/dev/null && return 0
  warn "无法设置开机自启: ${u} —— 重启后该服务不会自动启动"
  warn "请手动执行: systemctl enable ${u}   然后跑 proxy verify 复查"
  return 1
}

ensure_xray_service(){
  # FORCE_UNIT_REFRESH: proxy update 用它强制重写单元, 否则旧 unit 只要还含
  # PrivateTmp=true 就永远不会被新版本里的沙箱改动覆盖。
  if [ ! -f /etc/systemd/system/xray.service ] || ! grep -q 'PrivateTmp=true' /etc/systemd/system/xray.service \
     || [ "${FORCE_UNIT_REFRESH:-0}" = "1" ]; then
    {
      cat <<'UNIT'
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
UNIT
      unit_hardening
      cat <<'UNIT'
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
UNIT
    } > /etc/systemd/system/xray.service || die "写入 xray.service 失败(磁盘满/只读?)"
    systemctl daemon-reload || warn "xray.service daemon-reload 失败, 新单元可能未生效"
  fi
  enable_unit xray
}

# ---------------- Hysteria2 ----------------
# 写 hysteria2 配置。$1=1 带 sniff 段, $2=1 带 IPv4-only 出站。
# 两个开关分开是为了能逐级回退: 老版本不认 outbounds 就只丢 v4,
# 还不认 sniff 再丢 sniff —— 不至于为了一个新特性把整个服务搞挂。
write_hy2_config(){
  local sniff="$1" v4="${2:-1}" cfg_tmp=""
  # 同 Xray: 先写临时文件再原子替换, 半截 YAML 会让服务起不来。
  mkdir -p "$(dirname "$HY2_CFG")"
  cfg_tmp=$(mktemp "$(dirname "$HY2_CFG")/.config.XXXXXX.yaml") || die "无法创建 Hysteria2 配置临时文件"
  {
    echo "listen: :${HY2_PORT}"
    echo ""
    echo "tls:"
    echo "  cert: /etc/hysteria/cert.pem"
    echo "  key: /etc/hysteria/key.pem"
    # 不校验客户端 SNI: 客户端用什么 SNI 都能连, 身份由 auth 密码保证。
    # 这也是 hysteria cert 示例配置的做法, 避免客户端 SNI 与证书 CN 不一致时连不上。
    echo "  sniGuard: disable"
    echo ""
    echo "auth:"
    echo "  type: password"
    echo "  password: ${HY2_PASS}"
    echo ""
    if [ "$sniff" = "1" ]; then
      # 嗅探并把"IP 目标"改写回域名。
      # xray 侧靠 inbound 的 sniffing + routeOnly:false 做这件事: 客户端即使在本地
      # 解析了域名, 服务端也能从 TLS SNI / HTTP Host 里把域名捞回来, 再用服务端 DNS
      # 重新解析。hysteria2 默认不做 —— 客户端发 IP 就只能连那个 IP, 等于用客户端的
      # 解析结果上网, 这正是送中的一条路径。rewriteDomain 补上这一步。
      echo "sniff:"
      echo "  enable: true"
      echo "  timeout: 2s"
      echo "  rewriteDomain: true"
      echo ""
    fi
    if [ "$v4" = "1" ]; then
      # 出站强制 IPv4: 客户端就算把 AAAA 结果 / IPv6 字面地址发过来,
      # direct.mode: 4 也只连 A 记录, 不会用 VPS 的 IPv6 出口直连出去。
      # 不用 acl 的 cidr("::/0") 拦 IPv6 —— 域名请求会先被解析, 只要域名有
      # AAAA 就命中那条规则, 整个连接被拒, 正常网站会一起断掉。
      # outbounds 第一项即默认出站(hysteria2 的 default 语义), 不写 acl 时
      # 所有流量都走它, 所以不需要额外加规则。
      echo "outbounds:"
      echo "  - name: v4_only"
      echo "    type: direct"
      echo "    direct:"
      echo "      mode: 4"
      echo ""
    fi
    if [ "$ENABLE_OBFS" = "1" ]; then
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: ${OBFS_PASS}"
      echo ""
    fi
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: https://${DEST}/"
    echo "    rewriteHost: true"
    echo ""
    echo "quic:"
    echo "  initStreamReceiveWindow: 8388608"
    echo "  maxStreamReceiveWindow: 8388608"
    echo "  initConnReceiveWindow: 20971520"
    echo "  maxConnReceiveWindow: 20971520"
  } > "$cfg_tmp" || { rm -f "$cfg_tmp"; die "写入 Hysteria2 配置失败(磁盘满/权限?)"; }
  chmod 600 "$cfg_tmp"
  mv -f "$cfg_tmp" "$HY2_CFG" || { rm -f "$cfg_tmp"; die "替换 ${HY2_CFG} 失败"; }
}

ensure_hy2_service(){
  # 与 xray/sb 对齐: FORCE_UNIT_REFRESH 时必须重写单元。以前缺这个条件,
  # 老机器即使 proxy update 换了脚本, hy2 单元只要还含加固串就永远不刷新。
  if [ ! -f /etc/systemd/system/hysteria-server.service ] \
     || ! grep -q 'NoNewPrivileges=true' /etc/systemd/system/hysteria-server.service \
     || [ "${FORCE_UNIT_REFRESH:-0}" = "1" ]; then
    {
      cat <<'UNIT'
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
Type=simple
User=root
UNIT
      unit_hardening
      cat <<'UNIT'
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    } > /etc/systemd/system/hysteria-server.service || die "写入 hysteria-server.service 失败(磁盘满/只读?)"
    systemctl daemon-reload || warn "hysteria-server.service daemon-reload 失败, 新单元可能未生效"
  fi
  enable_unit hysteria-server
  systemctl restart hysteria-server >/dev/null 2>&1
}

ensure_hy2(){
  local arch asset sha_arch url ok_dl=0
  # 兜底: 没有伪装目标时证书 CN 与 masquerade 都会是空的
  DEST="${DEST:-www.bing.com}"
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)  asset="hysteria-linux-amd64"; sha_arch="amd64" ;;
    aarch64|arm64) asset="hysteria-linux-arm64"; sha_arch="arm64" ;;
    *) die "不支持的架构: $arch" ;;
  esac

  # "latest" 是哨兵: 每次部署解析一次官方最新版, 和 Xray 同一套策略。
  # 只接受 2.x —— 生成的服务端配置是 hysteria2 的格式, 官方一旦发 3.x 换了
  # 配置结构, 盲目追最新会直接把在跑的节点弄挂。跨大版本就停在基线并告警,
  # 由用户显式 HY2_VERSION=x.y.z 决定要不要上, 绝不自动跳。
  case "${HY2_VERSION:-latest}" in
    latest|'')
      local lv="" cur=""
      lv=$(hy2_latest_version)
      case "$lv" in
        2.*) : ;;
        '')  lv="" ;;
        *)   warn "Hysteria2 最新版是 v${lv}, 已跨出 2.x; 服务端配置格式可能不兼容, 本次不自动跟"
             lv="" ;;
      esac
      if [ -n "$lv" ]; then
        if [ "$lv" != "${HY2_VERSION:-}" ]; then
          info "Hysteria2 追踪最新版: ${lv}"
        fi
        HY2_VERSION="$lv"
      else
        # API 不通(国内 VPS 常见): 沿用本机已在跑的版本, 绝不降级回内置基线。
        if [ -x "$HY2_BIN" ]; then
          cur=$("$HY2_BIN" version 2>/dev/null) || cur=""
          cur=$(printf '%s\n' "$cur" | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
        fi
        case "$cur" in 2.*) ;; *) cur="$HY2_FALLBACK_VERSION" ;; esac
        warn "查询 Hysteria2 最新版失败(GitHub API 不可达), 沿用 v${cur}, 不降级"
        HY2_VERSION="$cur"
      fi ;;
  esac

  # 已装也要复验基准哈希: 内置 SHA-256 不能只在下载路径生效。xray 分支至少
  # 会比对版本, 这里以前连版本都不看, 被替换/降级的二进制会一直留着。
  local _hy2_ok=0 _hy2_ver=""
  # HY2_BIN_SHA 是上次安装时自证写进 state.env 的, 不是内置基准哈希。
  # 只看它的话, 改了 HY2_VERSION 重装会永远走"已安装且哈希一致, 跳过",
  # pinned_sha 那条校验根本没机会跑。所以要连实际版本一起比。
  # 版本号先整段读进变量再抠: pipefail 下 `hysteria version | grep | head`
  # 会因 SIGPIPE 把"版本读到了"判成失败, 于是每次都白下一遍内核。
  if [ -x "$HY2_BIN" ]; then
    local _hvout=""
    _hvout=$("$HY2_BIN" version 2>/dev/null) || _hvout=""
    _hy2_ver=$(printf '%s\n' "$_hvout" | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
  fi
  if [ -x "$HY2_BIN" ] && [ -n "${HY2_BIN_SHA:-}" ] \
     && [ "$(file_sha256 "$HY2_BIN" 2>/dev/null)" = "$HY2_BIN_SHA" ] \
     && { [ -z "$_hy2_ver" ] || [ "$_hy2_ver" = "${HY2_VERSION#v}" ]; }; then
    _hy2_ok=1
  fi
  if [ "$_hy2_ok" = "1" ]; then
    ok "Hysteria2 已安装且哈希一致, 跳过"
  else
    info "下载 Hysteria2 v${HY2_VERSION} ..."
    # 版本在上面的 latest 分支里已经定好; 这里只负责下载 + 校验。
    # tag 历史上有 app/ 前缀, 两种形式都试。仓库已迁到 HyNetworks/hysteria
    # (旧名 apernet/hysteria 仍 301, 这里直接用新址, 少一层重定向)。
    local htmp; htmp=$(mktemp -d) || die "无法创建临时目录"
    for url in \
      "https://github.com/HyNetworks/hysteria/releases/download/app/v${HY2_VERSION}/${asset}" \
      "https://github.com/HyNetworks/hysteria/releases/download/v${HY2_VERSION}/${asset}" ; do
      if download_with_mirror "$url" "$htmp/hy2.bin"; then ok_dl=1; break; fi
    done
    [ "$ok_dl" = "1" ] || { rm -rf "$htmp"; die "Hysteria2 下载失败"; }
    # 官方 hashes.txt 优先, 内置值兜底, 冲突拒绝 —— 与 Xray 同一套闸门。
    local _hy2_want
    _hy2_want=$(hy2_expected_sha "$HY2_VERSION" "$sha_arch" "$asset") \
      || { rm -rf "$htmp"; die "Hysteria2 校验值获取失败, 已中止"; }
    verify_sha256 "$htmp/hy2.bin" "$_hy2_want" "Hysteria2 v${HY2_VERSION}" \
      || { rm -rf "$htmp"; die "Hysteria2 校验未通过, 已中止"; }
    chmod 700 "$htmp/hy2.bin"
    systemctl stop hysteria-server >/dev/null 2>&1 || true
    # 同 Xray: 装失败必须当场停手。上面已经 stop 了服务, 静默失败会留下
    # "服务停了 + 屏幕报已安装 + 哈希算的是旧二进制" 的组合。
    install -m 755 "$htmp/hy2.bin" "$HY2_BIN" \
      || { rm -rf "$htmp"; die "安装 Hysteria2 二进制失败(磁盘空间或权限?), 服务已停止, 请排查后重跑 install"; }
    rm -rf "$htmp"
    HY2_BIN_SHA=$(file_sha256 "$HY2_BIN")
    [ -n "$HY2_BIN_SHA" ] || die "无法计算 Hysteria2 二进制哈希, 安装不可信"
    ok "Hysteria2 已安装: $($HY2_BIN version 2>/dev/null | grep -m1 '^Version:' | cut -f2)"
  fi

  # 96 位熵对在线爆破已经够用, 但 hy2 密码会明文出现在客户端配置里,
  # 128 位不增加任何成本, 直接用满。
  [ -n "${HY2_PASS:-}" ] || HY2_PASS=$(openssl rand -hex 16)
  if [ "$ENABLE_OBFS" = "1" ] && [ -z "${OBFS_PASS:-}" ]; then
    OBFS_PASS=$(openssl rand -hex 16)
  fi
  # 密码会裸写进 YAML 和 hysteria2:// URI: 带 : # & 引号会写坏配置(甚至被
  # YAML 当成注释/锚点)。state.env 被手改或从旧备份恢复时可能出现这种值,
  # 直接重新生成 —— 反正重新生成后订阅也会一起重发。
  case "${HY2_PASS}" in
    *[!A-Za-z0-9._~-]*)
      warn "HY2_PASS 含 YAML/URI 特殊字符, 已重新生成"
      HY2_PASS=$(openssl rand -hex 16) ;;
  esac
  if [ "$ENABLE_OBFS" = "1" ]; then
    case "${OBFS_PASS}" in
      *[!A-Za-z0-9._~-]*)
        warn "OBFS_PASS 含 YAML/URI 特殊字符, 已重新生成"
        OBFS_PASS=$(openssl rand -hex 16) ;;
    esac
  fi

  mkdir -p /etc/hysteria
  # 证书只在"缺失"时生成是不够的: 换了伪装站(REALITY_DEST=random / 上一个站被墙)
  # 之后, 证书 CN 还是旧站, 而配置里的 server_name / masquerade 已经指向新站 ——
  # 主动探测一比对就是破绽, 部分客户端也会因此握手异常。
  if [ ! -f /etc/hysteria/cert.pem ] || [ ! -f /etc/hysteria/key.pem ] \
     || [ "$(cert_cn /etc/hysteria/cert.pem)" != "$DEST" ]; then
    info "生成 hysteria2 自签证书 (CN=${DEST})"
    make_self_signed_cert /etc/hysteria/cert.pem /etc/hysteria/key.pem "$DEST" \
      || die "证书生成失败"
  fi
  chmod 600 /etc/hysteria/key.pem

  write_hy2_config 1 1

  ensure_hy2_service
  # 全部改成轮询。这里误判的代价不只是"报错": 每判错一级就真的降一级配置 ——
  # 丢掉 IPv4-only 出站(hy2 会走 v6 出去, 白送一个泄露面)、再丢掉 sniff
  # (少一层防送中)。一次计时竞态换一次安全降级, 不能接受。
  # sniff 段和 outbounds 都是较新版本才认的。起不来就逐级去掉重写, 而不是让
  # 整个安装失败 —— 少一层防送中 / IPv6 兜底, 和完全没网可用不对等。
  # 先丢 IPv4-only(新加的), 再丢 sniff; 每级都真重启一次确认。
  if ! wait_active hysteria-server; then
    warn "带 IPv4-only 出站的 hysteria2 配置未能启动, 去掉该段重试(该版本可能不支持 outbounds)"
    write_hy2_config 1 0
    systemctl restart hysteria-server >/dev/null 2>&1
  fi
  if ! wait_active hysteria-server; then
    warn "去掉 IPv4-only 后仍起不来, 再去掉 sniff 段重试(该版本可能不支持)"
    write_hy2_config 0 0
    systemctl restart hysteria-server >/dev/null 2>&1
  fi
  wait_active hysteria-server || die "Hysteria2 未能启动, 查看: journalctl -u hysteria-server -n 30"
  ok "Hysteria2 运行中, 监听 UDP ${HY2_PORT}"

  # 自签证书必须靠指纹固定来验证身份, 否则 insecure 等于对中间人完全敞开。
  # hysteria2 的 pinSHA256 = 整张证书 DER 的 SHA-256, 小写 hex 无冒号(64 字符)。
  # 这一点由 `hysteria cert` 的输出直接确认过, 不是 SPKI、也不是 base64。
  # 客户端配置必须 insecure:true + pinSHA256 同时给: insecure 负责跳过 CA 校验,
  # pinSHA256 才是真正的身份校验(官方示例就是这么配的)。
  compute_cert_pins || die "证书指纹计算失败, 拒绝以 insecure 方式部署 (确需跳过请显式加 HY2_INSECURE=1)"
  if [ "$HY2_INSECURE" = "1" ]; then
    HY2_PIN=""
    warn "HY2_INSECURE=1: 客户端将跳过证书验证, 链路上可被冒充(仅建议临时调试)"
  else
    HY2_PIN="${CERT_HEX:-}"
    [ -n "$HY2_PIN" ] || die "无法计算证书指纹(SHA-256 hex)"
    ok "证书固定已启用: ${HY2_PIN:0:24}..."
    if verify_hy2 "$HY2_PIN"; then
      ok "本机握手自测: 通过 (证书固定已验证)"
    else
      warn "本机握手自测未通过, 配置仍使用证书固定, 不回退 insecure"
      warn "  常见原因: 出站测试站不可达 / UDP 回环受限 / 客户端启动慢"
      warn "  客户端若报证书错误, 核对服务端指纹:"
      echo -e "    ${D}openssl x509 -in /etc/hysteria/cert.pem -noout -fingerprint -sha256${N}"
    fi
  fi
}

# ---------------- sing-box 内核: ss2022 / anytls / tuic ----------------
# 这三个协议由同一个 sing-box 进程承载, 端口各自独立, 共用一份自签证书
# SB_VERSION / SB_FALLBACK_VERSION 在文件顶部默认参数区定义(与 Xray / HY2 并列,
# 三个组件的版本策略放在一起才看得出是一套, 别在这里重复定义导致两处漂移)。

sb_enabled(){ proto_on ss2022 || proto_on anytls || proto_on tuic; }

sb_port_summary(){
  local p=""
  proto_on ss2022 && p="${p} SS2022/${SS2022_PORT}"
  proto_on anytls && p="${p} AnyTLS/${ANYTLS_PORT}"
  proto_on tuic   && p="${p} TUIC/${TUIC_PORT}"
  echo "${p# }"
}

ensure_singbox(){
  sb_enabled || return 0
  local arch asset tmp bin
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac

  # "latest" 是哨兵: 每次部署解析一次官方最新版, 与 Xray / Hysteria2 同一套策略。
  # 和 HY2 那个 2.x 白名单不同, 这里**不**用大版本号卡: sing-box 的配置格式变化
  # 不看大版本(1.11 -> 1.12 就删了 legacy inbound 和 geoip), 卡大版本挡不住,
  # 真正能挡住的是下面的"新内核 check 现有配置", 那个是实测不是猜。
  case "${SB_VERSION:-latest}" in
    latest|'')
      local lv="" cur=""
      lv=$(sb_latest_version)
      if [ -n "$lv" ]; then
        if [ "$lv" != "${SB_VERSION:-}" ]; then
          info "sing-box 追踪最新版: ${lv}"
        fi
        SB_VERSION="$lv"
      else
        # API 不通(国内 VPS 常见): 沿用本机已在跑的版本, 绝不降级回内置基线。
        cur=$(sb_installed_version)
        [ -n "$cur" ] || cur="$SB_FALLBACK_VERSION"
        warn "查询 sing-box 最新版失败(GitHub API 不可达), 沿用 v${cur}, 不降级"
        SB_VERSION="$cur"
      fi ;;
  esac

  asset="sing-box-${SB_VERSION}-linux-${arch}.tar.gz"

  # 不能写成 `"$SB_BIN" version | grep -qF ...`: 脚本开了 pipefail, grep -q 命中后
  # 立刻退出, 还在写的 sing-box 会吃到 SIGPIPE(141), 整条管道判为失败 —— 于是
  # "已装且版本正确"被误判成"没装", 每次 install 都白下一遍 sing-box。
  # 先把输出整段读进变量, 退出码与管道无关(和 ensure_xray 里同一个坑)。
  # 只取首行并在两边补空格, 避免 1.14.4 误配到 11.14.4。
  local vout="" vline=""
  if [ -x "$SB_BIN" ]; then
    vout=$("$SB_BIN" version 2>/dev/null) || vout=""
    vline="${vout%%$'\n'*}"
  fi
  case " ${vline} " in
    *" ${SB_VERSION} "*)
      ok "sing-box v${SB_VERSION} 已安装, 跳过"
      return 0 ;;
  esac

  info "下载 sing-box v${SB_VERSION} ..."
  tmp=$(mktemp -d) || die "无法创建临时目录"
  download_with_mirror \
    "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${asset}" \
    "$tmp/sb.tar.gz" || { rm -rf "$tmp"; die "sing-box 下载失败(检查服务器能否访问 GitHub)"; }
  # 官方 release digest 优先, 内置值兜底, 冲突拒绝 —— 与 Xray / HY2 同一套闸门。
  local _want_sha
  _want_sha=$(sb_expected_sha "$SB_VERSION" "$arch" "$asset") \
    || { rm -rf "$tmp"; die "sing-box 校验值获取失败, 已中止"; }
  verify_sha256 "$tmp/sb.tar.gz" "$_want_sha" "sing-box v${SB_VERSION}" \
    || { rm -rf "$tmp"; die "sing-box 校验未通过, 已中止"; }
  tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "sing-box 解压失败"; }
  bin=$(find "$tmp" -type f -name sing-box 2>/dev/null | head -1)
  [ -n "$bin" ] || { rm -rf "$tmp"; die "压缩包内未找到 sing-box"; }

  # 兼容闸门: 只有新内核能读懂**现有**配置, 才允许它替换掉在跑的二进制。
  # 追最新最大的风险不在下载, 而在"新版删了老配置里的字段, 换完服务起不来" ——
  # 那时节点已经断了, 用户还得登进来救。用新二进制 check 一遍是实测, 比按版本号
  # 猜准得多(也正因为如此, 这里不需要给 sing-box 加版本白名单)。
  # 全新安装没有配置可校验, 直接往下走: write_singbox_config 写完后会再 check,
  # 那时失败也只是"装不上", 不会弄挂一个已经在跑的节点。
  if [ -f "$SB_CFG" ] && [ -x "$SB_BIN" ]; then
    local _clog="$tmp/check.log" _crc=0
    "$bin" check -c "$SB_CFG" >"$_clog" 2>&1 || _crc=$?
    case "$_crc" in
      0) : ;;
      # 126/127 = 执行不了(权限/缺解释器), 不是配置问题。/tmp 挂 noexec 的加固机器
      # 上很常见, 这种情况不能当成"新版本不兼容"把升级拦掉 —— 那样用户会一直
      # 卡在老版本上, 还以为是上游的问题。
      126|127)
        warn "无法在临时目录执行新内核(可能 /tmp 为 noexec), 跳过升级前配置预检" ;;
      *)
        warn "sing-box v${SB_VERSION} 无法解析当前配置, 已放弃升级(现有内核继续运行, 未做改动):"
        sed -n '1,4p' "$_clog" 2>/dev/null | sed 's/^/    /' >&2
        local _curver=""
        _curver=$(sb_installed_version)
        [ -n "$_curver" ] || _curver="$SB_FALLBACK_VERSION"
        warn "  多半是新版删改了配置字段。要装就先把配置改到新格式, 或指定可用版本:"
        warn "    SB_VERSION=${_curver} bash setup-proxy.sh install"
        rm -rf "$tmp"
        return 0 ;;
    esac
  fi

  # 留一份上一版二进制: 万一新内核 check 过了但运行期才暴露问题, 一行 mv 就能回滚,
  # 不用重新下载(那时 GitHub 往往也连不上)。每次升级覆盖同一份, 只占一个副本。
  if [ -x "$SB_BIN" ]; then
    # 回滚点也必须原子写: cp -f 会先截断 .prev, 中途失败就把唯一的回滚点
    # 变成半截文件; 紧接着的新版安装再失败, 旧版和回滚点一起没了。
    local pb=""
    pb=$(mktemp "${SB_BIN}.prev.XXXXXX") || die "无法创建 sing-box 回滚点临时文件"
    cp -f "$SB_BIN" "$pb" 2>/dev/null || { rm -f "$pb"; die "备份旧版 sing-box 失败"; }
    chmod 755 "$pb" 2>/dev/null || { rm -f "$pb"; die "备份旧版 sing-box 失败(权限?)"; }
    mv -f "$pb" "${SB_BIN}.prev" 2>/dev/null || { rm -f "$pb"; die "写入 sing-box 回滚点失败"; }
  fi
  systemctl stop sing-box >/dev/null 2>&1 || true
  if ! install -m 755 "$bin" "$SB_BIN"; then
    # 服务在上面已经停掉了。不把旧版装回去就是让节点直接下线 ——
    # Xray / Hysteria2 两处都是失败即 die, 这里漏了同样的处理。
    rm -rf "$tmp"
    if [ -x "${SB_BIN}.prev" ]; then
      install -m 755 "${SB_BIN}.prev" "$SB_BIN" >/dev/null 2>&1
      systemctl start sing-box >/dev/null 2>&1
    fi
    die "安装 sing-box 二进制失败(磁盘满/权限?), 已尝试恢复旧版并重启服务"
  fi
  rm -rf "$tmp"
  mkdir -p "$(dirname "$SB_CFG")"; chmod 700 "$(dirname "$SB_CFG")"
  # Xray / Hysteria2 都查了哈希非空, 这里漏了: 空值写进 state.env 后
  # proxy verify 的 chk_bin_sha 会打印"未记录"并 return 0, 校验假绿。
  SB_BIN_SHA=$(file_sha256 "$SB_BIN") || die "无法计算 sing-box 二进制哈希"
  [ -n "$SB_BIN_SHA" ] || die "sing-box 二进制哈希为空, 拒绝继续"
  ok "sing-box 已安装: $($SB_BIN version 2>/dev/null | head -1)"
}

ensure_sb_cert(){
  sb_enabled || return 0
  mkdir -p "$SB_DIR"; chmod 700 "$SB_DIR"
  local cn="${DEST:-www.bing.com}"
  # 与 hysteria2 侧同理: 换了伪装站要跟着换证书, 否则 CN 与 server_name 对不上。
  if [ ! -f "$SB_CERT" ] || [ ! -f "$SB_KEY" ] \
     || [ "$(cert_cn "$SB_CERT")" != "$cn" ]; then
    make_self_signed_cert "$SB_CERT" "$SB_KEY" "$cn" || die "sing-box 证书生成失败"
  fi
  chmod 600 "$SB_KEY"; chmod 644 "$SB_CERT"
  # 只要 SPKI 这一种: sing-box 的 TLS 出站固定证书只有
  # certificate_public_key_sha256 一个字段, 吃的就是公钥 SPKI 的 base64。
  # 这里以前还多算了一份"整证书 SHA-256 hex"(SB_HEX), 但它在 sing-box 侧
  # 没有任何对应字段 —— 每次安装白跑一条 openssl 管道, 写进 state.env 占一行,
  # 列进 CRED_KEYS 每次读状态还要多校验一个值, 全脚本却没人读它。删掉。
  SB_PIN=$(openssl x509 -in "$SB_CERT" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary | openssl base64 -A)
  # 与 Hysteria2 侧对齐(那里是 compute_cert_pins || die): 指纹算不出来时
  # sb_tls 会静默退回 insecure:true, 自签证书没有 CA 校验, 等于对 MITM 敞开。
  [ -n "$SB_PIN" ] || die "sing-box 证书指纹计算失败, 拒绝以 insecure 方式部署"
}

# 由 UUID 无状态派生密码: 不额外占状态字段, 换 UUID 即换密码
derive_hex(){
  printf '%s' "$1" | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.*= *//' | cut -c1-32
}

# SS2022 要求 base64 编码的 16 字节密钥
derive_ss_key(){
  printf '%s' "$1" | openssl dgst -sha256 -binary 2>/dev/null | head -c 16 | openssl base64 -A
}

# SS2022 多用户模式下客户端的真实密码。
# 服务端配了 users 数组就走 EIH 多用户模式, 客户端密码必须是
# "服务端密钥:设备密钥"(冒号分隔, 两段都是 base64 16 字节)。
# 只给设备密钥会被服务端直接拒掉 —— 这一点由 sing-shadowsocks2 的
# NewMethod 源码确认: strings.Split(password, ":") 得到 pskList,
# 长度 > 1 才走 EIH, 长度 == 1 就是单用户模式, 与多用户服务端不匹配。
ss_pass_for(){
  local u="${1:-${UUID}}"
  if [ -n "${SS2022_PASS:-}" ]; then
    printf '%s:%s' "$SS2022_PASS" "$(derive_ss_key "$u")"
  else
    derive_ss_key "$u"
  fi
}

ensure_sb_creds(){
  sb_enabled || return 0
  [ -n "${SS2022_PASS:-}" ] || SS2022_PASS=$(openssl rand -base64 16)
  [ -n "${ANYTLS_PASS:-}" ] || ANYTLS_PASS=$(openssl rand -hex 16)
  [ -n "${TUIC_PASS:-}" ]   || TUIC_PASS=$(openssl rand -hex 16)
  [ -n "${TUIC_UUID:-}" ]   || TUIC_UUID=$(gen_uuid)
}

# JSON 字符串转义。设备名来自 users.txt, 可能是历史遗留或手改的,
# 这里兜一道: 名字里带 " 或 \ 不会把整份 sing-box 配置写坏。
json_esc(){
  printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\037\177'
}

# 生成 sing-box users 数组. kind: tuic | anytls | ss
sb_users_json(){
  local kind="$1" out="" u name
  if [ -f "$USERS_FILE" ]; then
    # `|| [ -n "$u" ]`: 文件末行没换行时 read 会返回非 0, 但 u/name 已被赋值。
    # 少了这半句, 最后一条设备就被静默丢掉 —— 首行(UUID)在时看着"有用户",
    # 实际最后一名的 TUIC/AnyTLS/SS 密码没写进 sing-box, 那台设备连不上。
    while IFS='|' read -r u name _ || [ -n "$u" ]; do
      [ -n "$u" ] || continue
      # 同 build_clients_json: UUID 会进 JSON, 非法字符直接跳过这行。
      case "$u" in *[!0-9A-Fa-f-]*) continue ;; esac
      name=$(json_esc "$name")
      case "$kind" in
        tuic)   out="${out}{\"uuid\":\"${u}\",\"password\":\"$(derive_hex "$u")\"}," ;;
        anytls) out="${out}{\"name\":\"${name}\",\"password\":\"$(derive_hex "$u")\"}," ;;
        ss)     out="${out}{\"name\":\"${name}\",\"password\":\"$(derive_ss_key "$u")\"}," ;;
      esac
    done < "$USERS_FILE"
  fi
  if [ -z "$out" ]; then
    case "$kind" in
      tuic)   out="{\"uuid\":\"${TUIC_UUID}\",\"password\":\"${TUIC_PASS}\"}," ;;
      anytls) out="{\"name\":\"default\",\"password\":\"${ANYTLS_PASS}\"}," ;;
      ss)     out="{\"name\":\"default\",\"password\":\"$(derive_ss_key "${UUID:-default}")\"}," ;;
    esac
  fi
  printf '[%s]' "${out%,}"
}

# sing-box 的 listen 用 "::" 才能同时吃 v4/v6, 但在 disable_ipv6=1 的机器上
# bind 会直接失败, 那种机器必须退成 0.0.0.0, 否则三个协议一起起不来。
sb_listen_addr(){
  # 启动失败回退到 v4 时由 ensure_singbox_service 置 1
  [ "${SB_FORCE_V4:-0}" = "1" ] && { echo "0.0.0.0"; return 0; }
  # 只认 disable_ipv6=1 不够: 内核用 ipv6.disable=1 启动、模块没加载、
  # LXC/OpenVZ/Docker 容器里 /proc/sys/net/ipv6 根本不存在。这时返回 "::"
  # 会让 ss2022/anytls/tuic 三个 inbound 一起 bind 失败。
  if [ ! -d /proc/sys/net/ipv6 ]; then
    echo "0.0.0.0"; return 0
  fi
  if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] \
     && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = "1" ]; then
    echo "0.0.0.0"; return 0
  fi
  # 有 /proc 目录也不等于能建 AF_INET6 socket(部分容器挂了 /proc 却禁了 v6)。
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import socket; s=socket.socket(socket.AF_INET6, socket.SOCK_STREAM); s.bind(("::1",0)); s.close()' >/dev/null 2>&1; then
      echo "0.0.0.0"; return 0
    fi
  fi
  echo "::"
}

write_singbox_config(){
  sb_enabled || return 0
  # users.txt 是设备凭据的唯一来源: xray clients / sing-box users / 分享链接
  # 三处都从它派生。少了它, sb_users_json 会退回 TUIC_UUID / ANYTLS_PASS 那套
  # 老字段, 而 gen_links 用的是 users.txt 首行(退化成 $UUID) —— 两边算出的
  # 凭据不同, 客户端导进去必然连不上, 且报错指向"密码错误"这种误导方向。
  # 这里先确保它在, 让三处永远读同一份。幂等: 已存在时什么都不做。
  ensure_users_file || die "无法写入 ${USERS_FILE}, 拒绝继续生成配置"
  # cfg_tmp 必须显式赋空: `local a=1 b` 里的 b 是"未定义"而不是空串,
  # set -u 下第一次取值就崩(这个坑被回归 harness 抓到过)。
  local tls_h2 tls_h3 dest sb_listen cfg_tmp=""
  mkdir -p "$(dirname "$SB_CFG")"
  # server_name 不能空: 证书 CN 那边已经兜底成 www.bing.com, 这里必须跟着一致
  dest="${DEST:-www.bing.com}"
  sb_listen=$(sb_listen_addr)

  tls_h2=$(printf '{"enabled":true,"server_name":"%s","certificate_path":"%s","key_path":"%s","alpn":["h2","http/1.1"]}' \
    "$dest" "$SB_CERT" "$SB_KEY")
  tls_h3=$(printf '{"enabled":true,"server_name":"%s","certificate_path":"%s","key_path":"%s","alpn":["h3"]}' \
    "$dest" "$SB_CERT" "$SB_KEY")

  # 生成 inbounds 数组。$1 是要追加到每个 inbound 末尾的字段:
  #   空串                                  -> 什么都不加
  #   ,\n "sniff": true, ...                -> 旧版 sing-box 的 inbound 级嗅探
  # 追加点放在每个对象最后一个字段之后, 空串时 JSON 依然合法。
  #
  # 为什么需要两种写法: route 里的 {"action":"sniff"} 是 1.11 才有的; 1.8~1.10
  # 只有 inbound 上的 sniff + sniff_override_destination。原实现只试新写法,
  # 老内核上直接放弃嗅探 —— 等于 ss2022/anytls/tuic 三个协议在服务端看不到域名,
  # 客户端本地解析出来的 IP 一路带到底, 这正是送中的一条路。
  sb_inbounds_json(){
    local sf="${1:-}" parts=()
    if proto_on ss2022; then
      parts+=("$(cat <<JSON
    {
      "type": "shadowsocks",
      "tag": "ss2022-in",
      "listen": "${sb_listen}",
      "listen_port": ${SS2022_PORT},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS2022_PASS}",
      "users": $(sb_users_json ss)${sf}
    }
JSON
)")
    fi
    if proto_on anytls; then
      parts+=("$(cat <<JSON
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "${sb_listen}",
      "listen_port": ${ANYTLS_PORT},
      "users": $(sb_users_json anytls),
      "tls": ${tls_h2}${sf}
    }
JSON
)")
    fi
    if proto_on tuic; then
      parts+=("$(cat <<JSON
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "${sb_listen}",
      "listen_port": ${TUIC_PORT},
      "users": $(sb_users_json tuic),
      "congestion_control": "bbr",
      "tls": ${tls_h3}${sf}
    }
JSON
)")
    fi
    [ "${#parts[@]}" -gt 0 ] || { printf ''; return 0; }
    printf '%s\n' "$(printf '%s,\n' "${parts[@]}" | sed '$ s/,$//')"
  }

  # 上游出口: 与 xray 侧同样处理, 只是这里用 route.final 指定默认出站。
  # block 出站是给 IPv6 目标用的黑洞。用这个内置类型而不是 action:reject ——
  # reject 是 sing-box 1.13 才有的, 1.11/1.12 上写了直接 check 失败。
  local sb_ob sb_final="direct" sb_line sb_scheme sb_host sb_port sb_user sb_pass sb_cred=""
  if sb_line=$(parse_egress); then
    IFS='|' read -r sb_scheme sb_host sb_port sb_user sb_pass <<< "$sb_line"
    [ -n "$sb_user" ] && sb_cred=", \"username\": \"${sb_user}\", \"password\": \"${sb_pass}\""
    sb_ob="  \"outbounds\": [
    { \"type\": \"${sb_scheme}\", \"tag\": \"egress\", \"server\": \"${sb_host}\", \"server_port\": ${sb_port}${sb_cred} },
    { \"type\": \"direct\", \"tag\": \"direct\" },
    { \"type\": \"block\", \"tag\": \"block\" }
  ],"
    sb_final="egress"
  else
    sb_ob='  "outbounds": [ { "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" } ],'
  fi

  # 域名嗅探 + IPv6 目标拦截。客户端如果先本地把域名解析成 IP 再发过来,
  # 服务端就只能连那个 IP; 解析结果一旦是境外 CDN 的地址, Google 反查就落到
  # 客户端所在地 —— 也就是送中。
  #   xray        : inbound sniffing + routeOnly:false
  #   hysteria2   : sniff + rewriteDomain
  #   sing-box    : 1.11+ 用 route 的 sniff 动作; 1.8~1.10 只有 inbound 级嗅探
  # 两组写法都按「新 → 旧 → 不带」依次试, 每份先过 sing-box check 再落盘,
  # 老内核不会因为多了新规则就起不来。
  #   IPv6 : 1.11+ 用 action:route + outbound:block; 1.8~1.10 用纯 outbound:block。
  #          ip_version:6 只匹配「目标本身就是 IPv6 字面地址」; 域名请求交给
  #          客户端订阅的 ipv4_only / 服务端解析策略兜底, 不在这里误杀。
  # 外层 v6try 是最后一道保险: 万一某版本连 ip_version 都不认, 整条 v6 规则
  # 撤掉, 按原来三种 sniff 写法再跑一遍 —— 屏蔽丢了, 但服务必须能起。
  local attempt slog v6try v6_on=0 sniff_rule sniff_sf v6_rule rules
  slog=$(mktemp) || die "无法创建临时文件"
  # 与配置同目录建临时文件, 保证 mv 是同文件系统内的原子替换(跨盘 mv 会退化成
  # 拷贝, 中途断电就留下半份 JSON)。
  # 与 Xray 同理: sing-box check 也按扩展名判断配置格式。
  cfg_tmp=$(mktemp "$(dirname "$SB_CFG")/.config.XXXXXX.json") || { rm -f "$slog"; die "无法创建 sing-box 配置临时文件"; }
  for v6try in 1 0; do
    for attempt in 1 2 0; do
      case "$attempt" in
        1)
          sniff_rule='{ "action": "sniff" }'
          sniff_sf=""
          v6_rule='{ "ip_version": 6, "action": "route", "outbound": "block" }'
          ;;
        2)
          sniff_rule=""
          sniff_sf=$',\n      "sniff": true,\n      "sniff_override_destination": true'
          v6_rule='{ "ip_version": 6, "outbound": "block" }'
          ;;
        *)
          sniff_rule=""
          sniff_sf=""
          v6_rule='{ "ip_version": 6, "outbound": "block" }'
          ;;
      esac
      if [ "$v6try" = "1" ]; then
        rules="$v6_rule"
        [ -n "$sniff_rule" ] && rules="${rules}, ${sniff_rule}"
      else
        rules="$sniff_rule"
      fi
      {
        echo "{"
        echo '  "log": { "level": "warn", "timestamp": true },'
        printf '  "inbounds": [\n%s\n  ],\n' "$(sb_inbounds_json "$sniff_sf")"
        printf '%s\n' "$sb_ob"
        printf '  "route": { "rules": [ %s ], "final": "%s" }\n' "$rules" "$sb_final"
        echo "}"
      } > "$cfg_tmp" || { rm -f "$cfg_tmp" "$slog"; die "写入 sing-box 配置失败(磁盘满/权限?)"; }

      if "$SB_BIN" check -c "$cfg_tmp" >"$slog" 2>&1; then
        v6_on=$v6try
        case "$attempt" in
          2) warn "sing-box 不认 route 的 sniff 动作, 已改用 inbound 级嗅探(能防送中, 但建议 proxy upgrade 升到 1.11+)" ;;
          0) warn "sing-box 不支持任何形式的域名嗅探, 已跳过域名还原(ss2022/anytls/tuic 会按客户端发来的 IP 直连)" ;;
        esac
        break 2
      fi
      if [ "$v6try" = "0" ] && [ "$attempt" = "0" ]; then
        err "sing-box 配置校验失败:"
        sed -n '1,5p' "$slog" | sed 's/^/    /' >&2
        rm -f "$slog" "$cfg_tmp"
        die "请把上面几行发给我"
      fi
    done
  done
  rm -f "$slog"
  [ "$v6_on" = "1" ] || warn "当前 sing-box 不接受 IPv6 拦截规则, 已跳过; 建议在服务商侧关掉公网 IPv6"
  # 直接写正式路径的话, 六轮全失败时留在盘上的就是那份非法 JSON:
  # 内核还在用内存里的旧配置跑, 看着正常, 下次重启就起不来。
  chmod 600 "$cfg_tmp"
  mv -f "$cfg_tmp" "$SB_CFG" || { rm -f "$cfg_tmp"; die "替换 ${SB_CFG} 失败"; }
}

ensure_singbox_service(){
  sb_enabled || return 0
  if [ ! -f /etc/systemd/system/sing-box.service ] \
     || ! grep -q 'NoNewPrivileges=true' /etc/systemd/system/sing-box.service \
     || [ "${FORCE_UNIT_REFRESH:-0}" = "1" ]; then
    {
      cat <<'UNIT'
[Unit]
Description=sing-box Server
After=network.target

[Service]
Type=simple
User=root
UNIT
      unit_hardening
      cat <<'UNIT'
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    } > /etc/systemd/system/sing-box.service || die "写入 sing-box.service 失败(磁盘满/只读?)"
    systemctl daemon-reload || warn "sing-box.service daemon-reload 失败, 新单元可能未生效"
  fi
  enable_unit sing-box
  systemctl restart sing-box >/dev/null 2>&1
  # 轮询而非固定等待: 误判的代价是把本来能用的 "::" 监听换成 0.0.0.0,
  # 双栈机器上白白丢掉 IPv6。
  if ! wait_active sing-box && [ "$(sb_listen_addr)" = "::" ]; then
    # 探测说有 v6, 但 bind("::") 实际失败(容器 / 内核禁用了 v6 socket)。
    # 不回退就是三个协议一起起不来; hy2 侧早就有同类的启动失败回退。
    warn "sing-box 以 :: 监听失败(本机可能没有可用的 IPv6 socket), 改用 0.0.0.0 重试"
    SB_FORCE_V4=1
    write_singbox_config
    systemctl restart sing-box >/dev/null 2>&1
  fi
  wait_active sing-box \
    || die "sing-box 未能启动, 查看: journalctl -u sing-box -n 30 --no-pager"
  ok "sing-box 运行中: $(sb_port_summary)"
}

# 自签证书的两种指纹表示, 对应不同客户端字段(算法不同, 不能混用):
#   整证书 SHA-256 (hex)    -> hysteria2 URI / 配置里的 pinSHA256; mihomo 的 fingerprint
#                              已用 `hysteria cert` 的输出核对过, 就是整证书 DER 的 hex
#   SPKI 公钥 SHA-256 (b64) -> sing-box 的 certificate_public_key_sha256
# 脚本里不带参调用(默认就是 hysteria 证书), 但测试会传一张临时证书进来做独立
# 复算 —— 参数是给测试留的, 所以 SC2120 在这里是误报。
# 指令必须紧贴命令且后面不跟文字: 写成 `disable=SC2120  (说明)` 时 shellcheck
# 会把括号里那段当成下一个 key=value, 报 SC1125 并**整条忽略掉**。
# shellcheck disable=SC2120
compute_cert_pins(){
  # $1 可选, 默认就是 hysteria2 的证书路径。做成参数是为了能被回归套件
  # 用一张临时证书直接验证 —— 否则这段唯一的算法只能靠肉眼审。
  local cert="${1:-/etc/hysteria/cert.pem}"
  [ -f "$cert" ] || return 1
  CERT_SPKI_B64=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null)
  # CERT_HEX 是 hysteria2 的 pinSHA256: **整张证书 DER** 的 SHA-256, 小写 hex 无冒号。
  # 它和上面的 SPKI 不是一回事(SPKI 只覆盖公钥, 给 sing-box 用), 两个都要算。
  # 曾经这里只剩 SPKI 一项, CERT_HEX 全脚本没人赋值 —— 于是本函数恒返回失败,
  # ensure_hy2 每次都 die 在"证书指纹计算失败", 默认组合 reality,hy2 直接装不完。
  # 算法与 hysteria2 自带的 `hysteria cert` 输出一致(已核对过), 全脚本只有这一份。
  CERT_HEX=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null \
    | sed 's/^.*=//; s/://g' | tr 'A-F' 'a-f')
  # DER 那份从来没被读过, 不再列进成功条件: openssl 偶发失败就整个部署 die 不值得。
  [ -n "$CERT_SPKI_B64" ] && [ -n "$CERT_HEX" ]
}

# 用真实握手验证一条 pin 是否被服务端接受; pin 为空则测 insecure
# 注意: 这个测试只用于"确认/诊断", 不参与是否启用证书固定的决策
verify_hy2(){
  local pin="${1:-}" code i pid
  [ -x "$HY2_BIN" ] || return 1

  # 自测配置里有 hy2 明文密码, 不能放在 /tmp: 世界可写的目录里
  # 既会被同机用户读到, 也能被预先做成软链接。改用 0700 的 /run 子目录。
  local hcd=/run/proxy-hc
  mkdir -p "$hcd" 2>/dev/null; chmod 700 "$hcd" 2>/dev/null

  # 清掉上次可能残留的客户端, 否则 10898 端口会假就绪
  pkill -f "hysteria client -c ${hcd}/hc.yaml" >/dev/null 2>&1 || true

  {
    echo "server: 127.0.0.1:${HY2_PORT}"
    echo "auth: ${HY2_PASS}"
    echo "tls:"
    echo "  sni: ${DEST}"
    if [ -n "$pin" ]; then
      # 官方示例: insecure 跳过 CA 校验, pinSHA256 做真正的身份校验
      echo "  insecure: true"
      echo "  pinSHA256: ${pin}"
    else
      echo "  insecure: true"
    fi
    if [ "$ENABLE_OBFS" = "1" ]; then
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: ${OBFS_PASS}"
    fi
    echo "socks5:"
    echo "  listen: 127.0.0.1:10898"
  } > "$hcd/hc.yaml"

  : > "$hcd/hc.log"
  chmod 600 "$hcd/hc.yaml" "$hcd/hc.log" 2>/dev/null
  "$HY2_BIN" client -c "$hcd/hc.yaml" >>"$hcd/hc.log" 2>&1 &
  pid=$!

  # 等 socks5 端口真正起来, 最多 10 秒(原来固定 sleep 4 经常不够)
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    if command -v ss >/dev/null 2>&1; then
      # pipefail + grep -q: 命中后 grep 立刻退出, 上游 ss 吃 SIGPIPE(141),
      # 整条管道被判失败 -> break 永远不执行, 白等满 20 轮(约 10 秒)。
      local _sl
      _sl=$(ss -ltn 2>/dev/null || true)
      case "$_sl" in *':10898 '*) break ;; esac
    fi
    sleep 0.5
  done

  code=$(curl -s --socks5-hostname 127.0.0.1:10898 -o /dev/null -w '%{http_code}' --max-time 15 https://www.gstatic.com/generate_204 2>/dev/null)
  case "$code" in
    000|"") code=$(curl -s --socks5-hostname 127.0.0.1:10898 -o /dev/null -w '%{http_code}' --max-time 20 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null) ;;
  esac

  kill "$pid" >/dev/null 2>&1; wait "$pid" 2>/dev/null

  case "$code" in
    2*|3*) rm -rf "$hcd"; return 0 ;;
  esac

  # 失败必须把客户端输出带出来, 否则永远不知道为什么不通
  if [ -s "$hcd/hc.log" ]; then
    echo -e "    ${D}--- hysteria client 输出 ---${N}" >&2
    tail -6 "$hcd/hc.log" | sed 's/^/    /' >&2
  fi
  rm -rf "$hcd"
  return 1
}

# ---------------- 端口跳跃 ----------------
# 从 iptables 里枚举并删掉所有"本脚本这类"端口跳跃规则。
# 不能用 state.env 当前存的 HY2_HOP 去 -D: 区间改过之后旧区间已经不在 state
# 里, 却还留在 iptables 里; 而新 unit 的 ExecStop 只会删新区间那一条。
# 只清本脚本建的 REDIRECT: 老版本没打标记, 兼容匹配"纯数字区间 -> 纯数字端口"
# 的历史规则; 绝不能匹配任意 UDP REDIRECT, 那会删掉别人服务(如透明代理)的 NAT 规则。
HOP_COMMENT="proxy-node-hop"
hop_cleanup_rules(){
  local line spec n=0
  local hop_comment="${HOP_COMMENT:-proxy-node-hop}"
  # 老格式(无注释)用锚定正则精确识别, 不用宽泛的 case 通配: `[0-9]*` 的尾部 *
  # 会吞掉后续任意参数, 把同机其它透明代理的 UDP REDIRECT 也删掉。老版本 iptables
  # -S 会在 -p udp 后带 -m udp, 两种形状都要认; 行尾必须正好是数字端口, 且整行
  # 不含任何别人的 --comment。当前格式带本脚本注释, 由下面 case 第一臂匹配。
  local re_old='^-A PREROUTING -p udp (-m udp )?--dport [0-9]+:[0-9]+ -j REDIRECT --to-ports [0-9]+$'
  while IFS= read -r line; do
    case "$line" in
      *"--comment ${hop_comment}"*) ;;
      *)
        [[ "$line" =~ $re_old ]] || continue
        [[ "$line" == *--comment* ]] && continue
        ;;
    esac
    spec="${line#-A }"
    # $spec 是 `iptables -S` 的输出, 本来就是按空格分好的参数串, 这里必须让
    # word splitting 生效 —— 加引号会把整串当成一个参数传给 iptables。
    # 指令后面不能跟文字, 否则 shellcheck 报 SC1125 并整条忽略(等于没屏蔽)。
    # shellcheck disable=SC2086
    iptables -t nat -D $spec >/dev/null 2>&1 && n=$((n + 1))
  done < <(iptables -t nat -S 2>/dev/null | grep '^-A PREROUTING ' || true)
  [ "$n" -gt 0 ] && ok "已清理 ${n} 条旧的端口跳跃 REDIRECT 规则"
  return 0
}

setup_hy2_hop(){
  if [ -z "${HY2_HOP:-}" ]; then
    # 关掉端口跳跃: 之前开过就必须真的停。hy2-hop 是 oneshot + RemainAfterExit,
    # ExecStop 才会删那条 iptables REDIRECT; 只 disable 不 stop 的话规则一直留着,
    # 那一段 UDP 端口对公网始终是开的。
    if [ -f /etc/systemd/system/hy2-hop.service ]; then
      if systemctl is-active --quiet hy2-hop 2>/dev/null \
         || systemctl is-enabled --quiet hy2-hop 2>/dev/null; then
        systemctl disable --now hy2-hop >/dev/null 2>&1 \
          && warn "已停用端口跳跃 (HY2_HOP 为空, NAT 规则已清理)"
      fi
    fi
    # 旧 unit 的 ExecStop 只认它自己那一段区间, 历史区间还得枚举清一遍
    hop_cleanup_rules
    return 0
  fi
  local start end
  start="${HY2_HOP%%-*}"; end="${HY2_HOP##*-}"
  case "${start}${end}" in
    ''|*[!0-9]*)
      warn "HY2_HOP 格式错误(应为 20000-30000, 且起点<=终点), 跳过端口跳跃"
      hop_cleanup_rules; return 0 ;;
  esac
  start=$((10#$start)); end=$((10#$end))
  if ! valid_port "$start" || ! valid_port "$end" || [ "$start" -gt "$end" ]; then
    warn "HY2_HOP 格式错误(应为 20000-30000, 且起点<=终点), 跳过端口跳跃"
    hop_cleanup_rules; return 0
  fi
  # HY2_PORT 会原样进下面 unit 的 /bin/sh -c '...'。它正常来自已校验的 state,
  # 但手改 state.env 塞进 `; rm -rf /` 就会在 root 下执行, 这里再卡一道。
  if ! valid_port "${HY2_PORT:-}"; then
    warn "HY2_PORT 非法, 跳过端口跳跃"; hop_cleanup_rules; return 0
  fi
  # 关键顺序: 先停旧 unit、再枚举清旧规则, 最后才写新 unit。
  # 反过来(先写 unit 再 restart)时 systemctl 用的是**新** unit 的 ExecStop,
  # 旧区间那条 REDIRECT 永远删不掉 —— 那一段 UDP 端口会一直对公网开着。
  if [ -f /etc/systemd/system/hy2-hop.service ]; then
    systemctl stop hy2-hop >/dev/null 2>&1 || true
  fi
  hop_cleanup_rules
  # 上面已停旧 unit、清掉旧 iptables 规则, 这里写失败(目录只读/磁盘满)若不 die,
  # 后面仍 enable/restart 一个空 unit, 最后还报"可能缺少 iptables nat 支持",
  # 排障方向完全错。与其它 unit 写入一样必须失败即停。
  if ! cat > /etc/systemd/system/hy2-hop.service <<EOF
[Unit]
Description=Hysteria2 UDP port hopping (${HY2_HOP} -> ${HY2_PORT})
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C PREROUTING -p udp --dport ${start}:${end} -m comment --comment ${HOP_COMMENT} -j REDIRECT --to-ports ${HY2_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport ${start}:${end} -m comment --comment ${HOP_COMMENT} -j REDIRECT --to-ports ${HY2_PORT}'
ExecStop=/bin/sh -c 'iptables -t nat -D PREROUTING -p udp --dport ${start}:${end} -m comment --comment ${HOP_COMMENT} -j REDIRECT --to-ports ${HY2_PORT} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
  then
    hop_cleanup_rules
    die "写入 hy2-hop.service 失败(目录只读/磁盘满?), 端口跳跃未启用"
  fi
  systemctl daemon-reload
  enable_unit hy2-hop
  systemctl restart hy2-hop >/dev/null 2>&1
  if systemctl is-active --quiet hy2-hop; then
    ok "端口跳跃已启用: UDP ${HY2_HOP} -> ${HY2_PORT}"
    warn "云安全组必须放行 UDP ${HY2_HOP}, 否则跳跃无效"
  else
    warn "端口跳跃启动失败(可能缺少 iptables nat 支持), 已跳过"
  fi
}

# ---------------- 系统优化 ----------------
# $1: all(默认) | bbr | swap | time | log
optimize_system(){
  local what="${1:-all}"

  case "$what" in
  all|bbr)
    info "内核参数与 BBR ..."
    cat > /etc/sysctl.d/99-proxy-optimize.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
# 缓冲区上限要盖过 hysteria 的 QUIC 窗口(配置里是 8MB/20MB),
# 否则内核会把 SO_RCVBUF 截断, UDP 大流量跑不满带宽
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
# 短连接复用 TIME_WAIT, 代理场景下能少占端口
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=10000 65000
net.ipv4.tcp_mtu_probing=1
# 不开 ip_forward: 本机只是代理终点, 端口跳跃用的是 nat/PREROUTING 的
# REDIRECT(投递本机), 不需要转发第三方流量; 打开反而让 VPS 具备路由能力。
# 空闲后不重置拥塞窗口, 长连接(视频/直播)不会每隔一阵子重新慢启动
net.ipv4.tcp_slow_start_after_idle=0
# 刻意不设 tcp_notsent_lowat: Xray 是 Go 程序, 用 epoll 判断可写,
# 设 16384 会让每个连接最多只有 16KB 未发数据, 高延迟链路上直接把
# Reality/TCP 吞吐压到 1Mbps 量级。保持内核默认(UINT_MAX)才能跑满带宽。
# 并发连接能力
net.core.somaxconn=8192
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_syncookies=1
fs.file-max=1048576
# 连接跟踪表上限(模块未加载时该行会被内核忽略)
net.netfilter.nf_conntrack_max=65536
# UDP 收发内存: hysteria2 / TUIC 全靠 UDP, 默认上限在小机器上会直接丢包,
# 表现为"带宽跑不满 + 偶发卡顿"。单位是页(4KB), 这里是 128MB/192MB/256MB 的上限。
net.ipv4.udp_mem=32768 49152 65536
# 网卡收包队列: 突发流量下默认 1000 太小, 会在这里丢包(ip -s link 的 dropped 会涨)
net.core.netdev_max_backlog=16384
# 主动关闭的连接早点回收, 代理场景下 TIME_WAIT 少堆一点
net.ipv4.tcp_fin_timeout=15
SYSCTL
    # 老机器运行时可能还留着 16384(甚至误设的 0), 而 sysctl -p 不会重置
    # 已从配置文件里删掉的键。必须显式恢复内核默认 UINT_MAX, 否则要重启才生效。
    # 注意不能设 0: 内核里 0 会让 tcp_notsent_lowat() 退化成阈值 0, POLLOUT 永远
    # 不触发, Go/epoll 程序(Xray)会直接停发数据 —— 比 16384 更致命。
    sysctl -w net.ipv4.tcp_notsent_lowat=4294967295 >/dev/null 2>&1 || true
    local _nsl; _nsl=$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)
    if [ "$_nsl" = "16384" ] || [ "$_nsl" = "0" ]; then
      warn "tcp_notsent_lowat 仍为 ${_nsl}, Reality/TCP 吞吐会被限制; 可重启或手动 sysctl -w net.ipv4.tcp_notsent_lowat=4294967295"
    fi

    # 不能把 sysctl -p 的输出和返回码一起丢掉: 容器/老内核上 rmem_max、
    # wmem_max、udp_mem、fq 经常写不进去, 之前全程静默, 装完还是慢却查不出原因。
    local sysout sysrc kv k expect got miss=""
    sysout=$(sysctl -p /etc/sysctl.d/99-proxy-optimize.conf 2>&1); sysrc=$?
    if [ "$sysrc" -ne 0 ]; then
      warn "sysctl -p 有参数未生效(容器/只读 /proc / 老内核常见):"
      printf '%s\n' "$sysout" | grep -iE 'error|cannot|not permitted|no such|read-only' \
        | head -8 | sed 's/^/    /' >&2 || true
    fi
    # 逐项回读: 写进配置文件不等于内核接受了。
    while IFS= read -r kv; do
      case "$kv" in ''|'#'*) continue ;; esac
      k="${kv%%=*}"; expect="${kv#*=}"
      [ -n "$k" ] || continue
      got=$(sysctl -n "$k" 2>/dev/null) || continue
      got=$(printf '%s' "$got" | tr '\t' ' ' | tr -s ' ')
      expect=$(printf '%s' "$expect" | tr '\t' ' ' | tr -s ' ')
      [ "$got" = "$expect" ] || miss="${miss} ${k}(=${got:-读不到})"
    done < /etc/sysctl.d/99-proxy-optimize.conf
    if [ -n "$miss" ]; then
      warn "以下内核参数未生效(可能被容器或内核版本限制, 高速率下会掉速):${miss}"
    else
      ok "内核参数已逐项回读核对"
    fi


    # 这里必须真的核对一遍: 内核 < 4.9 或模块没编进去时, 写 bbr 会静默失败,
    # 之前无论成没成都打印 "ok BBR: ...", 看起来调好了其实还是 cubic。
    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [ "$cc" = "bbr" ]; then
      ok "拥塞控制: bbr (队列: ${qd:-未知})"
    else
      warn "拥塞控制: ${cc:-未知} —— 当前内核不支持 BBR(需 4.9+), 高速率下会明显掉速"
      warn "查一下可用算法: sysctl net.ipv4.tcp_available_congestion_control"
    fi

    # conntrack 上限已写进 sysctl 持久化, 这里补一次运行时生效
    if [ -w /proc/sys/net/netfilter/nf_conntrack_max ]; then
      echo 65536 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
      ok "conntrack_max: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
    fi

    # 进程句柄数: 高并发下默认 1024 会成为瓶颈
    if [ -d /etc/security/limits.d ]; then
      if ! cat > /etc/security/limits.d/99-proxy-nofile.conf <<'LIMITS'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
LIMITS
      then
        warn "写入句柄数配置失败(磁盘满/只读?), 高并发下可能仍是 1024"
      else
        ok "句柄数上限: 65535"
      fi
    fi
    ;;&
  all|log)
    # journald 限容: 小硬盘机器最容易被日志写满
    mkdir -p /etc/systemd/journald.conf.d
    if ! cat > /etc/systemd/journald.conf.d/99-proxy-size.conf <<'JOURNAL'
[Journal]
SystemMaxUse=100M
SystemMaxFileSize=20M
JOURNAL
    then
      warn "写入 journald 限容配置失败(磁盘满/只读?), 小硬盘可能被日志写满"
    else
      systemctl restart systemd-journald >/dev/null 2>&1 && ok "journald 日志上限: 100M"
    fi
    ;;&
  all|swap)
    if [ "$(free -m | awk '/Swap:/{print $2}')" = "0" ] && [ ! -f /swapfile ]; then
      # 整条链必须一起判成功。容器/老内核/磁盘不足时 fallocate+mkswap+swapon
      # 常常失败, 旧版却无条件写 fstab 并打印 ok —— 残留无效条目会让开机
      # swapon -a 失败, 还谎报"已添加"。
      if { fallocate -l 1G /swapfile 2>/dev/null \
           || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null; } \
         && chmod 600 /swapfile \
         && mkswap /swapfile >/dev/null 2>&1 \
         && swapon /swapfile >/dev/null 2>&1; then
        grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "已添加 1GB swap"
      else
        rm -f /swapfile 2>/dev/null || true
        warn "swap 创建失败(容器/内核不支持或磁盘不足), 已跳过; 未改动 /etc/fstab"
      fi
    else
      ok "swap 已就绪 ($(free -m | awk '/Swap:/{print $2}')MB)"
    fi
    ;;&
  all|time)
    # REALITY 依赖时间偏差, 差几分钟就会握手失败
    # 同 pipefail 的坑: list-unit-files 输出很长, grep -q 命中即退会让 systemctl
    # 吃 SIGPIPE, 整条管道判失败 -> 明明装了 timesyncd 也走"没有"分支。
    # 先落到变量里再判断, 与管道退出码无关。
    local _ufs _has_timesyncd=0
    _ufs=$(systemctl list-unit-files 2>/dev/null) || _ufs=""
    case "$_ufs" in
      *systemd-timesyncd.service*) _has_timesyncd=1 ;;
      *) _has_timesyncd=0 ;;
    esac
    if [ "$_has_timesyncd" = "1" ]; then
      systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
      if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
        ok "时间同步: 已同步"
      else
        warn "时间同步: 服务已启用, 但尚未完成同步(等 1 分钟再查)"
      fi
    else
      warn "系统没有 systemd-timesyncd, 跳过时间同步"
    fi
    ;;&
  esac
}

cmd_optimize(){
  need_root
  local what="${1:-all}"
  case "$what" in
    all|bbr|swap|time|log) ;;
    *) die "未知优化项: ${what} (可选: all bbr swap time log)" ;;
  esac

  echo
  echo -e "${M}============================================================${N}"
  echo -e "${M}   VPS 优化${N}"
  echo -e "${M}============================================================${N}"
  echo
  case "$what" in
    all)  echo "  将执行: BBR + 内核参数 + 句柄数 + 日志限容 + swap + 时间同步" ;;
    bbr)  echo "  将执行: BBR + 内核参数 + 句柄数" ;;
    log)  echo "  将执行: journald 日志限容" ;;
    swap) echo "  将执行: 1GB swap (已有则跳过)" ;;
    time) echo "  将执行: 时间同步" ;;
  esac
  echo -e "  ${D}只改系统网络参数, 不动任何已有服务配置${N}"
  echo
  if [ "$ASSUME_YES" != "1" ]; then
    ask_yes "开始优化?" || { info "已取消"; return 0; }
    echo
  fi

  optimize_system "$what"
  echo
  ok "优化完成"
  echo -e "  ${D}当前拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${N}"
  echo -e "  ${D}当前 swap: $(free -m | awk '/Swap:/{print $2}')MB${N}"
  if [ "$what" = "all" ] || [ "$what" = "bbr" ]; then
    echo -e "  ${D}已运行的 UDP 服务是在旧 socket 缓冲区下创建的; 要吃满新参数请执行: proxy restart${N}"
  fi
  if [ "$what" = "all" ] || [ "$what" = "time" ]; then
    echo -e "  ${D}时区未改动, 当前: $(cur_timezone)  (要按机器所在地区设置用 proxy timezone)${N}"
  fi
  echo
}

# ---------------- 时区 ----------------
# 注意: NTP 同步(把 UTC 校准) 和 时区(本地怎么显示) 是两件事。
# TLS / REALITY 只认 UTC 时间戳, 时区设成什么都能正常握手。
# 但时区是平台风控的软信号: IP 在东京、系统时区是上海, 等于自己承认人不在这个区。
# 所以原则是"这台机器在哪就设哪", 不是"一律设美国"。
cur_timezone(){
  timedatectl show -p Timezone --value 2>/dev/null \
    || cat /etc/timezone 2>/dev/null \
    || echo "unknown"
}

# 探测出口 IP 所在时区; 失败返回空(不阻塞, 菜单里可手动选)
# 注意: 这一步会把本机 IP 交给第三方, 只在你主动选"自动匹配"时才会用到
# $1 可选: 指定要查的 IP。审计里要查的是"平台实际看到的那个 IP",
# 配了上游出口时它和本机 IP 不是同一个, 不传就会查错对象。
# 三个来源依次试: ip-api 最快但会限速; ipinfo 稳; ipwho.is 兜底。
# 任何一家能给出合法时区就停, 不要为了"多源校验"把三次请求都打出去。
detect_exit_tz(){
  local tz="" ip="${1:-}" cand src
  command -v curl >/dev/null 2>&1 || { printf ''; return 0; }

  for src in ipapi ipinfo ipwho; do
    case "$src" in
      ipapi)
        cand=$(curl -s --max-time 4 "http://ip-api.com/line/${ip}?fields=timezone" 2>/dev/null \
               | head -1 | tr -d '\r') ;;
      ipinfo)
        cand=$(curl -s --max-time 4 "https://ipinfo.io/${ip}/timezone" 2>/dev/null \
               | tr -d '\r\n') ;;
      ipwho)
        # JSON 里的斜杠可能被转义成 \/ , 先去掉反斜杠再取 timezone.id
        cand=$(curl -s --max-time 5 "https://ipwho.is/${ip}" 2>/dev/null \
               | tr -d '\\' \
               | grep -o '"timezone":{[^}]*}' | head -1 \
               | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4) ;;
    esac
    # 必须严格是 Area/City 这种形式。ip-api 是明文 HTTP, 被 MITM 后返回
    # "../../etc/shadow" 之类会过 zoneinfo 的 -f 检查(相对路径逐级回退),
    # 再被 ln -sf 写进 /etc/localtime —— 等于拿系统文件当符号链接目标。
    case "$cand" in
      */*) case "$cand" in
             # *.* 已经涵盖 *..* (含两个点必然含一个点), 不必再写一条永远
             # 匹配不到的模式。
             *.*|*//*|/*|*' '*|*[!A-Za-z0-9_+-/]*) ;;
             *) tz="$cand"; break ;;
           esac ;;
    esac
  done

  # 白名单正则再兜一层(只允许 Area/City, 无点无空格无绝对路径), 然后确认本机存在。
  if [ -n "$tz" ] && [[ "$tz" =~ ^[A-Za-z_]+/[A-Za-z0-9_+-]+$ ]] \
     && [ -f "/usr/share/zoneinfo/${tz}" ]; then
    printf '%s' "$tz"
  fi
  return 0
}

# 国家代码 -> 中文名, 只列常见的。查不到返回空, 不硬造名字。
cc_note(){
  case "$1" in
    US) printf ' (美国)' ;;      HK) printf ' (中国香港)' ;;  MO) printf ' (中国澳门)' ;;
    TW) printf ' (中国台湾)' ;;  JP) printf ' (日本)' ;;      KR) printf ' (韩国)' ;;
    SG) printf ' (新加坡)' ;;    MY) printf ' (马来西亚)' ;;  TH) printf ' (泰国)' ;;
    ID) printf ' (印尼)' ;;      VN) printf ' (越南)' ;;      PH) printf ' (菲律宾)' ;;
    IN) printf ' (印度)' ;;      AE) printf ' (阿联酋)' ;;    TR) printf ' (土耳其)' ;;
    DE) printf ' (德国)' ;;      GB|UK) printf ' (英国)' ;;   NL) printf ' (荷兰)' ;;
    FR) printf ' (法国)' ;;      CH) printf ' (瑞士)' ;;      AT) printf ' (奥地利)' ;;
    SE) printf ' (瑞典)' ;;      NO) printf ' (挪威)' ;;      DK) printf ' (丹麦)' ;;
    FI) printf ' (芬兰)' ;;      PL) printf ' (波兰)' ;;      CZ) printf ' (捷克)' ;;
    IT) printf ' (意大利)' ;;    ES) printf ' (西班牙)' ;;    IE) printf ' (爱尔兰)' ;;
    RU) printf ' (俄罗斯)' ;;    CA) printf ' (加拿大)' ;;    AU) printf ' (澳洲)' ;;
    NZ) printf ' (新西兰)' ;;    BR) printf ' (巴西)' ;;      MX) printf ' (墨西哥)' ;;
    CN) printf ' (中国大陆)' ;;
  esac
  return 0
}

# 出口国家 -> 该国的 Google 本地域名。表里没有的国家返回 google.com:
# Google 只在部分国家换域名, 其余国家直接用 .com。
google_cc_tld(){
  case "$1" in
    HK|MO) echo google.com.hk ;;
    JP) echo google.co.jp ;;      KR) echo google.co.kr ;;
    TW) echo google.com.tw ;;     SG) echo google.com.sg ;;
    GB|UK) echo google.co.uk ;;   IE) echo google.ie ;;
    DE) echo google.de ;;         FR) echo google.fr ;;
    NL) echo google.nl ;;         IT) echo google.it ;;
    ES) echo google.es ;;         CH) echo google.ch ;;
    AT) echo google.at ;;         BE) echo google.be ;;
    SE) echo google.se ;;         NO) echo google.no ;;
    DK) echo google.dk ;;         FI) echo google.fi ;;
    PL) echo google.pl ;;         CZ) echo google.cz ;;
    RU) echo google.ru ;;         TR) echo google.com.tr ;;
    IN) echo google.co.in ;;      AU) echo google.com.au ;;
    NZ) echo google.co.nz ;;      CA) echo google.ca ;;
    BR) echo google.com.br ;;     MX) echo google.com.mx ;;
    AR) echo google.com.ar ;;     CL) echo google.cl ;;
    TH) echo google.co.th ;;      MY) echo google.com.my ;;
    ID) echo google.co.id ;;      VN) echo google.com.vn ;;
    PH) echo google.com.ph ;;     IL) echo google.co.il ;;
    AE) echo google.ae ;;         SA) echo google.com.sa ;;
    ZA) echo google.co.za ;;
    *) echo google.com ;;
  esac
}

# IP 反查只能查到"这段 IP 登记在谁名下", 查不到"你把钱付给了谁"。
# RackNerd / CloudCone / AlphaVPS 这类转售商自己没有 ASN, 机器和 IP 都租自
# ColoCrossing(2023 年被 HostPapa 收购, AS36352 的登记名已改成 HostPapa)、
# Psychz、QuadraNet 等批发商, 所以反查必然返回批发商的名字。
# 命中这张表时说明"这个结果大概不是你买的商家", 装完提示用户自己改。
vendor_is_upstream(){
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    hostpapa|colocrossing|psychz|quadranet|internap|cogent|hurricane|level3|lumen|zayo|equinix|voxility|datacamp|servercentral|telia|gtt|ntt|tata) return 0 ;;
  esac
  return 1
}

# 从出口 IP 反查 VPS 厂商, 用作节点备注名
# 目标: 客户端列表里显示 "RackNerd-VLESS" 而不是 "Node-VLESS", 一眼看出是哪台机器
# 只取一个短词: 去 AS 号 / 去逗号分支 / 跳过法律后缀与冠词 / 去 .com 尾巴
detect_vendor(){
  local raw="" name="" out="" tok second="" resp="" isp="" asn=""

  command -v curl >/dev/null 2>&1 || { printf ''; return 0; }

  # 一次请求同时拿 isp 与 as: 免费接口连发两次会被限速
  resp=$(curl -s --max-time 5 "http://ip-api.com/line/?fields=isp,as" 2>/dev/null | tr -d '\r')
  isp=$(printf '%s\n' "$resp" | sed -n 1p)
  asn=$(printf '%s\n' "$resp" | sed -n 2p)

  raw="$isp"
  case "$raw" in ""|*"not assigned"*|*"Reserved"*) raw="$asn" ;; esac
  if [ -z "$raw" ]; then
    raw=$(curl -s --max-time 5 "https://ipinfo.io/org" 2>/dev/null | tr -d '\r\n')
  fi
  [ -n "$raw" ] || { printf ''; return 0; }

  # "AS36352 ColoCrossing" -> "ColoCrossing"; 只有 AS 号没有名字则放弃
  case "$raw" in
    AS[0-9]*)
      name="${raw#AS}"
      case "$name" in
        *" "*) name="${name#* }" ;;
        *)     name="" ;;
      esac
      ;;
    *) name="$raw" ;;
  esac
  [ -n "$name" ] || { printf ''; return 0; }

  # "Amazon.com, Inc." -> "Amazon.com"
  name="${name%%,*}"

  # 取第一个有意义的词: 跳过 LLC / Inc / GmbH / The 之类
  for tok in $name; do
    case "$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]' | tr -d '.,')" in
      the|a|an|llc|ltd|inc|incorporated|corp|corporation|co|company|limited|gmbh|bv|nv|sa|sas|sarl|pte|pty|plc|ag|oy|ab|as|kft|sp|zoo) continue ;;
    esac
    out="$tok"
    break
  done
  [ -n "$out" ] || out="${name%% *}"

  # 国名前缀: "China Mobile" 只取第一个词会变成没意义的 "China", 拼上第二个词
  case "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" in
    china|hong|korea|japan|singapore|india|vietnam|thai|taiwan)
      for tok in $name; do
        if [ "$tok" != "$out" ]; then second="$tok"; break; fi
      done
      [ -n "$second" ] && out="${out}${second}"
      ;;
  esac

  out="${out%.com}"; out="${out%.net}"; out="${out%.org}"
  out=$(printf '%s' "$out" | sed 's/[^A-Za-z0-9._-]//g')

  # 拿不到有效组织名时不要造出 "Reserved" / "Unknown" 这种备注
  case "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" in
    ""|reserved|unknown|private|localhost|none|na) printf ''; return 0 ;;
  esac

  # 少量映射: ASN 组织名和用户认知差得比较远的几家
  case "$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')" in
    choopa|constant|vultr*)      out="Vultr" ;;
    amazon|aws*)                 out="AWS" ;;
    tencent*)                    out="Tencent" ;;
    alibaba|aliyun*)             out="Aliyun" ;;
    chinanet*|chinatelecom*)     out="ChinaTelecom" ;;
    chinaunicom*|cucc*)          out="ChinaUnicom" ;;
    chinamobile*|cmcc*)          out="ChinaMobile" ;;
    oracle*)                     out="Oracle" ;;
    google*)                     out="Google" ;;
    microsoft*)                  out="Azure" ;;
    linode*|akamai*)             out="Linode" ;;
  esac

  printf '%s' "$out"
}

set_timezone(){
  local tz="$1" after
  if [ -z "$tz" ]; then return 1; fi
  # 必须先卡字符集: 只做 -f 检查的话, "Asia/../../etc/hostname" 会被文件系统
  # 解析到任意真实文件, 回退分支的 ln -sf 就把 /etc/localtime 指过去了。
  # detect_exit_tz 的输出本来就是严格白名单, 手动输入走同一道闸。
  # 斜杠后的 + 要允许(Etc/GMT+5), 但整段没有斜杠的 CET / EST / MST 也是
  # zoneinfo 里的合法时区 —— 上一版正则要求至少一个 /, 把它们全拒了。
  # 后面的 -f 检查会挡掉不存在的名字, 这里只管字符合法性。
  if [[ ! "$tz" =~ ^(UTC|[A-Za-z_]+(/[A-Za-z0-9_+-]+)*)$ ]]; then
    warn "非法时区名: ${tz} (格式: Asia/Tokyo、Etc/GMT+5、CET 或 UTC)"
    return 1
  fi
  if [ ! -f "/usr/share/zoneinfo/${tz}" ]; then
    warn "未知时区: ${tz}"
    echo -e "  ${D}查可用时区: timedatectl list-timezones | grep -i tokyo${N}"
    echo -e "  ${D}格式是 大洲/城市, 例如 Asia/Tokyo、Europe/Berlin${N}"
    return 1
  fi
  if ! timedatectl set-timezone "$tz" >/dev/null 2>&1; then
    # 容器/精简系统里 timedatectl 可能不可用, 直接改链接
    ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime 2>/dev/null \
      && echo "$tz" > /etc/timezone 2>/dev/null \
      || { warn "设置时区失败, 请手动执行: timedatectl set-timezone ${tz}"; return 1; }
  fi
  after=$(cur_timezone)
  if [ "$after" = "$tz" ]; then
    ok "时区已设为: ${tz}"
  else
    warn "已写入, 但当前读到的仍是: ${after} (可能需要在 SSH 里重新登录)"
  fi
  echo -e "  当前时间: ${Y}$(date '+%Y-%m-%d %H:%M:%S %Z (%z)')${N}"
}

# 时区分组候选。只列常见地区 —— 不在表里的用"手动输入"直接写时区名,
# set_timezone 会拿 /usr/share/zoneinfo 校验, 输错不会写坏系统。
# 每行格式: 时区|中文说明
tz_group(){
  case "$1" in
    asia) cat <<'TZL'
Asia/Hong_Kong|中国香港
Asia/Macau|中国澳门
Asia/Taipei|中国台湾
Asia/Tokyo|日本
Asia/Seoul|韩国
Asia/Singapore|新加坡
Asia/Kuala_Lumpur|马来西亚
Asia/Bangkok|泰国
Asia/Ho_Chi_Minh|越南
Asia/Jakarta|印尼
Asia/Manila|菲律宾
Asia/Kolkata|印度
Asia/Dubai|阿联酋 / 中东
Australia/Sydney|澳洲
TZL
      ;;
    europe) cat <<'TZL'
Europe/London|英国
Europe/Dublin|爱尔兰
Europe/Berlin|德国
Europe/Amsterdam|荷兰
Europe/Paris|法国
Europe/Zurich|瑞士
Europe/Vienna|奥地利
Europe/Stockholm|瑞典
Europe/Oslo|挪威
Europe/Helsinki|芬兰
Europe/Warsaw|波兰
Europe/Prague|捷克
Europe/Madrid|西班牙
Europe/Rome|意大利
Europe/Moscow|俄罗斯
TZL
      ;;
    america) cat <<'TZL'
America/Los_Angeles|美西 洛杉矶 / 圣何塞 / 西雅图
America/Denver|美西 山地 (丹佛 / 盐湖城)
America/Chicago|美中 达拉斯 / 芝加哥
America/New_York|美东 纽约 / 阿什本
America/Toronto|加拿大 东部
America/Vancouver|加拿大 西部
America/Sao_Paulo|巴西
TZL
      ;;
  esac
}

# 二级菜单: 选组里的某一项
tz_pick(){
  # 变量名带 tz_ 前缀, 别叫 grp: pick_dest 里的 grp 是**数组**, 这里的是字符串。
  # 两处都 local 所以不会真的串, 但同名不同类型正是"复制代码就变真 bug"的形态,
  # 静态检查也会一直报 SC2178/SC2128 —— 那是它没法做作用域推断, 不是误报本身
  # 有问题。改名把这个隐患直接消掉。
  local tz_grp="$1" title="$2" i sel line
  local -a items=()
  while IFS= read -r line; do [ -n "$line" ] && items+=("$line"); done < <(tz_group "$tz_grp")
  [ ${#items[@]} -gt 0 ] || return 1
  while true; do
    echo
    echo -e "  ${M}${title}${N}"
    i=0
    for line in "${items[@]}"; do
      i=$((i + 1))
      printf '  %2d) %-22s %s\n' "$i" "${line%%|*}" "${line#*|}"
    done
    echo "   0) 返回上一级"
    read_tty "  选择 [回车=0]: " sel "0" || return 1
    case "$sel" in 0|"") return 1 ;; esac
    case "$sel" in *[!0-9]*) warn "无效选项: ${sel}"; continue ;; esac
    if [ "$sel" -ge 1 ] && [ "$sel" -le "${#items[@]}" ]; then
      line="${items[$((sel - 1))]}"
      set_timezone "${line%%|*}"
      return 0
    fi
    warn "无效选项: ${sel}"
  done
}

cmd_timezone(){
  need_root
  local tz="${1:-}" cur exit_tz sel

  # 直接指定: proxy timezone Europe/Berlin
  if [ -n "$tz" ] && [ "$tz" != "auto" ]; then
    set_timezone "$tz"
    return $?
  fi

  # 按出口 IP 自动: proxy timezone auto
  if [ "$tz" = "auto" ]; then
    exit_tz=$(detect_exit_tz)
    [ -n "$exit_tz" ] || die "探测失败, 请手动指定: proxy timezone Asia/Tokyo"
    set_timezone "$exit_tz"
    return $?
  fi

  while true; do
    cur=$(cur_timezone)
    exit_tz=$(detect_exit_tz)
    echo
    echo -e "${M}============================================================${N}"
    echo -e "${M}   时区设置${N}"
    echo -e "${M}============================================================${N}"
    echo
    echo -e "  当前时区: ${Y}${cur}${N}"
    echo -e "  本地时间: $(date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
    echo -e "  UTC 时间: $(date -u '+%Y-%m-%d %H:%M:%S')"
    if [ -n "$exit_tz" ]; then
      echo -e "  出口 IP 所在时区: ${G}${exit_tz}${N}"
      [ "$exit_tz" = "$cur" ] && echo -e "  ${D}已一致, 一般不用改${N}"
    fi
    echo
    echo -e "  ${D}原则: 这台机器在哪个区就设哪个区。时区只影响日志和 date 显示,${N}"
    echo -e "  ${D}不影响 TLS/REALITY 握手, 但和 IP 对不上是平台风控的软信号。${N}"
    echo
    if [ -n "$exit_tz" ] && [ "$exit_tz" != "$cur" ]; then
      echo -e "   1) ${G}按出口 IP 自动匹配 → ${exit_tz}${N}   (推荐)"
    else
      echo -e "   1) 按出口 IP 自动匹配          ${D}(当前已一致)${N}"
    fi
    echo "   2) 亚洲 / 大洋洲"
    echo "   3) 欧洲"
    echo "   4) 美洲"
    echo "   5) UTC                         标准时间, 不随夏令时变化"
    echo "   6) 手动输入时区名              ${D}例如 Asia/Tokyo、Europe/Berlin${N}"
    echo "   0) 返回"
    echo
    read_tty "  ${B}请选择${N} [回车=0 返回]: " sel "0" || return 0
    case "$sel" in
      0|"") return 0 ;;
      1)
        if [ -n "$exit_tz" ]; then set_timezone "$exit_tz"
        else warn "没探测到出口时区, 请手动选"; fi ;;
      2) tz_pick asia "亚洲 / 大洋洲" ;;
      3) tz_pick europe "欧洲" ;;
      4) tz_pick america "美洲" ;;
      5) set_timezone "UTC" ;;
      6)
        echo
        echo -e "  ${D}可用时区列表: timedatectl list-timezones | grep -i 关键词${N}"
        read_tty "  输入时区名 [回车=取消]: " tz "" || return 0
        [ -n "$tz" ] && set_timezone "$tz" ;;
      *) warn "无效选项: ${sel}" ;;
    esac
    echo
  done
}

# ---------------- 健康检查 ----------------
install_healthcheck(){
  if ! cat > /usr/local/bin/proxy-healthcheck.sh <<'HEALTH'
#!/usr/bin/env bash
# 由 proxy-installer 安装
# 每 5 分钟查进程/端口; 每 6 次(约 30 分钟)做一次真实隧道探测, 连续失败才重启
set -u
# 探测用的临时配置里有设备 UUID, /run 是所有用户可读的, 必须收紧
umask 077
ST=/etc/proxy-node/state.env
FAIL=/run/proxy-healthcheck.fail
TICK=/run/proxy-healthcheck.tick
[ -f "$ST" ] || exit 0
# state.env 是数据文件, 绝不是 shell 代码。旧版这里用 . "$ST" 以 root
# source, 值里带一个单引号就能执行任意命令。改成只按白名单键逐行读成纯字符串。
while IFS= read -r _l || [ -n "$_l" ]; do
  case "$_l" in
    PROTOCOLS=*|VLESS_PORT=*|HY2_PORT=*|SS2022_PORT=*|ANYTLS_PORT=*|TUIC_PORT=*|DEST=*|PUB=*|SID=*|UUID=*|REALITY_FP=*) ;;
    *) continue ;;
  esac
  _k=${_l%%=*}; _v=${_l#*=}
  case "$_v" in \'*\') _v=${_v#\'}; _v=${_v%\'}; _v=${_v//\'\\\'\'/\'} ;; esac
  printf -v "$_k" '%s' "$_v"
done < "$ST"
# state.env 是数据文件, 指纹值必须白名单校验后才能拼进下面的 JSON, 否则
# 被手改过的 state.env 里带引号就能破坏探测配置。非法值回退 chrome。
case "${REALITY_FP:-}" in
  chrome|firefox|safari|ios|android|edge|360|qq|random|randomized|'') ;;
  *) REALITY_FP=chrome ;;
esac
VLESS_PORT=${VLESS_PORT:-443}; HY2_PORT=${HY2_PORT:-443}
SS2022_PORT=${SS2022_PORT:-8445}; ANYTLS_PORT=${ANYTLS_PORT:-8444}; TUIC_PORT=${TUIC_PORT:-8443}

PROTOCOLS=${PROTOCOLS:-reality,hy2}
on(){
  case ",${PROTOCOLS}," in
    *",$1,"*) return 0 ;;
    *)        return 1 ;;
  esac
}
sb_on(){ on ss2022 || on anytls || on tuic; }

restart_xray(){
  # 重启失败也必须如实记: 以前无条件写"已重启", 配置坏到起不来时日志看起来
  # 一直在自动恢复, 实际每 5 分钟白重启一次, 排障方向被彻底带偏。
  if systemctl restart xray >/dev/null 2>&1; then
    logger -t proxy-healthcheck "xray 异常($1), 已重启"
  else
    logger -t proxy-healthcheck "xray 异常($1), 重启失败(检查 journalctl -u xray)"
  fi
  # 不在这里清 FAIL: 进程/端口类重启也走这里, 清零会掩盖"隧道持续失败"的计数。
  # 隧道成功时由探测分支自己 echo 0, 语义更准确。
}
restart_svc(){
  if systemctl restart "$1" >/dev/null 2>&1; then
    logger -t proxy-healthcheck "$1 异常($2), 已重启"
  else
    logger -t proxy-healthcheck "$1 异常($2), 重启失败(检查 journalctl -u $1)"
  fi
}
listen_tcp(){ ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"; }
listen_udp(){ ss -uln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"; }

if on reality; then
  systemctl is-active --quiet xray || restart_xray "进程不在"
  listen_tcp "${VLESS_PORT}" || restart_xray "端口未监听"
fi
if on hy2; then
  systemctl is-active --quiet hysteria-server || restart_svc hysteria-server "进程不在"
  listen_udp "${HY2_PORT}" || restart_svc hysteria-server "UDP 端口未监听"
fi
if sb_on; then
  if ! systemctl is-active --quiet sing-box; then
    restart_svc sing-box "进程不在"
  else
    on ss2022 && { listen_tcp "${SS2022_PORT}" || restart_svc sing-box "SS2022 端口未监听"; }
    on anytls && { listen_tcp "${ANYTLS_PORT}" || restart_svc sing-box "AnyTLS 端口未监听"; }
    on tuic   && { listen_udp "${TUIC_PORT}"   || restart_svc sing-box "TUIC 端口未监听"; }
  fi
fi

n=$(cat "$TICK" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$(( n + 1 ))
echo "$n" > "$TICK" 2>/dev/null || true

if on reality && [ $(( n % 6 )) -eq 0 ]; then
  U=$(head -1 /etc/proxy-node/users.txt 2>/dev/null | cut -d'|' -f1)
  U=${U:-${UUID:-}}
  # U 直接拼进下面的探测 JSON: 手改过 users.txt 塞进引号/花括号就会写坏配置,
  # 探测必失败 -> 反复误重启。UUID 只允许十六进制与连字符, 不合格就跳过本轮。
  case "$U" in ''|*[!0-9A-Fa-f-]*) U="" ;; esac
  case "${DEST:-}" in *[!A-Za-z0-9.-]*) DEST="" ;; esac
  case "${PUB:-}" in *[!0-9A-Za-z_+/=-]*) PUB="" ;; esac
  case "${SID:-}" in *[!0-9A-Za-z]*) SID="" ;; esac
  # 端口也要卡: 它会裸拼进探测 JSON, 还会被 listen_tcp 当正则用。前导零
  # (0443) 是非法 JSON, 带 | 之类则让端口检查恒真。
  case "${VLESS_PORT:-}" in ''|*[!0-9]*) VLESS_PORT=443 ;; esac
  VLESS_PORT=$((10#${VLESS_PORT}))
  case "$VLESS_PORT" in 0|*[!0-9]*) VLESS_PORT=443 ;; esac
  if [ -n "$U" ] && [ -n "${DEST:-}" ]; then
    cat > /run/_hc.json <<JSON
{ "log": { "loglevel": "error" },
  "inbounds": [ { "port": 10896, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ { "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${VLESS_PORT},
      "users": [ { "id": "${U}", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "${DEST}", "fingerprint": "${REALITY_FP:-chrome}",
        "publicKey": "${PUB:-}", "shortId": "${SID:-}", "spiderX": "/" } } } ] }
JSON
    # 上一轮探针若被 systemd 超时杀掉, 临时 xray 会残留并一直占着 10896 ——
    # 本轮的端口等待会立刻通过(连到的是那个残留进程), 而下面 kill "$hp" 只杀
    # 新起的那个, 残留的永远留着。按配置路径精确清一次: 只匹配本探针自己的
    # /run/_hc.json, 不会碰到正式服务(/etc/xray/config.json)。
    pkill -f '^/usr/local/bin/xray -c /run/_hc.json' >/dev/null 2>&1 || true
    /usr/local/bin/xray -c /run/_hc.json >/dev/null 2>&1 &
    hp=$!
    # 等临时 xray 把 SOCKS 端口监听上。固定 sleep 3 在慢机器上不够, 而端口还没
    # 起来时 curl 立刻拿到 000 —— 连吃两次就判"隧道连续不可用"并重启一次用户
    # 连接。探测手段自己没准备好, 却去重启被探测的服务, 方向反了。
    _pw=0
    while [ "$_pw" -lt 30 ] && ! (exec 3<>/dev/tcp/127.0.0.1/10896) 2>/dev/null; do
      sleep 0.2; _pw=$((_pw + 1))
    done
    code=$(curl -s --socks5-hostname 127.0.0.1:10896 -o /dev/null -w '%{http_code}' --max-time 10 https://www.gstatic.com/generate_204 2>/dev/null)
    kill "$hp" >/dev/null 2>&1
    rm -f /run/_hc.json
    case "$code" in
      2*|3*) echo 0 > "$FAIL" 2>/dev/null || true ;;
      *)
        f=$(cat "$FAIL" 2>/dev/null || echo 0)
        case "$f" in ''|*[!0-9]*) f=0 ;; esac
        f=$(( f + 1 ))
        echo "$f" > "$FAIL" 2>/dev/null || true
        logger -t proxy-healthcheck "隧道探测失败(HTTP ${code:-000}), 连续 ${f} 次"
        if [ "$f" -ge 2 ]; then
          restart_xray "隧道连续不可用"
          # 重启后给一个新的观察窗口, 避免计数器一直累加导致每轮都重启。
          echo 0 > "$FAIL" 2>/dev/null || true
        fi
        ;;
    esac
  fi
fi
HEALTH
  then
    warn "写入健康检查脚本失败(磁盘满/只读?), 跳过健康检查安装"
    return 1
  fi
  chmod 755 /usr/local/bin/proxy-healthcheck.sh || return 1

  if ! cat > /etc/systemd/system/proxy-healthcheck.service <<'UNIT'
[Unit]
Description=Proxy health check (one shot)

[Service]
Type=oneshot
# 只需要读状态文件 + 调 systemctl + 跑一次探测, 其余一律关掉
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictNamespaces=true
SystemCallArchitectures=native
UMask=0077
ExecStart=/usr/local/bin/proxy-healthcheck.sh
UNIT
  then
    warn "写入健康检查单元失败(磁盘满/只读?), 跳过健康检查安装"
    return 1
  fi

  if ! cat > /etc/systemd/system/proxy-healthcheck.timer <<'UNIT'
[Unit]
Description=Run proxy health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT
  then
    warn "写入健康检查定时器失败(磁盘满/只读?), 跳过健康检查安装"
    return 1
  fi

  systemctl daemon-reload
  enable_unit proxy-healthcheck.timer
  systemctl start proxy-healthcheck.timer >/dev/null 2>&1 || warn "healthcheck 定时器未能启动"
  if systemctl is-active --quiet proxy-healthcheck.timer; then
    ok "健康检查已启用(每 5 分钟, 异常自动重启)"
  else
    warn "健康检查定时器启动失败, 已跳过"
  fi
}

# ufw 是否真的在管规则。
# 不能写成 `ufw status | grep -q "Status: active"`: 脚本开了 pipefail, grep -q
# 命中首行就退出, 还在写的 ufw 会吃到 SIGPIPE(141), 整条管道判为失败 —— 于是
# "防火墙开着"被当成"没开", 端口规则一条都不加, 装完直接连不上。
ufw_active(){
  command -v ufw >/dev/null 2>&1 || return 1
  local out
  out=$(ufw status 2>/dev/null) || out=""
  case "$out" in *"Status: active"*) return 0 ;; esac
  return 1
}

setup_firewall(){
  local ports="" p old="" failed="" removed=""
  proto_on reality && ports="${ports} ${VLESS_PORT}/tcp"
  proto_on hy2     && ports="${ports} ${HY2_PORT}/udp"
  proto_on ss2022  && ports="${ports} ${SS2022_PORT}/tcp ${SS2022_PORT}/udp"
  proto_on anytls  && ports="${ports} ${ANYTLS_PORT}/tcp"
  # TUIC v5 是 QUIC, 只跑 UDP。多放行一个 TCP 没有用处, 还会让
  # "8443/tcp 被无关进程占用"变成一次误判甚至误杀。
  proto_on tuic    && ports="${ports} ${TUIC_PORT}/udp"
  # 订阅 HTTP 对公网开放时, 它自己的 TCP 端口也要放行。以前只管代理协议端口,
  # SUB_HTTP=1 + SUB_BIND=0.0.0.0 时订阅服务一直被本机防火墙拦着。
  if [ "${SUB_HTTP:-0}" = "1" ] && [ "${SUB_BIND:-127.0.0.1}" != "127.0.0.1" ] \
     && [ -n "${SUB_PORT:-}" ] && valid_port "$SUB_PORT"; then
    ports="${ports} ${SUB_PORT}/tcp"
  fi
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  [ -f "$FW_RULES" ] && old=$(cat "$FW_RULES" 2>/dev/null)

  if ufw_active; then
    # 先撤上一轮放过、这次不再需要的端口: 只增不减会让旧端口永远开着
    for p in $old; do
      case " $ports " in *" $p "*) continue ;; esac
      ufw delete allow "$p" >/dev/null 2>&1 && removed="${removed} ${p}"
    done
    for p in $ports; do ufw allow "$p" >/dev/null 2>&1 || failed="${failed} ${p}"; done
    [ -n "$removed" ] && ok "ufw 已撤回旧规则:${removed}"
    if [ -n "$failed" ]; then warn "ufw 放行失败:${failed}"; else ok "ufw 已放行:${ports}"; fi
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in $old; do
      case " $ports " in *" $p "*) continue ;; esac
      firewall-cmd --permanent --remove-port="$p" >/dev/null 2>&1 && removed="${removed} ${p}"
    done
    for p in $ports; do firewall-cmd --permanent --add-port="$p" >/dev/null 2>&1 || failed="${failed} ${p}"; done
    # reload 失败时规则只在 permanent 里、运行时没生效: 端口仍被拦, 但 failed 为空
    # 会让下面的 ok 和函数返回值都报"已放行", 安装报成功却从外部连不上。
    firewall-cmd --reload >/dev/null 2>&1 || failed="${failed} (reload)"
    [ -n "$removed" ] && ok "firewalld 已撤回旧规则:${removed}"
    if [ -n "$failed" ]; then warn "firewalld 放行失败:${failed}"; else ok "firewalld 已放行:${ports}"; fi
  else
    # 没装 ufw/firewalld 不等于没防火墙: 不少云镜像直接写原生 iptables。
    # 之前这里无条件打印"本机防火墙未启用", INPUT 默认 DROP 时会误导人。
    if command -v iptables >/dev/null 2>&1; then
      local pol
      pol=$(iptables -S INPUT 2>/dev/null | sed -n 's/^-P INPUT //p' | head -1)
      if [ "$pol" = "DROP" ] || [ "$pol" = "REJECT" ]; then
        warn "检测到原生 iptables INPUT 默认策略为 ${pol}, 本脚本不托管它 —— 请手动放行:${ports}"
        warn "  例: iptables -I INPUT -p udp --dport ${HY2_PORT:-443} -j ACCEPT"
      else
        ok "本机未启用托管防火墙 (iptables INPUT=${pol:-未知}), 请确认云安全组已放行:${ports}"
      fi
    else
      ok "本机防火墙未启用, 请确认云安全组已放行:${ports}"
    fi
  fi
  # 记下这一轮放行了什么, 供下次换端口 / proxy clean 撤回。
  # 记录写失败 -> 下次换端口/clean 时 firewall_undo 读不到旧规则, 旧端口永久对公网开放。
  if ! printf '%s\n' $ports > "$FW_RULES" 2>/dev/null; then
    err "无法记录防火墙规则到 ${FW_RULES}, 后续可能无法自动撤回旧端口"
    failed="${failed} (记录失败)"
  else
    chmod 600 "$FW_RULES" 2>/dev/null || failed="${failed} (记录权限)"
  fi
  # 放行失败必须传出去: 以前只 warn 再 return 0, cmd_install 一路绿灯打
  # "部署完成", 用户看到的是装好了却从外部连不上。
  [ -z "${failed:-}" ] || return 1
  return 0
}

# proxy clean / 换端口时撤掉本脚本加过的规则。只删记录文件里列出的那些,
# 绝不动用户自己配的 ufw/firewalld 规则。
firewall_undo(){
  local p f="$FW_RULES" n=0
  [ -f "$f" ] || return 0
  if ufw_active; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      ufw delete allow "$p" >/dev/null 2>&1 && n=$((n + 1))
    done < "$f"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      firewall-cmd --permanent --remove-port="$p" >/dev/null 2>&1 && n=$((n + 1))
    done < "$f"
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  [ "$n" -gt 0 ] && ok "已撤回本脚本放行的 ${n} 条防火墙规则"
  rm -f "$f"
  return 0
}

# 关掉"这次没选"的协议服务。
# 以前 PROTOCOLS 从 reality,hy2 改成 reality 再装一次, hy2 会继续跑: state.env 里
# 已经没有它, 订阅不再列它, proxy status 也不显示 —— 但进程和端口都还在。
# 用户以为关了其实没关, 这比"没装"更糟: 多一个没人看管的对公网端口。
stop_unused_services(){
  local unit stopped="" was
  if ! proto_on reality && [ -f /etc/systemd/system/xray.service ]; then
    was=""
    systemctl is-active --quiet xray 2>/dev/null && was=1
    systemctl is-enabled --quiet xray 2>/dev/null && was=1
    if [ -n "$was" ]; then
      systemctl disable --now xray >/dev/null 2>&1
      stopped="${stopped} xray"
    fi
  fi
  if ! proto_on hy2; then
    for unit in hysteria-server hysteria; do
      [ -f "/etc/systemd/system/${unit}.service" ] || continue
      was=""
      systemctl is-active --quiet "$unit" 2>/dev/null && was=1
      systemctl is-enabled --quiet "$unit" 2>/dev/null && was=1
      if [ -n "$was" ]; then
        systemctl disable --now "$unit" >/dev/null 2>&1
        stopped="${stopped} ${unit}"
      fi
      # 不能 break: 两个 unit 同时存在时, 只检查第一个会漏停旧版 hy2 进程。
    done
    # 端口跳跃是 hy2 的附属服务, 协议关了必须一起停: 否则 REDIRECT 还指着
    # 已经没人监听的 UDP 端口, 云安全组上那段区间一直"看起来需要开着"。
    # setup_hy2_hop 只在 proto_on hy2 分支里被调用, 清理逻辑永远走不到这里。
    if [ -f /etc/systemd/system/hy2-hop.service ]; then
      systemctl disable --now hy2-hop >/dev/null 2>&1
      stopped="${stopped} hy2-hop"
    fi
    hop_cleanup_rules
  fi
  if ! sb_enabled && [ -f /etc/systemd/system/sing-box.service ]; then
    was=""
    systemctl is-active --quiet sing-box 2>/dev/null && was=1
    systemctl is-enabled --quiet sing-box 2>/dev/null && was=1
    if [ -n "$was" ]; then
      systemctl disable --now sing-box >/dev/null 2>&1
      stopped="${stopped} sing-box"
    fi
  fi
  [ -n "$stopped" ] && warn "已停用本次未启用的协议服务:${stopped}  (配置与凭据保留, 重新启用用 proxy wizard)"
  return 0
}

# ---------------- 链接生成 ----------------
gen_links(){
  PRIMARY_UUID=$(primary_uuid)
  VLESS_LINK=""; HY2_LINK=""; HY2_LINK_COMPAT=""
  SS_LINK=""; ANYTLS_LINK=""; TUIC_LINK=""
  local _frag; _frag=$(uri_fragment "$NODE_NAME")

  if proto_on reality; then
    VLESS_LINK="vless://${PRIMARY_UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST}&fp=${REALITY_FP:-chrome}&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${_frag}-VLESS"
  fi

  if proto_on hy2; then
    local hb="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${DEST}"
    if [ -n "${HY2_HOP:-}" ]; then hb="${hb}&mport=${HY2_HOP}"; fi
    if [ "$ENABLE_OBFS" = "1" ]; then
      hb="${hb}&obfs=salamander&obfs-password=${OBFS_PASS}"
    fi
    if [ -n "${HY2_PIN:-}" ]; then
      # pin 是 64 位小写 hex, 放进 query 无需转义。
      # 同时带 insecure=1: hysteria2 用 insecure 跳过自签证书的 CA 校验,
      # 真正的身份校验由 pinSHA256 完成(与官方 cert 命令给出的示例配置一致)。
      HY2_LINK="${hb}&insecure=1&pinSHA256=${HY2_PIN}#${_frag}-HY2"
      # v2rayN 新版(官方 #7866/#10433 已支持, 界面还有"获取 pinSHA256"按钮)识别
      # pinSHA256, 所以主链接直接给它用。另留一条无 pin 的兼容链接, 给尚不识别的
      # 老版本兜底 —— 老版导入带 pin 的链接会忽略该参数, 仍能连, 只是没有证书固定。
      HY2_LINK_COMPAT="${hb}&insecure=1#${_frag}-HY2-oldv2rayN"
    else
      HY2_LINK="${hb}&insecure=1#${_frag}-HY2"
      HY2_LINK_COMPAT=""
    fi
  fi

  # 以下 AnyTLS / TUIC 两个协议用自签证书, URI 标准里没有证书指纹字段,
  # 只能 insecure; SS2022 没有 TLS, 根本不需要证书固定。三者的分享链接
  # 都别当成"已固定证书", 真固定只在 singbox.json(1.13+)里。
  if sb_enabled; then
    local pu ss_ui
    pu="$PRIMARY_UUID"

    if proto_on ss2022; then
      # SIP002: base64url(method:password), 去掉 padding
      # 密码是 "服务端密钥:设备密钥", 整段一起 base64, 客户端按第一个冒号切分
      ss_ui=$(printf '2022-blake3-aes-128-gcm:%s' "$(ss_pass_for "$pu")" \
        | openssl base64 -A | tr '+/' '-_' | tr -d '=') || die "SS 链接编码失败"
      [ -n "$ss_ui" ] || die "SS 链接编码结果为空"
      SS_LINK="ss://${ss_ui}@${SERVER_IP}:${SS2022_PORT}#${_frag}-SS2022"
    fi
    if proto_on anytls; then
      ANYTLS_LINK="anytls://$(derive_hex "$pu")@${SERVER_IP}:${ANYTLS_PORT}?sni=${DEST}&insecure=1#${_frag}-AnyTLS"
    fi
    if proto_on tuic; then
      TUIC_LINK="tuic://${pu}:$(derive_hex "$pu")@${SERVER_IP}:${TUIC_PORT}?sni=${DEST}&alpn=h3&congestion_control=bbr&allow_insecure=1#${_frag}-TUIC"
    fi
  fi
}

# ---------------- 订阅文件 ----------------
# ---------------------------------------------------------------------------
# sing-box 客户端配置
#
# sing-box 的 DNS 与路由格式在 1.12 / 1.13 / 1.14 连着改了三次, 一份配置喂
# 不了所有版本。实测(官方 1.11.0 / 1.12.0 / 1.13.0 / 1.14.4 四个二进制):
#
#   | 配置形态                              | 1.11 | 1.12 | 1.13 | 1.14 |
#   |---------------------------------------|------|------|------|------|
#   | 新 DNS(type+server)+hijack-dns       | 致命 | 通过 | 通过 | 通过 |
#   |   + default_domain_resolver           |      |      |      |      |
#   |   + certificate_public_key_sha256     |      | 致命 | 通过 | 通过 |
#   | 旧 DNS(address)+dns-out              | 致命 | 致命 | 致命 | 致命 |
#   |   (1.14 起彻底移除, 1.12 需开废弃开关) |      |      |      |      |
#
# 所以订阅里给两份:
#   singbox.json         新 DNS + 证书指纹(certificate_public_key_sha256) -> 1.13+
#   singbox-compat.json  新 DNS + insecure                                  -> 1.12 (1.13/1.14 也能用)
# 1.11 及更早不认新 DNS 格式, 改用 clash.yaml (mihomo 内核)。
# ---------------------------------------------------------------------------

# 单个协议的 TLS 段
# $1 = anytls|tuic|hy2   $2 = pinned|compat
sb_tls(){
  local kind="$1" mode="$2" pin="" alpn=""
  case "$kind" in
    # hy2 要跟 hysteria 服务端的 pinSHA256 保持一致: HY2_INSECURE=1 时 HY2_PIN 是空的,
    # 这时客户端配置也退回 insecure, 不能一个走指纹一个不走。
    hy2)    pin="${CERT_SPKI_B64:-}"; [ -n "${HY2_PIN:-}" ] || pin="" ;;
    anytls) pin="${SB_PIN:-}"; alpn='"alpn": ["h2", "http/1.1"], ' ;;
    tuic)   pin="${SB_PIN:-}"; alpn='"alpn": ["h3"], ' ;;
    *)      echo '"tls": { "enabled": true }'; return 0 ;;
  esac
  # pinned 模式且有指纹才用真固定; compat 模式给 1.12 用(它没有这个字段)
  if [ "$mode" = "pinned" ] && [ -n "$pin" ]; then
    echo "\"tls\": { \"enabled\": true, \"server_name\": \"${DEST}\", ${alpn}\"certificate_public_key_sha256\": [\"${pin}\"] }"
  else
    echo "\"tls\": { \"enabled\": true, \"server_name\": \"${DEST}\", ${alpn}\"insecure\": true }"
  fi
}

# 生成 sing-box 客户端配置文件
# $1 = pinned|compat   $2 = 输出路径
write_sb_client(){
  local mode="$1" out="$2"
  local first_tag="" ob=()
  # 单独被调用(proxy selftest)时没有 gen_sub_files 那层校验, 这里自己兜一次,
  # 否则 state.env 被手改坏会写出 "up_mbps": abc 这种非法 JSON。
  local _sb_up="${HY2_BW_UP:-}" _sb_down="${HY2_BW_DOWN:-}" _sb_bad=0 _sbv
  for _sbv in "$_sb_up" "$_sb_down"; do
    [ -n "$_sbv" ] || continue
    hy2_bw_ok "$_sbv" || { _sb_bad=1; break; }
  done
  if [ "$_sb_bad" = "1" ]; then
    warn "HY2_BW_UP/DOWN 非法, 本次 sing-box 订阅按默认 BBR 生成"
    _sb_up=""; _sb_down=""
  fi
  # PRIMARY_UUID 平时是 gen_links 里算好的。这里自己兜一次, 否则单独调用
  # (比如 proxy selftest 只生成一份客户端配置)会撞上 set -u 直接退出。
  local pu="${PRIMARY_UUID:-$(primary_uuid)}"

  local tls_hy2 tls_anytls tls_tuic
  tls_hy2="$(sb_tls hy2 "$mode")"
  tls_anytls="$(sb_tls anytls "$mode")"
  tls_tuic="$(sb_tls tuic "$mode")"

  if proto_on reality; then
    first_tag="vless-out"
    ob+=("$(cat <<JSON
    {
      "type": "vless", "tag": "vless-out",
      "server": "${SERVER_IP}", "server_port": ${VLESS_PORT},
      "uuid": "${pu}", "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true, "server_name": "${DEST}",
        "utls": { "enabled": true, "fingerprint": "${REALITY_FP:-chrome}" },
        "reality": { "enabled": true, "public_key": "${PUB}", "short_id": "${SID}" }
      }
    }
JSON
)")
  fi

  if proto_on hy2; then
    [ -n "$first_tag" ] || first_tag="hy2-out"
    # 混淆和端口跳跃以前只写进了分享链接和 clash.yaml, 漏了 sing-box —— 开了
    # ENABLE_OBFS=1 之后用 sing-box 客户端导入订阅会直接连不上(服务端要求混淆,
    # 客户端不带)。端口跳跃同理, 客户端不写 server_ports 就用不上。
    local sb_hy2_extra="" sb_hy2_bw=""
    # sing-box 用 up_mbps/down_mbps(整数)开启 Brutal, 语义与 mihomo 的 up/down 一致。
    [ -n "$_sb_up" ]   && sb_hy2_bw="${sb_hy2_bw}\"up_mbps\": ${_sb_up}, "
    [ -n "$_sb_down" ] && sb_hy2_bw="${sb_hy2_bw}\"down_mbps\": ${_sb_down}, "
    if [ "$ENABLE_OBFS" = "1" ] && [ -n "${OBFS_PASS:-}" ]; then
      sb_hy2_extra="\"obfs\": { \"type\": \"salamander\", \"password\": \"${OBFS_PASS}\" },"
    fi
    if [ -n "${HY2_HOP:-}" ]; then
      # 配置里是 20000-30000, sing-box 要 20000:30000
      sb_hy2_extra="${sb_hy2_extra}\"server_ports\": [ \"${HY2_HOP/-/:}\" ],"
    fi
    ob+=("$(cat <<JSON
    {
      "type": "hysteria2", "tag": "hy2-out",
      "server": "${SERVER_IP}", "server_port": ${HY2_PORT},
      "password": "${HY2_PASS}",
      ${sb_hy2_bw}
      ${sb_hy2_extra}
      ${tls_hy2}
    }
JSON
)")
  fi

  if proto_on ss2022; then
    [ -n "$first_tag" ] || first_tag="ss2022-out"
    ob+=("$(cat <<JSON
    {
      "type": "shadowsocks", "tag": "ss2022-out",
      "server": "${SERVER_IP}", "server_port": ${SS2022_PORT},
      "method": "2022-blake3-aes-128-gcm",
      "password": "$(ss_pass_for "$pu")"
    }
JSON
)")
  fi

  if proto_on anytls; then
    [ -n "$first_tag" ] || first_tag="anytls-out"
    ob+=("$(cat <<JSON
    {
      "type": "anytls", "tag": "anytls-out",
      "server": "${SERVER_IP}", "server_port": ${ANYTLS_PORT},
      "password": "$(derive_hex "$pu")",
      ${tls_anytls}
    }
JSON
)")
  fi

  if proto_on tuic; then
    [ -n "$first_tag" ] || first_tag="tuic-out"
    ob+=("$(cat <<JSON
    {
      "type": "tuic", "tag": "tuic-out",
      "server": "${SERVER_IP}", "server_port": ${TUIC_PORT},
      "uuid": "${pu}", "password": "$(derive_hex "$pu")",
      "congestion_control": "bbr",
      ${tls_tuic}
    }
JSON
)")
  fi

  [ ${#ob[@]} -gt 0 ] || die "没有任何可用协议, 检查 PROTOCOLS"

  # 默认出口必须在写 DNS server 之前定下来: dns.remote 的 detour 用的就是它。
  # 以前改 first_tag 放在 outbounds 那段之后, DEFAULT_NODE=hy2 时流量走 HY2、
  # DNS 却仍绕 Reality, Reality 一挂 DNS 全断。
  if [ "$(effective_default_node)" = "hy2" ]; then
    first_tag="hy2-out"
  fi
  # 新版服务端的 REALITY 与 sing-box 客户端不兼容(见 sb_reality_ok 上方说明):
  # 这种情况下 REALITY 节点照写(等上游修好后可直接用), 但默认出口必须切到 HY2,
  # 否则用户导入 singbox.json 就是"节点在、一字节都不通"。只开了 REALITY 时
  # 无从可切, 记下标记交给调用方告警。
  if proto_on reality && ! sb_reality_ok; then
    if proto_on hy2; then
      first_tag="hy2-out"
      SB_REALITY_BROKEN=1
    else
      # 没有 HY2 可切: 不能把 first_tag 指向一个不存在的 hy2-out。
      # 记下标记, 由 gen_sub_files 告警并改写指南, 避免用户导入即用不了还不知道。
      SB_REALITY_ONLY=1
    fi
  fi

  {
    echo "{"
    echo '  "log": { "level": "info" },'
    # DNS 必须自己接管。不配的话 sing-box 走系统 DNS, 在国内就是运营商 DNS:
    # 客户端在本地解析出 IP 再发给服务端, 服务端只能连那个 IP,
    # Google 反查到的就是你的本地解析结果, 直接判成中国区。
    # remote 走代理出去(境外解析), local 走直连(国内解析, 只用于 .lan/.local 这类)。
    # 两个 server 都写 IP: 用域名会跟 default_domain_resolver 形成循环解析。
    echo '  "dns": {'
    echo '    "servers": ['
    printf '      { "type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "%s" },\n' "$first_tag"
    # local 用 UDP 明文 DNS 直连国内, 只负责 .lan/.local/.arpa 这类本地域名。
    # detour 必须指向一个"非空"的 direct 出站: 空 direct 会被 sing-box 拒绝启动
    # (detour to an empty direct outbound makes no sense)。
    echo '      { "type": "udp", "tag": "local", "server": "223.5.5.5", "detour": "direct" }'
    echo '    ],'
    echo '    "rules": ['
    # 这里必须用裸 server, 不能加 "action": "route" —— 加了反而规则不生效,
    # .local 会落到 final(remote) 走代理解析。
    echo '      { "domain_suffix": [".lan", ".local", ".arpa"], "server": "local" }'
    # 国内直连域名(抖音等)的 DNS 也必须走 local(国内 UDP DNS), 否则 final=remote
    # 会把它们用境外 DoH 解析, 拿到境外 CDN 节点 —— 域名走直连却配境外IP, 抖音打不开。
    # 与 route.rules 共用同一份 CN_DIRECT 白名单, TikTok 等境外域名不受影响。
    printf '      { "domain_suffix": [%s], "server": "local" },\n' "$(render_cn_dns_sb_suffix)"
    printf '      { "domain_keyword": [%s], "server": "local" }\n' "$(render_cn_dns_sb_keyword)"
    echo '    ],'
    echo '    "final": "remote",'
    echo '    "strategy": "ipv4_only"'
    echo '  },'
    echo '  "inbounds": ['
    echo '    { "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 2080 }'
    echo '  ],'
    # first_tag 已在上面按 effective_default_node 定好, 这里不再改动。
    # 加 block 黑洞出站给 STUN 拦截用。不能用 action:reject —— 那是 sing-box 1.13+
    # 才有的字段, 1.11/1.12(compat 版面向它)会 check 失败。block 出站全版本支持。
    printf '  "outbounds": [\n%s,\n    { "type": "direct", "tag": "direct", "network_strategy": "default" },\n    { "type": "block", "tag": "block" }\n  ],\n' \
      "$(printf '%s,\n' "${ob[@]}" | sed '$ s/,$//')"
    # 劫持 DNS 只能用 "port": 53, 不能用 "protocol": "dns" —— 后者在 sing-box 1.12+
    # 匹配不到 UDP/53, 流量会直接走 final 出站(等于没接管, 仍会本地解析泄漏)。
    # STUN/WebRTC 防泄漏(与 shadowrocket 假IP、clash REJECT 三端一致):
    #   域名规则拦常见 STUN 域名; 端口规则拦 UDP 3478/5349/19302-19309, 都送 block 出站。
    # 域名与端口必须分两条: 同一 rule 里 domain + port 是"与"关系, 合写会漏。
    # 用 outbound:block 而非 action:reject, 兼容 1.11/1.12(见上方 block 出站注释)。
    # 国内直连(单一数据源, 与另外两端共用)排在 STUN 拦截之后、final 之前:
    # STUN 规则必须在前, 否则一条 .cn 之类的直连域名可能遮蔽 WebRTC 拦截。
    printf '  "route": {\n    "rules": [\n      { "port": 53, "action": "hijack-dns" },\n      { "domain_suffix": [%s], "outbound": "block" },\n      { "network": "udp", %s, "outbound": "block" },\n      { "domain_suffix": [%s], "outbound": "direct" },\n      { "domain_keyword": [%s], "outbound": "direct" }\n    ],\n    "final": "%s",\n    "auto_detect_interface": true,\n    "default_domain_resolver": "local"\n  }\n' "$(render_stun_sb_domains)" "$(render_stun_sb_ports)" "$(render_cn_sb_suffix)" "$(render_cn_sb_keyword)" "$first_tag"
    echo "}"
  } > "$out"
}

# ---------------- 客户端订阅的统一校验 ----------------
# 不用算术比较(如 [ "$v" -gt 某个上限 ]): 超大整数会让 test 返回 2(报错)而不是 0/1,
# 这个返回值在 if 里被当成"假", 反而把非法值放过去写进 JSON/YAML。
# 只允许 1..10000, 用长度 + 字符串判断, 不受算术溢出影响。
hy2_bw_ok(){
  # 用 ${1:-} 而不是 $1: set -u 下无参调用会直接中止整个脚本, 而这里
  # 只该回答"这个值合法吗", 空值就是不合法。
  local v="${1:-}"
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "${#v}" -le 4 ] && return 0
  [ "$v" = "10000" ] && return 0
  return 1
}

# 客户端默认选中的节点。DEFAULT_NODE=hy2 且确实启用了 hy2 才切 UDP;
# 其余一律 reality(抗封锁优先)。非法值只警告, 绝不改变行为。
#
# 本函数的 stdout 就是返回值(调用方写 `_dn=$(effective_default_node)`)。
# 警告必须走 stderr: 以前 warn 走 stdout, DEFAULT_NODE 填错或填了 hy2 而本次
# 没开 hy2 时, _dn 会变成"警告文字 + reality"两行, 后面 `[ "$_dn" = hy2 ]`
# 永远不成立(默认节点被静默改掉), info 里还会印出两行乱码。
effective_default_node(){
  local want="${DEFAULT_NODE:-reality}" pick=""
  # 先算出"实际存在"的那个默认节点。没启用 REALITY 时不能照报 reality ——
  # 那个出站根本不在订阅里, 三份 writer 各自兜底换成别的协议, 而 proxy sub
  # 的输出仍然印着 reality: 用户拿着这句话去客户端里找, 找不到一个叫
  # "VLESS/REALITY" 的节点, 只能怀疑订阅坏了。
  if proto_on reality; then pick=reality
  elif proto_on hy2;    then pick=hy2
  elif proto_on ss2022; then pick=ss2022
  elif proto_on anytls; then pick=anytls
  elif proto_on tuic;   then pick=tuic
  else                       pick=reality
  fi
  case "$want" in
    hy2|hysteria2)
      if proto_on hy2; then echo hy2; return 0; fi
      warn "DEFAULT_NODE=hy2 但本次未启用 hysteria2, 仍用 ${pick}" >&2 ;;
    reality|vless|"") ;;
    *) warn "DEFAULT_NODE='${want}' 不认识(可选 reality / hy2), 按 ${pick} 处理" >&2 ;;
  esac
  echo "$pick"
  return 0
}

# 订阅文件写盘之后的结构校验。重定向失败 / 变量拼坏时, 以前会留下半份或空的
# clash.yaml / singbox.json, 客户端照样显示"更新成功", 却一个节点都导不进来。
sub_json_ok(){
  local f="$1"
  [ -s "$f" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("outbounds"),list) and d["outbounds"] else 1)' \
      "$f" >/dev/null 2>&1
    return $?
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e '.outbounds | length > 0' "$f" >/dev/null 2>&1
    return $?
  fi
  # 没有 JSON 解析器时做最小兜底: 括号数量配对, 至少能挡住"写到一半截断"。
  grep -q '"outbounds"' "$f" || return 1
  [ "$(tr -cd '{' < "$f" | wc -c)" -eq "$(tr -cd '}' < "$f" | wc -c)" ] || return 1
  [ "$(tr -cd '[' < "$f" | wc -c)" -eq "$(tr -cd ']' < "$f" | wc -c)" ] || return 1
  return 0
}

sub_yaml_ok(){
  local f="$1"
  [ -s "$f" ] || return 1
  grep -q '^proxies:' "$f" || return 1
  grep -q '^  - name:' "$f" || return 1
  grep -q 'enhanced-mode: fake-ip' "$f" || return 1
  grep -q '^rules:' "$f" || return 1
  # DNS 按域名分流: 境外 DoH 经 PROXY, 国内域名用 nameserver-policy 拨回
  grep -q 'nameserver-policy:' "$f" || return 1
  grep -q "geosite:cn,private" "$f" || return 1
  grep -q 'https://cloudflare-dns.com/dns-query#PROXY' "$f" || return 1
  # 国内直连域名规则必须存在。第一条从单一数据源算, 不在校验器里写死域名。
  # _cn_first 为空(数据源缺失)时直接判失败: 否则 grep -qF "" 恒真, 校验器假绿。
  local _cn_first="" _d
  for _d in $CN_DIRECT_SUFFIXES; do _cn_first="  - DOMAIN-SUFFIX,${_d},DIRECT"; break; done
  [ -n "$_cn_first" ] || return 1
  grep -qF "$_cn_first" "$f" || return 1
  # STUN 拦截必须排在 MATCH 之前。第一条规则由单一数据源算出, 不在校验器里
  # 再写一份域名 —— 否则生成器改了、校验器没跟上, 校验全绿但防护已丢。
  local _stun_first; _stun_first=$(stun_clash_first)
  grep -qF "$_stun_first" "$f" || return 1
  grep -q 'AND,((NETWORK,udp),(DST-PORT,3478)),REJECT' "$f" || return 1
  awk '
    /DST-PORT,3478.*REJECT/ { if (!s) s=NR; sl=NR }
    /^  - MATCH,PROXY$/      { if (!m) m=NR }
    END { exit !(s && m && sl < m) }
  ' "$f" || return 1
  return 0
}

# Shadowrocket(iOS 小火箭)开箱即用配置。$1=输出路径 $2=默认节点(reality|hy2)
# 校验用: 必须含 DNS 走代理的核心三件套, 否则算生成失败。
sub_shadowrocket_ok(){
  local f="$1"
  [ -s "$f" ] || return 1
  grep -q '^\[General\]' "$f" || return 1
  # DNS 覆写必须是国内 DNS: 直连域名(抖音/淘宝)要靠它解析到国内 CDN 节点。
  # 旧版设境外 DoH 经代理(#proxy=)会让直连域名拿境外节点 -> 抖音打不开。
  grep -q '^dns-server = https://doh.pub/dns-query' "$f" || return 1
  if grep -q '#proxy=' "$f"; then return 1; fi
  # hijack-dns 只劫持写死的境外 DNS(官方 lazy_group.conf 值); :53 会连国内
  # App 的正常查询一起劫持, 把国内域名也拖去境外解析。
  grep -q '^hijack-dns = 8.8.8.8:53,8.8.4.4:53$' "$f" || return 1
  grep -q '^FINAL,PROXY,force-remote-dns$' "$f" || return 1
  grep -q '^fallback-dns-server = ' "$f" || return 1
  # 顺序闸门: 国内域名直连规则必须在 FINAL 之前。写在 FINAL 后面会被抢先
  # 匹配, 规则等于白写 —— 存在性检查全绿但国内网站照样绕代理, 属静默失效。
  # 第一条规则从单一数据源算, 不在校验器里再写死 taobao.com: 否则改了清单
  # 校验器没跟上, 校验全绿但其实已经漂移(和 STUN 校验器同一原则)。
  local _cn_first="" _cn_kw_first="" _d
  for _d in $CN_DIRECT_SUFFIXES; do _cn_first="DOMAIN-SUFFIX,${_d},DIRECT"; break; done
  for _d in $CN_DIRECT_KEYWORDS; do _cn_kw_first="DOMAIN-KEYWORD,${_d},DIRECT"; break; done
  # 数据源缺失时不能放行(否则 awk 拿空 first 去比, 校验形同虚设)。
  [ -n "$_cn_first" ] && [ -n "$_cn_kw_first" ] || return 1
  awk -v first="$_cn_first" '
    $0 == first { if (!cn) cn=NR }
    /^FINAL,PROXY,force-remote-dns$/    { if (!fin) fin=NR }
    END { exit !(cn && fin && cn < fin) }
  ' "$f" || return 1
  # 关键词规则同样必须在 FINAL 之前。写在后面会被 FINAL 抢先匹配, 静默失效。
  awk -v first="$_cn_kw_first" '
    $0 == first { if (!kw) kw=NR }
    /^FINAL,PROXY,force-remote-dns$/    { if (!fin) fin=NR }
    END { exit !(kw && fin && kw < fin) }
  ' "$f" || return 1
  # 短词/英文常用词会误伤境外域名 -> 那些域名走 DIRECT 就在本地查 DNS, 泄露。
  if grep -Eq '^DOMAIN-KEYWORD,(mi|vip|oppo|honor|dji|cn|com|app|www),DIRECT$' "$f"; then
    return 1
  fi
  # WebRTC 防泄漏: 必须有 stun-response-ip, 且值必须是合法 IP(2026-11-22 起
  # 填真实 VPS 出口 IP, 不再是写死的 1.1.1.1 —— 后者会被属地检测误报泄露)。
  # 用正则校验形状, 不绑死具体 IP, 否则换出口 IP 就把自己的校验器卡死。
  local _stun_oct='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
  grep -Eq "^stun-response-ip = ${_stun_oct}\\.${_stun_oct}\\.${_stun_oct}\\.${_stun_oct}$" "$f" || return 1
  grep -q 'udp-policy-not-supported-behaviour = REJECT' "$f" || return 1
  # STUN 域名层拦截: 必须有, 且必须排在 FINAL 之前(写在后面会被 FINAL 抢先匹配)。
  # 第一条规则从单一数据源算, 校验器与生成器永不漂移。
  local _stun_first; _stun_first=$(stun_sr_first)
  grep -qF "$_stun_first" "$f" || return 1
  local _stun_re
  _stun_re=$(printf '%s|' "${STUN_DOMAINS[@]}" | sed 's/|$//; s/\./\\./g')
  awk -v re="^DOMAIN-SUFFIX,(${_stun_re}),REJECT-NO-DROP$" '
    $0 ~ re { if (!s) s=NR; sl=NR }
    /^FINAL,PROXY,force-remote-dns$/                       { if (!fin) fin=NR }
    END { exit !(s && fin && sl < fin) }
  ' "$f" || return 1
  return 0
}

# 生成小火箭配置文件。
# 字段全部来自官方 lazy_group.conf 与 DuskWander87 成熟配置交叉验证过的值:
#   dns-server = 国内 DNS      官方语义只服务直连域名, 就近解析到国内 CDN 节点
#   direct-dns-server=国内DNS  直连域名专用, 优先级高于 dns-server
#   hijack-dns = 8.8.8.8:53,8.8.4.4:53  只劫持写死境外 DNS 的 App(官方默认值)
#   dns-direct-system=false   不让 App 直接用系统 DNS
#   fallback-dns-server       官方字段(旧版写的 dns-fallback-system 官方不存在)
#   FINAL,PROXY,force-remote-dns  境外域名不在本地解析, 交服务端(防泄露主力)
#   block-quic=all-proxy      走代理的 QUIC 回退 HTTP/2, 防 QUIC 绕过
# 关键教训(2026-11-28): dns-server 曾被设成境外 DoH 经代理(#proxy=), 但按官方
# 语义它只服务直连域名 —— 抖音/淘宝被解析到境外节点, "开 VPN 抖音打不开"。
# 境外域名走 force-remote-dns 服务端解析, 所以 dnsleaktest 仍显示境外解析器。
write_shadowrocket_conf(){
  local out="$1" _defnode="${2:-reality}"
  # 说明: 旧版这里用 #proxy=节点名 让 DNS 经隧道, 但该语法只应服务于
  # "代理域名"; 直连域名(抖音/淘宝)经它会拿境外 DoH 解析到境外 CDN 节点。
  # 现改为国内 DNS 直出, 不再依赖节点名 —— 也顺带消除了"节点名写错 DNS 卡死"
  # 这一整类故障(节点名回退逻辑随之删除)。
  # WebRTC 的 STUN 应答 IP 必须填真实 VPS 出口 IP, 不能写死 1.1.1.1:
  #   属地检测工具会把 "WebRTC 报的公网 IP" 与 "代理出口 IP" 对比, 写死
  #   1.1.1.1(Cloudflare anycast, 不少地理位置库标成澳大利亚)就永远显示
  #   "WebRTC 地址泄露 / 与出口不一致"; 填成真实出口 IP 两者一致, 告警消失。
  #   VPS IP 本来就是所有网站看到的出口, 让 STUN 也报它不引入任何新泄露。
  # 拿不到出口 IP 时退回 1.1.1.1(仍是假 IP, 只是会触发那条显示告警)。
  local _stun_ip="${SERVER_IP:-}"
  # 每段的数值也要在 0-255(光校验形状会让 999.999.999.999 进配置)。
  local _oct='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
  if ! [[ "$_stun_ip" =~ ^${_oct}\.${_oct}\.${_oct}\.${_oct}$ ]]; then _stun_ip="1.1.1.1"; fi
  {
    # Shadowrocket 配置 - 由 proxy-node 自动生成 (DNS 防泄露已配好)
    # 用法: ① 先用 base64.txt 导入节点  ② 再导入本文件并「使用配置」
    #       ③ 首页全局路由选「配置」  ④ 选一个节点打开
    # 直连域名用国内 DNS(抖音/淘宝就近 CDN), 境外域名远端解析。
    # DNS 泄露检测仍显示境外解析器(境外域名走 force-remote-dns 服务端解析)。
    # 详见客户端指南第五节。节点请单独导入, 本文件只管 DNS 与分流。
    echo "[General]"
    echo "bypass-system = true"
    echo "skip-proxy = 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 127.0.0.1, localhost, *.local, captive.apple.com"
    echo "tun-excluded-routes = 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 255.255.255.255/32"
    # dns-server(DNS 覆写)按官方语义只服务【直连域名】的解析。必须国内 DNS:
    # 抖音/淘宝/B站要拿到国内 CDN 节点; 设境外 DoH 会解析到境外节点 ->
    # "开着 VPN 抖音打不开"。官方 lazy_group.conf 默认也是国内 DoH/UDP。
    # 境外域名不经过这里: 它们走下面的 FINAL,PROXY,force-remote-dns 由服务端
    # (VPS)解析, dnsleaktest 仍显示境外解析器, 防泄露不受影响。
    echo "dns-server = ${DNS_DOH_CN},${DNS_DOH_CN2},223.5.5.5,119.29.29.29"
    # direct-dns-server: 直连域名专用, 优先级高于 dns-server, 同样是国内 DNS。
    echo "direct-dns-server = 223.5.5.5, 119.29.29.29"
    # 只劫持写死境外 DNS 的 App(官方 lazy_group.conf 原值)。设成 :53 会把国内
    # App 发往运营商/223.5.5.5 的正常查询也劫持进来, 国内域名被拖去境外解析。
    echo "hijack-dns = 8.8.8.8:53,8.8.4.4:53"
    echo "dns-direct-system = false"
    # 官方字段是 fallback-dns-server; 旧的 dns-fallback-system 官方不存在(死配置)。
    # 回退也钉在国内 DNS, 不走可能污染的运营商 DNS。
    echo "fallback-dns-server = 223.5.5.5,119.29.29.29"
    echo "private-ip-answer = true"
    echo "ipv6 = false"
    echo "prefer-ipv6 = false"
    echo "block-quic = all-proxy"
    # 以下两项来自 Shadowrocket 官方懒人配置(lazy.conf 2026-10-15), 防 WebRTC
    # 与 UDP 绕过: stun-response-ip 让 TUN 里的 STUN 查询返回固定 IP 而非客户端
    # 真实地址, 堵住 WebRTC 泄漏本机真实 IP。这里填真实 VPS 出口 IP(见上面
    # _stun_ip), 使 WebRTC 报的公网 IP 与代理出口一致, 属地检测不再误报泄露。
    # ipv6 整个功能已关(ipv6=false), ::1 只是环回占位, 不会被当成公网 IPv6。
    # udp-policy-not-supported-behaviour = REJECT 让 UDP 命中不支持转发的策略时
    # 拒绝而不是直连(直连会暴露真实 IP); 本脚本节点都支持 UDP, 不会误伤。
    echo "stun-response-ip = ${_stun_ip}"
    echo "stun-response-ipv6 = ::1"
    echo "udp-policy-not-supported-behaviour = REJECT"
    # 局域网/内网直连, no-resolve 避免为匹配 IP 规则触发本地 DNS 解析
    echo "[Rule]"
    echo "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"
    echo "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"
    echo "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve"
    echo "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"
    echo "GEOIP,CN,DIRECT,no-resolve"
    # Apple 直连: 推送/iMessage/系统服务走国内, 避免被代理拖慢或收不到推送
    echo "DOMAIN-SUFFIX,apple.com,DIRECT"
    echo "DOMAIN-SUFFIX,icloud.com,DIRECT"
    echo "DOMAIN-SUFFIX,me.com,DIRECT"
    echo "DOMAIN-SUFFIX,mzstatic.com,DIRECT"
    # 国内域名必须显式直连: GEOIP,CN 是 IP 规则, no-resolve 后域名请求不命中它,
    # 会一路掉到 FINAL 走代理("国外正常, 淘宝/B站打不开")。从单一数据源渲染,
    # 内置 + 用户 + 远程名单都在里面, 排在 FINAL 之前。
    # 不写 GEOSITE(小火箭 README 无此类型)、不用 RULE-SET(依赖 raw.githubusercontent.com,
    # 国内常拉不到), 只用官方支持的 DOMAIN-SUFFIX / DOMAIN-KEYWORD。
    render_cn_sr_suffix
    render_cn_sr_keyword
    # Claude / TikTok 的域名(含客服/监控/支付/反欺诈等第三方域名)不单列:
    # 兜底 FINAL,PROXY 已把它们全部钉在同一出口, DNS 也远端解析, 不会漏真实IP。
    # 网传域名清单是给'只代理列名域名、其余直连'的配置用的, 与本配置架构相反。
    # 尤其别照抄 IP-CIDR,34.8.0.0/16,PROXY: 域名撞 IP 规则会先查本地 DNS 判断
    # IP, 反而泄露运营商解析; 加 no-resolve 则域名跳过该规则, 等于白写。
    # 关键: 境外域名不本地解析, 原样交服务端。检测工具看到的是 VPS(境外)。
    # WebRTC/STUN 域名层拦截(与 stun-response-ip 假IP 双保险; 与 clash/singbox 共用单一数据源)
    # REJECT-NO-DROP 让客户端快速失败而非等超时。必须在 FINAL 之前。
    render_stun_sr
    echo "FINAL,PROXY,force-remote-dns"
    echo "[Host]"
    echo "localhost = 127.0.0.1"
  } > "$out"
}

# ---------------- Clash / mihomo 客户端订阅配置 ----------------
# REALITY 的 X25519MLKEM768 是"两边都支持才协商"的混合密钥交换, 时间线(已实测):
#   v25.5.16  服务端开始支持(伪装站支持时自动启用), 客户端发不发都能连
#   v26.9.8   服务端改为**强制**要求 ClientHello 带该 key share, 不带就静默
#             fallback 到伪装站 —— 客户端只看到 "REALITY authentication failed"
# mihomo 只有写了 reality-opts.support-x25519mlkem768: true 才会发该 key share
# (字段从 mihomo 1.19.10 起存在; 更老的版本会忽略这个未知字段、不报错, 但同样
# 连不上 26.9.8+ 的服务端 —— 实测 1.18.10 能正常加载配置, 只是认证失败)。
# 实测矩阵(mihomo 1.19.34, 同一份 UUID/公钥/shortId/SNI, 本地起服务端):
#   服务端 25.4.30 + 不写 -> 204 / MLKEM=false   + 写 -> auth=false
#   服务端 26.3.27 + 不写 -> 204 / MLKEM=false   + 写 -> 204 / MLKEM=true
#   服务端 26.11.9 + 不写 -> auth=false          + 写 -> 204 / MLKEM=true
# 所以分界是 25.5.16: 低于它绝不能写(写了必挂), 高于它写了只会更好(抗量子),
# 26.9.8 起则是必须写。表现: 节点在、规则全加载、延迟测不通、上传下载恒 0 B,
# 换 xray 内核却正常 —— 极易被误判成"服务端坏了"或"订阅文件写错了"。
# 服务端 Xray 版本是否 >= 指定版本($1 形如 26.9.8)。
# 版本号来自 state.env 的 XRAY_VERSION, 可能是 latest(追最新)或空(很老的 state)。
# 未知一律按"够新"处理: latest 在安装时就被解析成具体版本写回 state, 正常走不到。
xray_ver_ge(){
  local want="${1:-0}" v="${XRAY_VERSION:-}" a b c wa wb wc
  case "$v" in ''|latest) return 0 ;; esac
  a="${v%%.*}"; v="${v#*.}"
  b="${v%%.*}"; c="${v#*.}"; c="${c%%.*}"
  wa="${want%%.*}"; want="${want#*.}"
  wb="${want%%.*}"; wc="${want#*.}"; wc="${wc%%.*}"
  # 解析不出来就当"够新": 宁可多写一个老客户端会忽略的字段, 也别漏掉必需的。
  case "$a"  in ''|*[!0-9]*) return 0 ;; esac
  case "$b"  in ''|*[!0-9]*) b=0 ;; esac
  case "$c"  in ''|*[!0-9]*) c=0 ;; esac
  case "$wa" in ''|*[!0-9]*) wa=0 ;; esac
  case "$wb" in ''|*[!0-9]*) wb=0 ;; esac
  case "$wc" in ''|*[!0-9]*) wc=0 ;; esac
  [ "$a" -gt "$wa" ] && return 0
  [ "$a" -lt "$wa" ] && return 1
  [ "$b" -gt "$wb" ] && return 0
  [ "$b" -lt "$wb" ] && return 1
  [ "$c" -ge "$wc" ] && return 0
  return 1
}

clash_mlkem_ok(){
  xray_ver_ge 25.5.16
}

# sing-box 的 REALITY 客户端能不能连上当前服务端。
# Xray >= 26.9.8 的 REALITY 服务端要求 ClientHello 里带 X25519MLKEM768 key share
# (且排在纯 X25519 之前), 而 sing-box 用的 uTLS chrome 模板不带 —— 服务端会静默
# fallback 到伪装站, 客户端只看到 "reality verification failed"。上游 issue
# SagerNet/sing-box#4520 至今未修(1.14.4 实测仍失败), 客户端侧没有开关可绕:
#   - curve_preferences 不管用(uTLS 用自己的 ClientHello 模板, 不读这个字段)
#   - 换指纹(chrome/firefox/safari/ios/edge)全部失败
#   - 关 uTLS 直接被拒: "uTLS is required by reality client"
# 本地起 Xray 26.11.9 服务端复现过, 与本项目服务端配置无关。
sb_reality_ok(){
  ! xray_ver_ge 26.9.8
}

# $1 = 输出路径  $2 = Brutal 上行 Mbps(空=不启用)  $3 = 下行  $4 = 默认节点(reality|hy2)
# 与小火箭、sing-box 的 writer 结构对称: 三者都只从单一数据源取 DNS/STUN 端点,
# 不各自硬编码。clash 的 Brutal 带宽和默认节点由调用方清洗后传入 —— 以前这段
# 内嵌在 gen_sub_files 里, 只能靠外层局部变量传递, 单独调用就没法测。
write_clash_yaml(){
  local out="$1" _bw_up="${2:-}" _bw_down="${3:-}" _dn="${4:-reality}"
  # 单独被调用时 PRIMARY_UUID 可能还没算, 这里自己兜一次(同 write_sb_client)。
  local PRIMARY_UUID="${PRIMARY_UUID:-$(primary_uuid)}"
  {
    echo "mixed-port: 7890"
    echo "allow-lan: false"
    echo "mode: rule"
    echo "log-level: info"
    # 关掉 IPv6: 客户端有公网 v6 时, 部分应用会绕过代理直连 AAAA 记录,
    # Google 一旦看到真实的中国 v6 出口就会把会话判成中国区(即"送中")
    echo "ipv6: false"
    # DNS 必须自己接管。不写这段的话 Clash 会用系统 DNS(国内运营商/114),
    # 在 TUN 模式下先本地解析再把 IP 发给服务端 —— 服务端只能看到 IP,
    # Google 反向查到的就是你本地的解析结果, 于是判定成中国用户。
    # fake-ip 让所有域名拿到 198.18.x.x 的假地址, 真域名原样透传给服务端解析。
    echo "dns:"
    echo "  enable: true"
    echo "  ipv6: false"
    echo "  enhanced-mode: fake-ip"
    echo "  fake-ip-range: 198.18.0.1/16"
    echo "  fake-ip-filter:"
    echo '    - "+.lan"'
    echo '    - "+.local"'
    echo '    - "+.arpa"'
    echo '    - "+.msftconnecttest.com"'
    echo '    - "+.msftncsi.com"'
    echo '    - "localhost.ptlogin2.qq.com"'
    # DNS 按域名分流(与 shadowrocket.conf 的境外经隧道 + 国内就近策略一致):
    #   default-nameserver 必须填 IP(用来解析下面 DoH 域名本身, 官方硬性要求);
    #   nameserver 默认走境外加密 DoH 经 PROXY 隧道("#PROXY" 是 mihomo 附加参数),
    #   nameserver-policy 把国内域名(geosite:cn)拨回国内 DoH 保 CDN 就近调度。
    # 这样"DNS 所在地与出口 IP 一致", 其它 App 若强制本地查询也不会漏国内运营商。
    # DNS 端点全部来自单一数据源(见文件头部 DNS_DOH_* 声明)
    echo "  default-nameserver:"
    echo "    - 223.5.5.5"
    echo "    - 119.29.29.29"
    echo "  nameserver:"
    echo "    - ${DNS_DOH_FOREIGN}#PROXY"
    echo "    - ${DNS_DOH_FOREIGN2}#PROXY"
    echo "  nameserver-policy:"
    # geosite:cn 只覆盖常见国内站, 抖音 CDN(snssdk/byteimg/pstatp 等)不在其中。
    # 把同一份 CN_DIRECT 白名单也拨回国内 DoH, 保证 "直连域名=国内DNS" 一致,
    # 否则抖音域名走直连但 DNS 经代理出境外, 拿到境外 CDN 节点就打不开。
    render_cn_dns_clash
    echo "    '${DNS_CN_GEOSITE}':"
    echo "      - ${DNS_DOH_CN}"
    echo "      - ${DNS_DOH_CN2}"
    echo "  proxy-server-nameserver:"
    echo "    - ${DNS_DOH_CN}"
    echo "proxies:"
    if proto_on reality; then
      echo "  - name: \"${NODE_NAME}-VLESS\""
      echo "    type: vless"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${VLESS_PORT}"
      echo "    uuid: ${PRIMARY_UUID}"
      echo "    network: tcp"
      echo "    udp: true"
      echo "    tls: true"
      echo "    flow: xtls-rprx-vision"
      echo "    servername: ${DEST}"
      echo "    client-fingerprint: ${REALITY_FP:-chrome}"
      echo "    reality-opts:"
      echo "      public-key: ${PUB}"
      clash_mlkem_ok && echo "      support-x25519mlkem768: true"
      echo "      short-id: ${SID}"
    fi
    if proto_on hy2; then
      echo "  - name: \"${NODE_NAME}-HY2\""
      echo "    type: hysteria2"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${HY2_PORT}"
      echo "    password: \"${HY2_PASS}\""
      echo "    sni: ${DEST}"
      # mihomo 的 up/down 是客户端的上传/下载带宽, 填了才启用 Brutal 拥塞控制。
      # 只写进订阅文件: hysteria2:// 分享链接标准里没有这两个参数。
      [ -n "$_bw_up" ]   && echo "    up: \"${_bw_up} Mbps\""
      [ -n "$_bw_down" ] && echo "    down: \"${_bw_down} Mbps\""
      if [ -n "${HY2_PIN:-}" ] && [ -n "${CERT_HEX:-}" ]; then
        echo "    skip-cert-verify: false"
        echo "    fingerprint: ${CERT_HEX}"
      else
        echo "    skip-cert-verify: true"
      fi
      [ -n "${HY2_HOP:-}" ] && echo "    ports: \"${HY2_HOP}\""
      if [ "$ENABLE_OBFS" = "1" ]; then
        echo "    obfs: salamander"
        echo "    obfs-password: \"${OBFS_PASS}\""
      fi
    fi
    if proto_on ss2022; then
      echo "  - name: \"${NODE_NAME}-SS2022\""
      echo "    type: ss"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${SS2022_PORT}"
      echo "    cipher: 2022-blake3-aes-128-gcm"
      echo "    password: \"$(ss_pass_for "$PRIMARY_UUID")\""
      echo "    udp: true"
    fi
    if proto_on anytls; then
      echo "  - name: \"${NODE_NAME}-AnyTLS\""
      echo "    type: anytls"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${ANYTLS_PORT}"
      echo "    password: \"$(derive_hex "$PRIMARY_UUID")\""
      echo "    sni: ${DEST}"
      # mihomo 的 anytls 默认 udp=false, 不写这条该节点不承载 UDP:
      # QUIC / HTTP3 / 语音会静默回落, 表现成"这条线某些应用特别慢"。
      echo "    udp: true"
      echo "    skip-cert-verify: true"
    fi
    if proto_on tuic; then
      echo "  - name: \"${NODE_NAME}-TUIC\""
      echo "    type: tuic"
      echo "    server: ${SERVER_IP}"
      echo "    port: ${TUIC_PORT}"
      echo "    uuid: ${PRIMARY_UUID}"
      echo "    password: \"$(derive_hex "$PRIMARY_UUID")\""
      echo "    sni: ${DEST}"
      echo "    alpn: [h3]"
      echo "    congestion-controller: bbr"
      echo "    skip-cert-verify: true"
    fi
    echo "proxy-groups:"
    echo "  - name: PROXY"
    echo "    type: select"
    echo "    proxies:"
    # select 的第一项就是客户端默认选中的节点。DEFAULT_NODE=hy2 时把 UDP
    # 节点排到最前(速度优先), 其余协议与顺序完全不变。
    if [ "$_dn" = "hy2" ]; then
      echo "      - \"${NODE_NAME}-HY2\""
    fi
    proto_on reality && echo "      - \"${NODE_NAME}-VLESS\""
    if proto_on hy2 && [ "$_dn" != "hy2" ]; then
      echo "      - \"${NODE_NAME}-HY2\""
    fi
    proto_on ss2022  && echo "      - \"${NODE_NAME}-SS2022\""
    proto_on anytls  && echo "      - \"${NODE_NAME}-AnyTLS\""
    proto_on tuic    && echo "      - \"${NODE_NAME}-TUIC\""
    echo "rules:"
    # 国内直连必须写进订阅里。只写 MATCH,PROXY 的话, 淘宝/B站/微信也会
    # 绕一圈出国再回来 —— 慢是小事, 很多国内服务直接拒绝境外 IP, 表现为
    # "开了代理国内网站打不开"。
    #
    # 局域网地址先放行: allow-lan 关了只影响别人连你, 不影响你访问 NAS / 打印机,
    # 后者要是不放行会一起被塞进代理, 表现为本地设备连不上。
    # 这里用 IP-CIDR 而不是 GEOIP,LAN —— 后者不是所有 Clash 内核都认,
    # 一条不认的规则会让整份订阅加载失败, 代价太大。
    echo "  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"
    echo "  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"
    echo "  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve"
    echo "  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"
    # GEOSITE,cn 是纯域名规则, 匹配阶段不解析域名 —— 所以 fake-ip 语义不受
    # 影响: 国内域名命中后直连, 由 nameserver(国内 DoH) 正常解析出国内 IP。
    # GEOIP,CN 后面加 no-resolve: 只处理"连接目标本身就是 IP"的情况,
    # 不去主动解析域名, 避免把 fake-ip 打穿。
    echo "  - GEOSITE,cn,DIRECT"
    echo "  - GEOIP,CN,DIRECT,no-resolve"
    # 国内直连单一数据源(内置 + 用户自定义 + 远程更新)。GEOSITE 覆盖广但更新
    # 依赖内核自带数据, 这份清单补它未收录的域名, 也让用户自己加的域名立刻生效。
    render_cn_clash
    # WebRTC/STUN 防泄漏: 域名 + UDP 端口(与另外两端共用单一数据源)。
    # 限定 NETWORK,udp 是关键——STUN/TURN 走 UDP, 不限制会误伤同端口的 TCP 流量。
    render_stun_clash
    echo "  - MATCH,PROXY"
  } > "$out"
}

gen_sub_files(){
  PRIMARY_UUID="${PRIMARY_UUID:-$(primary_uuid)}"
  # write_sb_client 会在 REALITY 与 sing-box 不兼容时置 1, 这里先清掉上一次的
  # 残留值: 同一进程里重复生成(重装/改协议)时, 旧的标记会让告警误报。
  SB_REALITY_BROKEN=0
  # Brutal 带宽填错比不填更糟: 官方明确说填高了会因丢包补偿导致"连接速度慢、
  # 不稳定且浪费流量"。这里只清洗**本次生成用的局部值**, 不动全局变量 ——
  # 之前一出错就把全局清空, 紧接着的 save_state 会把用户已保存的设置抹掉。
  # 局部值同时供本函数内的 clash.yaml 与被调用的 write_sb_client 使用。
  local _bw_up="${HY2_BW_UP:-}" _bw_down="${HY2_BW_DOWN:-}" _bw_bad=0 _bv
  for _bv in "$_bw_up" "$_bw_down"; do
    [ -n "$_bv" ] || continue
    hy2_bw_ok "$_bv" || { _bw_bad=1; break; }
  done
  if [ "$_bw_bad" = "1" ]; then
    warn "HY2_BW_UP/DOWN 必须是 1-10000 的整数(Mbps), 本次按默认 BBR 生成(已保存的设置不变)"
    _bw_up=""; _bw_down=""
  elif { [ -n "$_bw_up" ] && [ -z "$_bw_down" ]; } || { [ -z "$_bw_up" ] && [ -n "$_bw_down" ]; }; then
    # Brutal 是按"客户端实际链路带宽"做补偿的, 两边都要有值才有意义:
    # 只填一个时 sing-quic 拿不到发送速率, 会静默退回 BBR —— 用户以为开了其实没开。
    warn "Brutal 建议 up 与 down 一起填(现在只填了一个), 否则部分客户端会静默退回 BBR"
  fi
  local _dn
  _dn=$(effective_default_node)
  mkdir -p "$SUB_DIR"
  # 目录名本身就是 token, 没开 HTTP 时收紧权限防同机用户 ls; 开了才放开。
  # 一律先收紧: 真正开放给 nobody 是 maybe_sub_http 确认服务起来之后的事。
  # 只按 SUB_HTTP 变量放开的话, "开了 HTTP 但没装 python3/端口非法"的机器
  # 会把 UUID/密码摊成同机可读, 而服务从头到尾没运行过。
  chmod 700 "$SUB_DIR"
  # token 会直接拼进订阅目录 $SUB_DIR/$SUB_TOKEN。只判空不够: 手改过的
  # state.env / 旧备份里带 / 或 .. 时, root 下 mkdir -p 会写到目录外,
  # chmod 755 还会作用到父目录。校验必须在 mkdir 之前, 不能留给后面的
  # maybe_sub_http(那时文件早就写出去了)。
  case "${SUB_TOKEN:-}" in
    ''|*[!A-Za-z0-9_-]*)
      # 旧 token 若曾以 755/644 开放过, 轮换后旧目录仍摊着全套凭据。
      # 只处理安全字符的旧 token, 避免把 / 或 .. 拼进路径误改外部目录。
      local _old_token="${SUB_TOKEN:-}"
      SUB_TOKEN=$(openssl rand -hex 16 2>/dev/null)
      [ -n "$SUB_TOKEN" ] || SUB_TOKEN=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')
      [ -n "$SUB_TOKEN" ] || die "无法生成订阅 token (openssl 与 /dev/urandom 都不可用)"
      warn "订阅 token 为空或含非法字符, 已重新生成; 请重新获取订阅链接"
      case "$_old_token" in
        ''|*[!A-Za-z0-9_-]*) : ;;
        *)
          if [ "$_old_token" != "$SUB_TOKEN" ] && [ -d "${SUB_DIR}/${_old_token}" ]; then
            chmod 700 "${SUB_DIR}/${_old_token}" 2>/dev/null
            find "${SUB_DIR}/${_old_token}" -type f -exec chmod 600 {} + 2>/dev/null
          fi
          ;;
      esac
      ;;
  esac
  local tdir="${SUB_DIR}/${SUB_TOKEN}"
  # 必须先 700: 下面任何一步 die 都会留下已写出的凭据文件。若这里给 755,
  # 失败路径上同机任意用户都能读 UUID/密码/订阅链接。真正要开放给 nobody
  # 读是在本函数末尾、所有校验都通过之后(SUB_HTTP=1 才做)。
  mkdir -p "$tdir"; chmod 700 "$tdir"

  local links=()
  proto_on reality && links+=("$VLESS_LINK")
  proto_on hy2     && links+=("$HY2_LINK")
  proto_on ss2022  && links+=("$SS_LINK")
  proto_on anytls  && links+=("$ANYTLS_LINK")
  proto_on tuic    && links+=("$TUIC_LINK")
  [ ${#links[@]} -gt 0 ] || die "没有任何可用协议, 检查 PROTOCOLS"
  printf '%s\n' "${links[@]}" > "$tdir/links.txt"

  # base64 失败会留下一个空文件, 订阅客户端却显示"更新成功"。显式检查, 失败即中止。
  local b64
  b64=$(printf '%s\n' "${links[@]}" | base64 -w0) || die "订阅 base64 编码失败"
  [ -n "$b64" ] || die "订阅 base64 编码结果为空"
  printf '%s\n' "$b64" > "$tdir/base64.txt" || die "写入 base64.txt 失败"

  write_clash_yaml "$tdir/clash.yaml" "$_bw_up" "$_bw_down" "$_dn"

  # Shadowrocket(iOS 小火箭)开箱即用配置: DNS 防泄露已经配好, 导入即用。
  # 背景: 小火箭用户以前只能拿 base64.txt 纯节点, 不带任何 DNS 配置,
  # 图形界面那个"DNS 覆写"框留空 = 用国内运营商 DNS, DNS 泄露检测一查一个准。
  #
  # 这份配置的两条腿(已对照 LOWERTOP/Shadowrocket 官方 lazy_group.conf 与
  # DuskWander87/shadowrocket-config 成熟配置里的字段, 不写没验证过的语法):
  #   1) FINAL,PROXY,force-remote-dns —— 境外域名根本不在本地解析, 原样送
  #      服务端解析。检测工具从权威 DNS 侧看到的是 VPS(境外), 不是国内运营商。
  #      这条不需要节点名, 是防泄露的主力。
  #   2) dns-server / direct-dns-server = 国内 DNS —— 按 Shadowrocket 官方语义,
  #      DNS 覆写只服务【直连域名】, 必须让抖音/淘宝解析到国内 CDN 节点。
  #      旧版把 dns-server 设成境外 DoH 经代理, 方向反了: 直连域名拿境外节点,
  #      表现就是"开 VPN 抖音打不开"。境外域名走远端解析, 不受影响。
  #
  # 节点不写进 [Proxy] 段: 官方 README 明说配置文件内写节点只是兼容用途,
  # 且逗号分隔字段格式对 hysteria2/reality 的支持未完整文档化 —— 写错一行
  # 会让整份配置加载失败。保留 [Proxy] 段为空, 节点由 base64.txt 单独导入,
  # 这份配置只负责接通后的 DNS 与分流, 职责单一、失败面最小。
  write_shadowrocket_conf "$tdir/shadowrocket.conf" "$_dn"

  # sing-box 客户端配置: 两份, 适配不同内核版本(见 write_sb_client 上方说明)
  write_sb_client pinned "$tdir/singbox.json"
  write_sb_client compat "$tdir/singbox-compat.json"
  if [ "${SB_REALITY_BROKEN:-0}" = "1" ]; then
    warn "服务端 Xray >= 26.9.8 的 REALITY 与 sing-box 客户端不兼容(上游 #4520): singbox.json / v2rayn-routed.json 已默认走 HY2; 要用 REALITY 请用 mihomo(clash.yaml)或 xray 内核客户端(v2rayn.txt)"
  elif [ "${SB_REALITY_ONLY:-0}" = "1" ]; then
    warn "服务端 Xray >= 26.9.8 的 REALITY 与 sing-box 客户端不兼容(上游 #4520), 且未启用 HY2 可供切换: singbox.json / v2rayn-routed.json 的默认出口不可用! 请改用 clash.yaml(mihomo 内核)或 v2rayn.txt(xray 内核), 或者启用 HY2 后执行 proxy sub"
  fi
  # v2rayN 专用路由配置: v2rayn*.txt 是纯节点链接(URI 标准无 DNS 字段), 用户导入后
  # 还要手动配 fake-ip/绕过大陆, 一旦漏配或路由模式选错, Claude 第三方域名就可能
  # 从真实 IP 直连出去。这份配置把 singbox.json(已含 DNS 分流 + STUN 拦截 +
  # route.final 全代理 + 证书固定)复制成独立文件, v2rayN 用 sing-box 内核导入后
  # 即自带完整防护, 与纯链接的"自己配"路线二选一。
  # 这份是 v2rayN 的首选导入文件(指南里排第 ①), 复制失败必须当场报错:
  # 以前静默失败, 校验清单又没它, 结果"订阅已生成"全绿而该 URL 直接 404。
  cp -f "$tdir/singbox.json" "$tdir/v2rayn-routed.json" \
    || die "生成 v2rayn-routed.json 失败(磁盘空间或权限?)"

  # v2rayN 订阅: 新版本身识别 pinSHA256, 直接用带 pin 的主链接(真证书固定)。
  # 另附一条无 pin 的兼容链接给老版本兜底, 但放在最后且带 -oldv2rayN 标记,
  # 让新版用户优先选中带 pin 的那条。
  {
    # Hysteria2: 直接复用 gen_links 拼好的链接。手拼版本漏过 obfs 与 mport ——
    # 开了 salamander 混淆或端口跳跃时, v2rayN 导入后 QUIC 握手被服务端直接丢弃,
    # 表现成"节点在但连不上", 极难排查。新版 v2rayN 识别 pinSHA256, 主链接带
    # pin 才是真证书固定; 无 pin 的兼容链接作为第二条给老版本兜底。
    proto_on hy2 && printf '%s\n' "$HY2_LINK"
    [ -n "${HY2_LINK_COMPAT:-}" ] && printf '%s\n' "$HY2_LINK_COMPAT"
    # AnyTLS / TUIC 直接复用 gen_links 拼好的链接。以前这里又手拼了一遍,
    # TUIC 那行漏了 congestion_control=bbr(v2rayN 会退回默认拥塞控制, 表现成
    # "能连但慢"), 而且 #fragment 没做 URI 编码, 和 links.txt 里的同名节点
    # 其实是两条不同的字符串。手拼版本保留过的注释: v2rayN 不认指纹参数,
    # 这两条只能 insecure=1 / allow_insecure=1, gen_links 里就是这么写的。
    proto_on anytls && printf '%s\n' "$ANYTLS_LINK"
    proto_on tuic   && printf '%s\n' "$TUIC_LINK"
    # REALITY/SS2022 不需要指纹(REALITY 用短ID+公钥, SS2022 用密钥派生)
    proto_on reality && printf '%s\n' "$VLESS_LINK"
    proto_on ss2022  && printf '%s\n' "$SS_LINK"
  } > "$tdir/v2rayn.txt"

  # 新版 v2rayN(Xray-core v26.2.6 起移除 TLS allowInsecure)对带 insecure 的节点
  # 会持续提示"不安全"; 用户若在设置里勾了"默认跳过证书验证", 新导入的配置还会全挂。
  # 这份订阅只给不含 TLS 跳过验证的节点: REALITY 靠 pbk/sid 验身份、SS2022 没有 TLS,
  # 两者都不受该变更影响, 导入后干净可用。
  # 两个都没开时不生成空文件 —— 空的订阅会让客户端报错。
  local safe_links=""
  proto_on reality && safe_links="${safe_links}${VLESS_LINK}"$'\n'
  proto_on ss2022  && safe_links="${safe_links}${SS_LINK}"$'\n'
  # tdir 是持久订阅目录(不是临时目录), 条件生成前先删旧文件: 否则关掉
  # reality/ss2022 后重新 sub, 旧的 safe 订阅会残留, 客户端还在导入一条
  # 服务端已经不再提供的 REALITY 链接。
  rm -f "$tdir/v2rayn-safe.txt"
  [ -n "$safe_links" ] && printf '%s' "$safe_links" > "$tdir/v2rayn-safe.txt"

  local gsum=""
  proto_on reality && gsum="${gsum}   VLESS/TCP ${VLESS_PORT}"
  proto_on hy2     && gsum="${gsum}   Hysteria2/UDP ${HY2_PORT}"
  proto_on ss2022  && gsum="${gsum}   SS2022/TCP+UDP ${SS2022_PORT}"
  proto_on anytls  && gsum="${gsum}   AnyTLS/TCP ${ANYTLS_PORT}"
  proto_on tuic    && gsum="${gsum}   TUIC/UDP ${TUIC_PORT}"

  # sing-box 内核与新版 REALITY 服务端不兼容(见 sb_reality_ok), 指南里必须写清楚。
  # 否则用户按"首选 routed.json"导入后 REALITY 连不上, 只会以为服务端坏了。
  local sbreal_note=""
  if proto_on reality && ! sb_reality_ok; then
    if proto_on hy2; then
      sbreal_note=$'\n> **注意**: 本机服务端 Xray >= 26.9.8, REALITY 与 sing-box 内核不兼容\n> (上游 [SagerNet/sing-box#4520](https://github.com/SagerNet/sing-box/issues/4520),\n> 换指纹 / 关 uTLS 都无效)。这份 routed.json 的默认出口已切到 HY2(能正常用);\n> 想走 REALITY 请把 v2rayN 内核换成 **Xray**, 再导入 `v2rayn.txt`。\n> `clash.yaml`(mihomo)与 xray 内核客户端不受影响。\n'
    else
      sbreal_note=$'\n> **注意**: 本机服务端 Xray >= 26.9.8, REALITY 与 sing-box 内核不兼容\n> (上游 [SagerNet/sing-box#4520](https://github.com/SagerNet/sing-box/issues/4520),\n> 换指纹 / 关 uTLS 都无效)。当前**未启用 HY2**, routed.json / singbox.json 的默认出口\n> 无可切换, 导入后不会通。请改用 `clash.yaml`(mihomo 内核)或 `v2rayn.txt`(xray 内核);\n> 或者启用 HY2 后重新执行 `proxy sub` 让默认出口自动切到 HY2。\n'
    fi
  fi

  # 条件生成的订阅文件不能在指南里无条件推荐 —— 用户按图导入只会 404。
  local safe_note="" sb_rank_note=""
  if [ -z "$safe_links" ]; then
    safe_note=$'\n> 注意: 当前未启用 REALITY / SS2022, `v2rayn-safe.txt` 不会生成, 跳过第 ② 项 / 第 1 步即可。\n'
  fi
  if [ "${SB_REALITY_ONLY:-0}" = "1" ]; then
    sb_rank_note=$'\n> 注意: 当前 REALITY 与 sing-box 内核不兼容且未启用 HY2, 第 ① / ③ 项不可用, 请改用 `clash.yaml` 或 `v2rayn.txt`。\n'
  fi

  cat > "$tdir/client-guide.md" <<GUIDE
# 客户端配置指南

节点: ${SERVER_IP}${gsum}
伪装域名: ${DEST}

## 一、证书与指纹

Hysteria2 用自签证书: 必须 **跳过 CA 校验 + 固定指纹** 一起做 —— 前者让连接建立,
后者保证对端真是这台服务器。指纹只能来自本机, 链路上换不了。这是官方
\`hysteria cert\` 的标准配置(\`insecure: true\` + \`pinSHA256\` 同时出现)。

| 客户端 | 填法 |
|---|---|
| 官方客户端 / 小火箭 / Stash | 用带 pinSHA256 的链接(已含 insecure=1) |
| sing-box 1.13+ | tls.certificate_public_key_sha256 填 SPKI(base64) |
| mihomo / Clash Verge | skip-cert-verify: false + fingerprint 填 hex |
| v2rayN 新版 7.x | 识别 pinSHA256, 导入后存成证书指纹; 界面"跳过证书验证"是单选项, 不代表 pin 失效 |
| 老版 v2rayN | 用无 pin 兼容链接(能连但无固定), 升级即可 |

新版已支持 pinSHA256(官方 issue #7866/#10433/#10434), 早期教程说不识别已过时。
注意链接里的 \`fp=chrome\` 是 uTLS 指纹, 不是证书指纹。

**推荐顺序**: ① \`v2rayn-routed.json\`(自带完整防护); ② \`v2rayn-safe.txt\`
(纯节点, 无"跳过验证"提示, 只 REALITY/SS2022); ③ \`singbox.json\`; ④ \`v2rayn.txt\`
主链接。\`clash.yaml\` 只有 HY2 带 fingerprint, AnyTLS/TUIC 仍是 skip-cert-verify,
不能当成"整份已固定证书"。弹"不安全"提示是正常的, 别去勾"默认跳过证书验证"。
${safe_note}${sb_rank_note}

Hysteria2 链接(带 pin): ${HY2_LINK:-当前未生成}
无 pin 兼容链接(老 v2rayN): ${HY2_LINK_COMPAT:-${HY2_LINK:-当前未生成}}
pinSHA256 (hex): ${HY2_PIN:-未启用, 当前为 insecure}
SPKI (sing-box 用, base64): HY2=${CERT_SPKI_B64:-未计算} / AnyTLS+TUIC=${SB_PIN:-未计算}

## 二、TUN 四件事(出问题按顺序查)

1. MTU 填 1500 —— 默认 9000 在家宽会被丢弃, 症状是"连上但打不开网页"。
2. 关严格路由 —— 开着时出站一断整机断网。
3. 管理员运行 —— 没权限建不了虚拟网卡, 且系统代理已被关掉, 变双重断网。
4. DNS 用订阅里的那份, 别另配 —— 订阅已设好 fake-ip + 国内 DoH 引导。

卡住时(Windows): \`ping 1.1.1.1\`(通=DNS 问题, 不通=网卡/路由) →
\`ipconfig /all\`(有无 TUN 网卡) → \`route print\`(默认路由) → \`nslookup www.baidu.com\`。

### Reality 单独连不上、Hysteria2 却能用
IP 没被整体封, 问题在 TCP/TLS 层。每步只改一处:
1. 版本: 脚本默认追最新版(\`xray version\` 看实际), 升级后才断用 \`proxy upgrade --rollback\`。
   新版服务端与不带 MLKEM 的客户端可能对不上(issue #6873), 是客户端指纹侧问题。
2. 指纹: \`REALITY_FP=firefox proxy sub\` 换指纹后重导订阅, 跑 \`proxy selftest\` 验证。
3. 伪装站: \`REALITY_DEST=random bash /root/setup-proxy.sh install\`, 客户端重导链接。
4. 端口: \`VLESS_PORT=8443 HY2_PORT=443 bash /root/setup-proxy.sh install\`, 放行云安全组。
5. 都不行: \`DEFAULT_NODE=hy2 proxy sub\` 先走 UDP 链路。

## 三、Windows: v2rayN

**首选：导入 \`v2rayn-routed.json\`（自带完整防护，免手动核对）**
${sbreal_note}

v2rayN 新版内置 sing-box 内核, 导入后自带 DNS 分流(国内走国内 DoH、境外走加密
DoH 经隧道) + STUN/WebRTC 拦截 + "未列域名全代理"兜底, 与小火箭/Clash 一致。
Claude 的第三方域名(intercom/datadog/stripe/sentry 等)全程走代理, 不会从真实
IP 直连。开 TUN 即可, route.final 已指向代理出口, 不用手动配分流。

若坚持纯节点链接(格式本身不含 DNS 字段), 七项必须逐条核对, 漏一项就可能泄露:
1. 用 \`v2rayn-safe.txt\` 别用 base64.txt(只 REALITY/SS2022, 不弹"不安全")。${safe_note}
2. TUN: MTU 1500, 关严格路由, wintun.dll 放在 bin\\sing_box\\, 管理员运行。
3. 直连 DNS 填 223.5.5.5; 远程 DNS 填 \`https://1.1.1.1/dns-query\`; Bootstrap 填 IP。
4. 代理目标解析策略保持 **Default** —— 改成 UseIP/UseIPv4 就变本地解析, 即送中。
5. 路由域名解析策略选 **IPIfNonMatch**, 不要 AsIs(会让 geoip:cn 失效, 国内站绕出国)。
6. 路由模式选 **绕过大陆**, 不要全局(全局会让国内站打不开)。
7. TUN 下系统代理选"不改变系统代理", 避免重复代理。

## 四、送中 / DNS / 客户端

"送中"= Google 把你当中国大陆用户, 根因是客户端先本地解析了域名 —— 系统 DNS
拿到国内 CDN IP, 服务端只能连那个 IP, Google 看到的对端就成了国内节点。

订阅已配好: \`dns.enhanced-mode: fake-ip\`(Clash)/ \`dns.final: remote\`(sing-box)
让真域名原样送服务端解析; \`ipv6: false\` 防 AAAA 绕过。**别在客户端改回去**。
Clash 必须用 **mihomo 内核**(旧版不支持 fake-ip, 会静默回退系统 DNS)。

小火箭: 先导 \`base64.txt\`(节点), 再导 \`shadowrocket.conf\`(配置, 长按「使用配置」),
首页「全局路由」选「配置」。它已配好:
\`FINAL,PROXY,force-remote-dns\`(境外域名不在本地解析, 服务端解析, 是防泄露主力)、
\`dns-server = 国内 DoH\`(国内直连域名如抖音/淘宝解析到国内 CDN 节点, 开 VPN 也能刷抖音)、
\`stun-response-ip = 你的VPS出口IP\`(WebRTC 应答填真实出口, 与代理出口一致, 属地检测不再误报泄露)、STUN 域名 REJECT-NO-DROP、关 IPv6/QUIC。
抖音走国内 DNS、TikTok 走境外 DNS, 两端互不干扰。
只有纯节点链接才需手动核对七项(配置→通用 DNS 覆写留空或国内 DNS、关 IPv6、
禁 STUN、开 UDP 转发、指纹默认、私有 IP 应答开、全局路由选「配置」)。

sing-box 用 \`singbox.json\`(1.13+)/ \`singbox-compat.json\`(1.12)。

**浏览器自带的"安全 DNS"必须关掉**(Chrome/Edge Secure DNS、Firefox、Safari),
否则会绕过 fake-ip 把域名解析成国内 CDN IP。

#### 连上之后自己验一次 DNS 有没有漏
\`dnsleaktest.com\`(Extended) / \`ipleak.net\`(Extended) / \`browserleaks.com/webrtc\`。
只出现境外解析器正常; 出现国内运营商 DNS 或真实 IP 就是有请求绕过代理。
判定 Google 地区拿出口国家做基准, 别见 \`google.com.hk\` 就报送中。
\`proxy audit\` 只看服务端侧; \`proxy dnstest\` 验三端订阅的 DNS 配置、DoH 端点能否
真解析、出口是否同源。客户端到底用了哪个 DNS 服务端测不到, 最后仍要自己跑一次
dnsleaktest。

## 五、判机房与风控

机房 IP 是数据中心的注册属性, 双线 ISP 也改不了 —— ping0.cc 之类按 ASN 类型 /
IP 段历史 / PTR / 地理一致性判定。改不了的还有共享 IP 历史 / 浏览器指纹 /
账号行为 / SIM+GPS+语言时区。唯一技术解是让出口不是机房 IP:
\`proxy egress socks5://用户:密码@住宅机IP:1080\`(动态 IP 配 DDNS, 两跳延迟升,
上游挂了不自动回落以防暴露; WARP 段同样被标机房)。
只对 reality / anytls / tuic 生效: hysteria2 由独立的 hysteria 进程承载,
不吃 xray/sing-box 的 outbounds, 它的流量仍从本机 IP 直出。

### Claude / Anthropic: 风控看什么
没有任何脚本能保证不封号, 能做的是把可控信号收拾干净。**最易触发封号是真实 IP
短暂暴露**(代理断几秒、大陆 IP 漏出)。用配置模式就不用切全局。

网传"Claude 域名清单"是给"只代理列名域名、其余直连"的配置用的 —— 那种漏一个
就从真实 IP 出去。本订阅反过来: \`FINAL,PROXY,force-remote-dns\` 是"除国内白名单
外全部走代理", 这批第三方域名一个都不用列就全在代理里。**只有纯节点链接才需切
全局兜底**, 这也是前面强烈建议用 \`v2rayn-routed.json\` 的原因。

**别照抄清单里的 IP-CIDR 规则**(如 \`IP-CIDR,34.8.0.0/16,PROXY\`): 域名撞 IP 规则
会先查本地 DNS 判断 IP, 正好泄露给运营商; 加 no-resolve 又会让域名跳过该规则,
等于白写。靠兜底代理覆盖即可。

**TikTok 域名不用单独列**: 兜底全代理已把所有非白名单域名钉在同一出口、DNS 走
境外。真正决定风控的是 SIM 卡地区 / GPS / 系统语言时区 / 出口 IP 是否机房段。

API 用户: 官方 SDK 走代理时要连 DNS 一起代理, 否则 API 走代理、域名解析在本地,
同样露真实位置。时区语言跟节点地区一致。
GUIDE
  chmod 644 "$tdir/client-guide.md"

  # 订阅目录里是全部节点凭据, 生成阶段一律 700/600。需要给订阅服务(nobody)
  # 读时, 由 maybe_sub_http 在 wait_active 通过之后再放开 —— 那里才知道服务
  # 是否真的起来了。
  chmod 700 "$tdir"
  find "$tdir" -type f -exec chmod 600 {} + 2>/dev/null
  # SUB_HTTP=1 时服务以 nobody 运行: 把属主交给 nobody, 权限保持 700/600。
  # 以前用 755/644 放开, 等于把 UUID/密码开放给同机所有用户(无需 token)。
  # root 无视权限仍可维护; 这里先收紧, maybe_sub_http 确认服务起来后再定属主。
  if [ "${SUB_HTTP:-0}" = "1" ]; then
    chown -R nobody "$tdir" 2>/dev/null \
      || warn "无法把订阅目录交给 nobody, 订阅服务可能读不到文件"
  fi
  SUB_TOKEN_DIR="$tdir"
  # 写盘统一校验: 上面多处是 `{ ... } > file` 重定向, 磁盘满 / 权限问题时
  # bash 不会自己报错中止, 结果是半份订阅被当成成功分发出去。
  local _sub_bad=""
  [ -s "$tdir/links.txt" ]  || _sub_bad="${_sub_bad} links.txt"
  [ -s "$tdir/base64.txt" ] || _sub_bad="${_sub_bad} base64.txt"
  [ -s "$tdir/v2rayn.txt" ] || _sub_bad="${_sub_bad} v2rayn.txt"
  sub_yaml_ok "$tdir/clash.yaml"            || _sub_bad="${_sub_bad} clash.yaml"
  sub_json_ok "$tdir/singbox.json"          || _sub_bad="${_sub_bad} singbox.json"
  sub_json_ok "$tdir/singbox-compat.json"   || _sub_bad="${_sub_bad} singbox-compat.json"
  # v2rayN 首选文件必须一起验: 漏了它就会出现"全绿但客户端 404"。
  sub_json_ok "$tdir/v2rayn-routed.json"    || _sub_bad="${_sub_bad} v2rayn-routed.json"
  sub_shadowrocket_ok "$tdir/shadowrocket.conf" || _sub_bad="${_sub_bad} shadowrocket.conf"
  # 这两份也在订阅白名单里、指南也推荐导入: 漏验就会出现"全绿但客户端 404"。
  # client-guide.md 是这段最后写、体积最大的文件, 磁盘满时最容易留下半截。
  [ -s "$tdir/client-guide.md" ] || _sub_bad="${_sub_bad} client-guide.md"
  if [ -n "$safe_links" ] && [ ! -s "$tdir/v2rayn-safe.txt" ]; then
    _sub_bad="${_sub_bad} v2rayn-safe.txt"
  fi
  [ -z "$_sub_bad" ] || die "订阅文件生成后校验失败:${_sub_bad} —— 检查磁盘空间与 ${tdir} (proxy sub 可重试)"
  ok "订阅文件已生成: ${tdir}"
}

maybe_sub_http(){
  if [ "$SUB_HTTP" != "1" ]; then
    # 之前开过 HTTP 订阅、这次关了: 必须真的把服务停掉。不停的话端口还开着,
    # 而订阅目录已经收紧到 700, 服务只会一直回 403 —— 用户以为关了, 实际
    # 还占着一个公网端口。只在它确实在跑/被 enable 时才提示, 避免每次 sub 都刷屏。
    if [ -f /etc/systemd/system/proxy-sub.service ]; then
      if systemctl is-active --quiet proxy-sub 2>/dev/null \
         || systemctl is-enabled --quiet proxy-sub 2>/dev/null; then
        systemctl disable --now proxy-sub >/dev/null 2>&1 \
          && warn "已停用订阅 HTTP 服务 (SUB_HTTP=0, 端口已释放)"
      fi
    fi
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    warn "未安装 python3, 跳过订阅 HTTP 服务"
    return 0
  fi
  # token 现在会作为服务端的硬校验下发。为空时宁可不启动, 也别起一个"所有请求
  # 都 404"的服务让人以为是配置坏了。正常情况下 gen_sub_files 已先生成好。
  if [ -z "${SUB_TOKEN:-}" ]; then
    warn "订阅 token 为空, 跳过启动订阅 HTTP 服务(先执行一次: ${APP_NAME} sub)"
    return 0
  fi
  if [ -z "${SUB_PORT:-}" ]; then
    # 随机端口也要避开已占用的: 撞上了服务起不来, 报错却指向"python 失败"。
    # 这条路径只影响老机器(state 里没记 SUB_PORT), 新装已在 validate_ports
    # 之前就定好端口并参与冲突检查。
    local _try=0
    while [ "$_try" -lt 10 ]; do
      SUB_PORT=$(( (RANDOM % 10000) + 30000 ))
      port_in_use "$SUB_PORT" tcp || break
      SUB_PORT=""; _try=$((_try + 1))
    done
    [ -n "${SUB_PORT:-}" ] || die "无法自动挑选空闲的订阅端口, 请显式指定: SUB_PORT=xxxx ${APP_NAME} sub"
    warn "订阅端口未记录在 state, 本次随机用 ${SUB_PORT}; 云安全组/防火墙需自行放行"
  fi
  # SUB_BIND / SUB_TOKEN 都在这里卡过格式, 唯独 SUB_PORT 没有 —— 它会拼进
  # systemd 的 ExecStart, 带空格就会拆成多个参数, 服务静默起不来。
  valid_port "$SUB_PORT" || die "SUB_PORT='${SUB_PORT}' 不是合法端口, 请重新执行: ${APP_NAME} sub"

  # 不能用 python3 -m http.server: 它会在根路径返回目录列表, 而目录名就是订阅
  # token —— 任何人扫到这个端口, GET / 一次就把全部凭据拿走了。
  # 换成只认 /<token>/<已知文件名> 的小服务, 其余一律 404, 不列目录。
  # 监听地址会拼进 ExecStart, 先卡死格式(也可能来自被手改过的 state.env)
  if ! valid_bind "$SUB_BIND"; then
    warn "SUB_BIND='${SUB_BIND}' 不是合法监听地址, 改用 127.0.0.1"
    SUB_BIND="127.0.0.1"
  fi
  # token 不能明文留在 unit 里: systemctl cat / /proc/<pid>/environ 对同机
  # 普通用户可读。改成 0600 的 EnvironmentFile, 由 systemd(PID 1, root)读取。
  case "$SUB_TOKEN" in
    ''|*[!A-Za-z0-9_-]*) die "订阅 token 含非法字符, 请重新执行: ${APP_NAME} sub" ;;
  esac
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  # EnvironmentFile 前带 "-"(缺失也继续), 写失败时服务会以空 token 启动,
  # 所有请求 404, 而 wait_active 只看进程活着, 照样报"已启动"。
  { printf 'SUB_TOKEN=%s\nSUB_ROOT=%s\n' "$SUB_TOKEN" "$SUB_DIR" > "$STATE_DIR/sub.env"; } \
    || die "写入 ${STATE_DIR}/sub.env 失败(磁盘满/权限?), 订阅服务未启动"
  chmod 600 "$STATE_DIR/sub.env" || die "无法收紧 sub.env 权限, 拒绝以明文 token 启动服务"

  local srv=/usr/local/lib/proxy-sub/server.py
  mkdir -p /usr/local/lib/proxy-sub
  if ! cat > "$srv" <<'PYSRV'
#!/usr/bin/env python3
"""订阅服务: 只响应 /<token>/<已知文件名>, 其余一律 404, 绝不列目录。

替代 python3 -m http.server —— 后者会在 "/" 返回目录列表, 而目录名就是 token。
"""
import os
import sys
import socket
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.realpath(os.environ.get("SUB_ROOT", "/var/www/proxy-sub"))
TOKEN = os.environ.get("SUB_TOKEN", "")
ALLOW = {
    "clash.yaml", "singbox.json", "singbox-compat.json",
    "base64.txt", "v2rayn.txt", "v2rayn-safe.txt", "v2rayn-routed.json", "links.txt", "client-guide.md",
    "shadowrocket.conf",
}


class Handler(BaseHTTPRequestHandler):
    server_version = "sub"
    sys_version = ""
    # 默认是 HTTP/1.0(每请求一次连接)。1.1 + Content-Length 才能复用连接,
    # 部分订阅客户端对 1.0 响应处理得不好。
    protocol_version = "HTTP/1.1"
    # 每个连接最多占 30 秒。默认 timeout 是 None —— 只发半行请求就沉默的客户端
    # 会让线程永远挂在 rfile.readline 上。服务用的是 ThreadingHTTPServer, 一个
    # 连接一个线程, 几百个半开连接就能把这个进程的内存吃光, 而它监听在公网上。
    # 超时后标准库自己会关连接(handle_one_request 捕获 TimeoutError), 不必额外处理。
    timeout = 30

    def do_GET(self):
        parts = [p for p in self.path.split("?", 1)[0].split("/") if p]
        # 必须正好两段, 且第一段不能是 . / .. (防目录穿越)
        if len(parts) != 2 or parts[0] in (".", "..") or parts[1] not in ALLOW:
            self.send_error(404)
            return
        # token 必须真的等于本次订阅目录名。只靠"目录名难猜"不够:
        # 订阅根目录下若还有别的子目录, 里面的同名文件也会被读到。
        # 比的是 bytes 不是 str: hmac.compare_digest 对含非 ASCII 字符的 str
        # 直接抛 TypeError, 请求路径里塞一个 %C3%A9 就能把一次 404 变成一次
        # 未捕获异常(连接被直接掐断, 日志里一堆 traceback)。
        if not TOKEN or not hmac.compare_digest(
            parts[0].encode("utf-8", "surrogateescape"),
            TOKEN.encode("utf-8", "surrogateescape"),
        ):
            self.send_error(404)
            return
        full = os.path.realpath(os.path.join(ROOT, parts[0], parts[1]))
        if not full.startswith(ROOT + os.sep):
            self.send_error(404)
            return
        try:
            with open(full, "rb") as fh:
                body = fh.read()
        except OSError:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 30800
    bind = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    # valid_bind 允许 :: / IPv6 字面量, 但 HTTPServer 默认 AF_INET —— 绑 ::
    # 会直接 gaierror 退出, 脚本却只报"启动失败已跳过"且 state 仍记 SUB_HTTP=1。
    if ":" in bind:
        class IPv6Server(ThreadingHTTPServer):
            address_family = socket.AF_INET6
        srv = IPv6Server((bind, port), Handler)
    else:
        srv = ThreadingHTTPServer((bind, port), Handler)
    srv.serve_forever()


if __name__ == "__main__":
    main()
PYSRV
  then
    die "写入订阅服务 server.py 失败(磁盘满/只读?), 订阅服务不可用"
  fi
  chmod 644 "$srv" || die "无法设置 server.py 权限, 订阅服务不可用"

  if ! cat > /etc/systemd/system/proxy-sub.service <<EOF
[Unit]
Description=Proxy Subscription HTTP
After=network.target

[Service]
Type=simple
# 只读地发几个静态文件, 没有任何理由用 root 跑
User=nobody
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
# 允许绑 1024 以下的端口(用户把 SUB_PORT 设成 80/443 时), 其余能力一律不要
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=${SUB_DIR}
EnvironmentFile=-${STATE_DIR}/sub.env
ExecStart=$(command -v python3) ${srv} ${SUB_PORT} "${SUB_BIND}"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  then
    die "写入 proxy-sub.service 失败(磁盘满/只读?), 订阅服务不可用"
  fi
  systemctl daemon-reload || warn "proxy-sub daemon-reload 失败, 新单元可能未生效"
  enable_unit proxy-sub
  systemctl restart proxy-sub >/dev/null 2>&1
  # python3 冷启动 + ProtectSystem=strict 的沙箱准备, 1 秒经常不够;
  # 判早了就会打印"启动失败"并给出排错指引, 而服务其实马上就起来了。
  if wait_active proxy-sub; then
    # 服务以 nobody 运行, 需要能穿过 $SUB_DIR 并读 token 目录里的文件。
    # 以前用 755/644 放开 —— 同机任意用户都能直接读 links.txt 里的全部
    # UUID/密码, token 形同虚设。改成"属主给 nobody, 权限保持 700/600":
    # nobody 能读, 其它本地用户进不去; root 仍可正常维护。
    chmod 700 "$SUB_DIR" 2>/dev/null \
      || die "订阅目录权限收紧失败(${SUB_DIR})"
    chown nobody "$SUB_DIR" 2>/dev/null \
      || die "订阅目录属主设置失败(${SUB_DIR}), nobody 服务将无法进入"
    if [ -n "${SUB_TOKEN_DIR:-}" ] && [ -d "$SUB_TOKEN_DIR" ]; then
      chmod 700 "$SUB_TOKEN_DIR" 2>/dev/null \
        || die "订阅凭据目录权限收紧失败, 订阅链接将无法访问"
      chown -R nobody "$SUB_TOKEN_DIR" 2>/dev/null \
        || die "订阅凭据文件属主设置失败, nobody 服务将无法读取"
      find "$SUB_TOKEN_DIR" -type f -exec chmod 600 {} + 2>/dev/null \
        || die "订阅文件权限收紧失败, 订阅链接将无法访问"
    fi
    ok "订阅服务已启动: ${SUB_BIND}:${SUB_PORT}"
    if [ "$SUB_BIND" = "127.0.0.1" ]; then
      echo -e "${D}仅监听本机, 取订阅请先建 SSH 隧道:${N}"
      echo -e "${D}  ssh -N -L ${SUB_PORT}:127.0.0.1:${SUB_PORT} root@${SERVER_IP:-<服务器IP>}${N}"
      echo -e "${D}  然后访问 http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN:-<token>}/clash.yaml${N}"
    else
      warn "订阅服务已对 ${SUB_BIND} 开放: token 即凭据, 请勿外传"
    fi
    echo -e "${D}停用: systemctl disable --now proxy-sub${N}"
  else
    warn "订阅服务启动失败, 已跳过"
  fi
}

# ---------------- 输出 ----------------
# 把节点信息写到 /root/proxy-info.txt
# 只写当前真正启用的协议: 以前是固定模板, 单开 hy2 时也会出现 VLESS 段,
# 而 SS2022 / AnyTLS / TUIC 反而完全不出现。
write_info_file(){
  local pu="${PRIMARY_UUID:-$UUID}" dn
  {
    echo "=========== 节点信息 ==========="
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "服务器 IP: ${SERVER_IP}"
    echo "启用协议: ${PROTOCOLS}"
    # 伪装目标单独一行, 不跟着某个协议走: 所有协议共用同一个 DEST, 只写一次既够用
    # 又不会在开了四协议时重复四遍。带上"这是什么站", 是因为池子里一半域名普通用户
    # 不认识, 而这一行抄错只会得到"连接超时", 客户端不会告诉他是 SNI 的问题。
    # 用户自己指定 REALITY_DEST 时 dest_note 取不到说明 —— 那种情况下括号里就不写,
    # 但"必须一字不差"这两行照常输出: 自定义域名更容易抄错, 更需要这句提醒。
    if [ -n "${DEST:-}" ]; then
      dn=$(dest_note "$DEST" 2>/dev/null) || dn=""
      echo "伪装目标: ${DEST}${dn:+  (${dn})}"
      echo "          所有协议共用这一个 SNI, 必须与客户端一字不差;"
      echo "          抄错不会报 SNI 错误, 只会表现为连接超时或握手失败。"
    fi
    echo
    if proto_on reality; then
      echo "[VLESS + REALITY]  TCP ${VLESS_PORT}"
      echo "UUID     : ${pu}"
      echo "Flow     : xtls-rprx-vision"
      echo "SNI      : ${DEST}"
      echo "pbk      : ${PUB}"
      echo "shortId  : ${SID}"
      echo "fp       : ${REALITY_FP:-chrome}"
      echo "链接     : ${VLESS_LINK}"
      echo
    fi
    if proto_on hy2; then
      echo "[Hysteria2]  UDP ${HY2_PORT}"
      echo "密码     : ${HY2_PASS}"
      echo "SNI      : ${DEST}"
      if [ -n "${HY2_PIN:-}" ]; then
        # HY2_PIN 就是整证书的 SHA-256 hex, mihomo 的 fingerprint 填同一个值
        echo "证书固定 : 已启用"
        echo "指纹     : ${HY2_PIN}"
        echo "           (链接里的 pinSHA256 与 mihomo 的 fingerprint 都填这一行)"
        echo "SPKI     : ${CERT_SPKI_B64:-未计算}   (sing-box 的 certificate_public_key_sha256 用这行)"
      else
        echo "insecure : 1   (已显式关闭证书固定)"
      fi
      [ -n "${HY2_HOP:-}" ] && echo "端口跳跃 : ${HY2_HOP}"
      [ "$ENABLE_OBFS" = "1" ] && echo "混淆     : salamander / ${OBFS_PASS}"
      echo "链接     : ${HY2_LINK}"
      [ -n "${HY2_LINK_COMPAT:-}" ] && echo "老版v2rayN: ${HY2_LINK_COMPAT}  (不识别 pin 的老版本用, 无证书固定)"
      echo
    fi
    if proto_on ss2022; then
      echo "[Shadowsocks-2022]  TCP+UDP ${SS2022_PORT}"
      echo "加密方式 : 2022-blake3-aes-128-gcm"
      echo "服务端密钥: ${SS2022_PASS:-未设置}"
      echo "设备密码 : $(ss_pass_for "$pu")   (服务端密钥:设备密钥)"
      echo "链接     : ${SS_LINK}"
      echo
    fi
    if proto_on anytls; then
      echo "[AnyTLS]  TCP ${ANYTLS_PORT}"
      echo "SNI      : ${DEST}"
      echo "密码     : $(derive_hex "$pu")"
      echo "SPKI     : ${SB_PIN:-未计算}   (订阅 singbox.json 里已固定, 链接只能 insecure)"
      echo "链接     : ${ANYTLS_LINK}"
      echo
    fi
    if proto_on tuic; then
      echo "[TUIC v5]  UDP ${TUIC_PORT}"
      echo "UUID     : ${pu}"
      echo "密码     : $(derive_hex "$pu")"
      echo "SNI      : ${DEST}"
      echo "SPKI     : ${SB_PIN:-未计算}   (订阅 singbox.json 里已固定, 链接只能 insecure)"
      echo "链接     : ${TUIC_LINK}"
      echo
    fi
    echo "[管理]"
    echo "proxy info | dest | name | sub | status | verify | restart | logs | audit"
    echo "proxy user | reset | backup | upgrade | optimize | timezone | wizard | clean"
    echo "订阅目录: ${SUB_TOKEN_DIR:-${SUB_DIR}}"
  } 2>/dev/null > /root/proxy-info.txt || {
    warn "写入 /root/proxy-info.txt 失败, 其余步骤不受影响"
    return 0
  }
  # 这个文件含全部 UUID / 密码 / 订阅 token。chmod 失败会让它停在 umask 默认
  # 644, 同机其它用户可读, 不能再静默吞掉。
  chmod 600 /root/proxy-info.txt 2>/dev/null \
    || warn "无法收紧 /root/proxy-info.txt 权限, 其中的凭据可能被同机用户读取"
}

# 在 SNI 那一行下面补一句"这是什么站"。终端里是彩色 + 缩进, 和 write_info_file 里
# 的纯文本版本分开写: 那个要落盘, 不能带转义符。取不到说明就什么都不打(新域名没
# 补 dest_note 时不会在这里露一个空括号)。
print_dest_note(){
  local dn
  dn=$(dest_note "${DEST:-}" 2>/dev/null) || return 0
  echo -e "            ${D}(${dn}; 这一行必须与客户端一字不差)${N}"
}

print_links(){
  echo
  if proto_on reality; then
    hr
    echo -e "${M}VLESS + REALITY${N}   TCP ${VLESS_PORT}"
    hr
    # 必须显示当前生效的主 UUID(= users.txt 第一行), 不能显示 state.env 里的初始值:
    # 吊销首台设备后两者就不一样了, 照着旧值导入会连不上。VLESS_LINK 也是这个来源。
    echo "UUID      : ${PRIMARY_UUID:-$(primary_uuid)}"
    echo "Flow      : xtls-rprx-vision"
    echo "SNI       : ${DEST}"
    print_dest_note
    echo "公钥 pbk  : ${PUB}"
    echo "shortId   : ${SID}"
    echo "指纹 fp   : ${REALITY_FP:-chrome}"
    echo
    echo -e "${G}${VLESS_LINK}${N}"
    echo
  fi

  if proto_on hy2; then
    hr
    echo -e "${M}Hysteria2${N}   UDP ${HY2_PORT}"
    hr
    echo "密码      : ${HY2_PASS}"
    echo "SNI       : ${DEST}"
    # 只开了 hy2 没开 reality 时才补这一行: 两个都开的话上面 REALITY 段已经说过一次,
    # 同一个域名连说两遍是噪音。
    proto_on reality || print_dest_note
    if [ -n "${HY2_PIN:-}" ]; then
      echo -e "证书固定  : ${G}已启用${N} (pinSHA256, 证书 SHA-256)"
      echo "  指纹    : ${HY2_PIN}"
      echo -e "  ${D}链接里的 insecure=1 只负责跳过 CA 校验, 身份由 pinSHA256 校验${N}"
      echo "  mihomo  : fingerprint: ${HY2_PIN}"
    else
      echo -e "${Y}跳过证书验证: 开启 (insecure=1) —— 链路上可被冒充${N}"
    fi
    [ -n "${HY2_HOP:-}" ] && echo "端口跳跃  : ${HY2_HOP}"
    [ "$ENABLE_OBFS" = "1" ] && echo "混淆      : salamander / ${OBFS_PASS}"
    echo
    echo -e "${G}${HY2_LINK}${N}"
    if [ -n "${HY2_LINK_COMPAT:-}" ]; then
      echo
      echo -e "${D}老版 v2rayN(不识别 pinSHA256)可用这条兜底, 但无证书固定:${N}"
      echo -e "${D}${HY2_LINK_COMPAT}${N}"
    fi
    echo
  fi

  if proto_on ss2022; then
    hr
    echo -e "${M}Shadowsocks-2022${N}   TCP+UDP ${SS2022_PORT}"
    hr
    echo "加密方式  : 2022-blake3-aes-128-gcm"
    echo "服务端密钥: ${SS2022_PASS:-未设置}"
    echo "设备密码  : $(ss_pass_for "$(primary_uuid)")"
    echo -e "${D}  多用户模式: 客户端密码 = 服务端密钥:设备密钥, 链接里已拼好${N}"
    echo -e "${D}  每个设备一段不同的设备密钥, 用 proxy user link <名字> 取对应链接${N}"
    echo
    echo -e "${G}${SS_LINK}${N}"
    echo
  fi

  if proto_on anytls; then
    hr
    echo -e "${M}AnyTLS${N}   TCP ${ANYTLS_PORT}"
    hr
    echo "SNI       : ${DEST}"
    echo -e "${Y}自签证书: 分享链接只能 insecure; 订阅 singbox.json 真固定, singbox-compat.json 走 insecure${N}"
    echo
    echo -e "${G}${ANYTLS_LINK}${N}"
    echo
  fi

  if proto_on tuic; then
    hr
    echo -e "${M}TUIC v5${N}   UDP ${TUIC_PORT}"
    hr
    echo "UUID      : $(primary_uuid)"
    echo "SNI       : ${DEST}"
    echo -e "${Y}自签证书: 分享链接只能 insecure; 订阅 singbox.json 真固定, singbox-compat.json 走 insecure${N}"
    echo
    echo -e "${G}${TUIC_LINK}${N}"
    echo
  fi
}

print_qr(){
  command -v qrencode >/dev/null 2>&1 || return 0
  if proto_on reality && [ -n "${VLESS_LINK:-}" ]; then
    echo -e "${B}--- VLESS 二维码 ---${N}"
    qrencode -t ANSIUTF8 -m 1 "$VLESS_LINK" 2>/dev/null || true
    echo
  fi
  if proto_on hy2 && [ -n "${HY2_LINK:-}" ]; then
    echo -e "${B}--- Hysteria2 二维码 ---${N}"
    qrencode -t ANSIUTF8 -m 1 "$HY2_LINK" 2>/dev/null || true
    echo
  fi
  if proto_on ss2022 && [ -n "${SS_LINK:-}" ]; then
    echo -e "${B}--- SS2022 二维码 ---${N}"
    qrencode -t ANSIUTF8 -m 1 "$SS_LINK" 2>/dev/null || true
    echo
  fi
}

print_sub_info(){
  echo
  hr
  echo -e "${M}订阅文件${N}"
  hr
  echo "目录: ${SUB_TOKEN_DIR:-${SUB_DIR}}"
  echo "  links.txt      原始链接(每条节点一行)"
  echo "  base64.txt     通用订阅, 小火箭 / v2rayN / v2rayNG 可直接导入"
  echo "  clash.yaml       Clash / mihomo / Clash Verge (含 fake-ip)"
  echo "  singbox.json     sing-box 1.13+ (含证书指纹固定)"
  echo "  singbox-compat.json  sing-box 1.12 (DNS 格式相同, 证书走 insecure)"
  echo "  shadowrocket.conf iOS 小火箭专用 (DNS 已配好走代理, 导入即用)"
  echo -e "  ${G}v2rayn-routed.json v2rayN 首选 (sing-box 内核导入, 自带 DNS分流+STUN拦截+全代理)${N}"
  echo "  v2rayn.txt       v2rayN 兼容版 (纯节点链接, 含 HY2/AT/TUIC, 会提示不安全)"
  # 只开 hy2/anytls/tuic 时 gen_sub_files 不会生成 safe 订阅, 列出来会 404
  if proto_on reality || proto_on ss2022; then
    echo "  v2rayn-safe.txt  v2rayN 纯链接版 (只含 REALITY/SS2022, 无提示; 需自己配分流)"
  fi
  echo "  client-guide.md  客户端配置指南(证书固定 / TUN / 提速 / 排障)"
  echo -e "  ${Y}注意: links.txt / base64.txt / v2rayn*.txt 是纯节点列表, 本身不带 DNS 配置;${N}"
  echo -e "  ${Y}      这是分享链接格式的限制(URI 标准没有 DNS 字段), 不是漏做。${N}"
  echo -e "  ${G}      小火箭(iOS)直接导入 shadowrocket.conf: DNS 已配好走隧道 + 境外域名远端解析, 导入即用;${N}"
  echo -e "  ${Y}      其它客户端要开箱即用的 DNS 防泄露, 导入 clash.yaml / singbox.json(已配好 fake-ip);${N}"
  echo -e "  ${Y}      用纯节点列表手动导入时, 需在客户端自己开 fake-ip、关 IPv6, 否则等于没防泄露。${N}"
  echo "  默认节点     : $(effective_default_node) (DEFAULT_NODE=hy2 proxy sub 可切到 UDP 提速)"
  # 和 selftest 用同一套合法性判断: state.env 被手改成 abc 时订阅实际按默认
  # BBR 生成, 这里不能显示 "Brutal 已启用 up=abc" 骗人。
  local _biu="${HY2_BW_UP:-}" _bid="${HY2_BW_DOWN:-}"
  if [ -n "$_biu" ] && ! hy2_bw_ok "$_biu"; then _biu=""; fi
  if [ -n "$_bid" ] && ! hy2_bw_ok "$_bid"; then _bid=""; fi
  if [ -n "$_biu" ] || [ -n "$_bid" ]; then
    echo -e "  ${G}Brutal 已启用${N}: up=${_biu:-未设} down=${_bid:-未设} Mbps (clash.yaml / singbox*.json)"
  else
    echo -e "  ${D}提示: 大流量慢可开 Hysteria2 Brutal, 见 README「速度与调优」${N}"
  fi
  if [ "$SUB_HTTP" = "1" ] && [ -n "${SUB_PORT:-}" ] && [ -n "${SUB_TOKEN:-}" ]; then
    echo
    if [ "${SUB_BIND:-127.0.0.1}" = "127.0.0.1" ]; then
      echo "订阅服务(仅监听本机), 先在本地建隧道:"
      echo "  ssh -N -L ${SUB_PORT}:127.0.0.1:${SUB_PORT} root@${SERVER_IP}"
      echo "  Clash   : http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}/clash.yaml"
      echo "  通用    : http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}/base64.txt"
      echo "  singbox : http://127.0.0.1:${SUB_PORT}/${SUB_TOKEN}/singbox.json"
    else
      echo "订阅服务(${SUB_BIND}:${SUB_PORT}, 需安全组放行 TCP ${SUB_PORT}):"
      echo "  Clash   : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/clash.yaml"
      echo "  通用    : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/base64.txt"
      echo "  singbox : http://${SERVER_IP}:${SUB_PORT}/${SUB_TOKEN}/singbox.json"
    fi
  else
    echo
    echo -e "${D}未启用 HTTP 订阅。用 FinalShell 文件面板把需要的文件下载到本机导入即可。${N}"
  fi
  echo
}

# 用订阅里同一套生成逻辑起一个临时 sing-box 客户端, 实测某个协议能不能通。
# 关键在于"用用户真正会导入的那份配置": 另写一套测试配置的话,
# 订阅生成与服务端不一致的问题(hy2 混淆漏写 / 端口跳跃漏写)永远测不出来。
selftest_sb_proto(){
  # 返回码: 0 通 / 1 不通 / 2 缺 sing-box 客户端 / 3 订阅配置有问题 /
  #         4 临时目录都建不出来。分开报, 别把"配置生成失败"说成"缺 sing-box"。
  local proto="$1" tmp rc pid ip_re
  [ -x "$SB_BIN" ] || return 2
  tmp=$(mktemp -d 2>/dev/null) || return 4
  ( PROTOCOLS="$proto"; write_sb_client pinned "$tmp/c.json" ) >/dev/null 2>&1 \
    || { rm -rf "$tmp"; return 3; }
  # 本机连自己的公网 IP 依赖 hairpin NAT, 不少商家不支持 —— 直接改走回环。
  # 端口也从 2080 挪开, 避免和用户本机已有客户端撞车。
  # IP 里的点要转义, 否则正则里的 . 会匹配到别的地址。
  ip_re="${SERVER_IP//./\\.}"
  sed -i "s/\"server\": \"${ip_re}\"/\"server\": \"127.0.0.1\"/g" "$tmp/c.json" 2>/dev/null
  sed -i 's/"listen_port": 2080/"listen_port": 20801/' "$tmp/c.json" 2>/dev/null
  # 一个都没替换到 = 配置里的 server 不是这个 IPv4(IPv6 / 域名 / 生成异常),
  # 那就还在测公网 IP, hairpin 不通会被误报成"协议不通"。
  if [ -n "${SERVER_IP:-}" ] \
     && grep -qF "\"server\": \"${SERVER_IP}\"" "$tmp/c.json" 2>/dev/null; then
    rm -rf "$tmp"; return 3
  fi
  "$SB_BIN" run -c "$tmp/c.json" >"$tmp/log" 2>&1 &
  pid=$!
  # 等客户端把 SOCKS 端口监听上再发请求。固定 sleep 2 在慢机器上不够, 而端口
  # 还没起来时 curl 会立刻拿到 000(连接被拒), 结论却印成"不通" —— 把"还没起来"
  # 误报成"协议坏了", 方向完全相反。端口一上来就往下走, 正常情况下比 2 秒更快。
  local _p=0
  while [ "$_p" -lt 25 ] && ! (exec 3<>/dev/tcp/127.0.0.1/20801) 2>/dev/null; do
    sleep 0.2; _p=$((_p + 1))
  done
  rc=$(curl -s --socks5-hostname 127.0.0.1:20801 -o /dev/null -w '%{http_code}' \
       --max-time 12 http://cp.cloudflare.com/generate_204 2>/dev/null)
  kill "$pid" >/dev/null 2>&1
  # 不能裸 wait: 客户端忽略 TERM 时自检会永久挂起, 20801 端口也被占住,
  # 下一次自检又会因端口冲突误报"不通"。轮询 + KILL 兜底。
  local _w=0
  while kill -0 "$pid" 2>/dev/null && [ "$_w" -lt 20 ]; do
    sleep 0.2; _w=$((_w + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" >/dev/null 2>&1 || true; fi
  wait "$pid" 2>/dev/null || true
  # 已经拿到 200/204 就说明代理是通的, 日志里偶尔出现 FATAL 字样不该把它
  # 反过来判成"订阅配置非法"。
  case "$rc" in
    200|204) ;;
    *) grep -qi 'FATAL' "$tmp/log" 2>/dev/null && rc="cfg" ;;
  esac
  rm -rf "$tmp"
  case "$rc" in 200|204) return 0 ;; cfg) return 3 ;; *) return 1 ;; esac
}

# 逐个协议真连一次。返回不通的个数, 结果放在 SELFTEST_PASS/FAIL/SKIP/DETAIL。
# SKIP 单独留明细, 上层才能说清"到底哪个协议没测、为什么没测"。
selftest_protocols(){
  local pass=0 fail=0 skip=0 p detail=""
  SELFTEST_SKIP_DETAIL=""
  if proto_on reality; then
    printf '  %-10s ' "REALITY"
    if [ ! -x "$XRAY_BIN" ]; then
      printf '%s\n' "跳过(缺 xray)"; skip=$((skip + 1)); detail="${detail} REALITY(缺 xray)"
    elif verify_reality "${DEST:-}"; then
      printf '%b%s%b\n' "$G" "通" "$N"; pass=$((pass + 1))
    else
      printf '%b%s%b\n' "$R" "不通" "$N"; fail=$((fail + 1))
    fi
  fi
  for p in hy2 ss2022 anytls tuic; do
    proto_on "$p" || continue
    printf '  %-10s ' "$p"
    if [ "$p" = "hy2" ]; then
      # hy2 有自带的 hysteria 客户端, 别再依赖 sing-box —— 只开 reality+hy2
      # 时机器根本不装 sing-box, 旧代码因此永远把 hy2 报成"跳过", 默认组合
      # 的自检看起来永远没测完。verify_hy2 用的就是订阅那套凭据/证书固定,
      # 从 127.0.0.1 回环真连一次代理(安装时验证 pin 也是它), 语义一致。
      if [ ! -x "$HY2_BIN" ]; then
        printf '%s\n' "跳过(缺 hysteria 客户端)"
        skip=$((skip + 1)); detail="${detail} hy2(缺 hysteria 客户端)"
      elif verify_hy2 "${HY2_PIN:-}"; then
        printf '%b%s%b\n' "$G" "通" "$N"; pass=$((pass + 1))
      else
        printf '%b%s%b\n' "$R" "不通" "$N"; fail=$((fail + 1))
      fi
      continue
    fi
    selftest_sb_proto "$p"
    case $? in
      0) printf '%b%s%b\n' "$G" "通" "$N"; pass=$((pass + 1)) ;;
      2) printf '%s\n' "跳过(缺 sing-box 客户端)"; skip=$((skip + 1)); detail="${detail} ${p}(缺 sing-box 客户端)" ;;
      3) printf '%b%s%b\n' "$R" "订阅配置非法" "$N"; fail=$((fail + 1)) ;;
      4) printf '%s\n' "跳过(临时目录创建失败)"; skip=$((skip + 1)); detail="${detail} ${p}(临时目录创建失败)" ;;
      *) printf '%b%s%b\n' "$R" "不通" "$N"; fail=$((fail + 1)) ;;
    esac
  done
  SELFTEST_PASS=$pass; SELFTEST_FAIL=$fail; SELFTEST_SKIP=$skip
  SELFTEST_SKIP_DETAIL="${detail# }"
  return "$fail"
}

# 只读速度体检: 把"为什么慢"拆成能逐项核对的事实, 不改任何配置。
# 大多数"比别人的一键脚本慢"不是服务端配置差, 而是(1) 默认节点走 REALITY/TCP,
# 跨境丢包链路上抢不过 UDP; (2) Hysteria2 没开 Brutal; (3) 客户端把国内流量也塞进代理。
cmd_speed(){
  load_state 2>/dev/null || warn "未读到 state.env, 部分项会显示未知"
  apply_env_overrides

  echo -e "${M}速度与调优体检${N}"
  hr
  echo "[1] 内核网络参数(读的是真正生效的值, 不是配置文件里写了什么)"
  local cc qd
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
  qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
  printf '  拥塞控制     : %s\n' "${cc:-未知}"
  # sysctl 里的 default_qdisc 只是"默认值", 真正生效的队列要读 tc。两者不一致时
  # 打印实际值, 免得出现"配置写着 fq、实际还是 pfifo_fast"的假绿灯。
  local dev="" real_qd=""
  dev=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  # tc 输出形如 "qdisc fq_codel 0: root refcnt 2 ...": $2 是队列名, $4 才是 root。
  # 旧写法 $2=="root" 恒假, 这里永远打印 sysctl 的默认值 —— 正是假绿灯。
  [ -n "$dev" ] && real_qd=$(tc qdisc show dev "$dev" 2>/dev/null | awk '$1=="qdisc" && $4=="root"{print $2; exit}')
  printf '  队列规则     : %s\n' "${real_qd:-${qd:-未知}}${real_qd:+ (sysctl 值: ${qd:-未知})}"
  printf '  可用算法     : %s\n' "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 未知)"
  printf '  rmem/wmem max: %s / %s\n' \
    "$(sysctl -n net.core.rmem_max 2>/dev/null || echo '?')" \
    "$(sysctl -n net.core.wmem_max 2>/dev/null || echo '?')"
  if [ "$cc" = "bbr" ]; then
    ok "BBR 已生效"
  else
    warn "当前是 ${cc:-未知}, 不是 bbr —— 先跑一次: proxy optimize bbr"
  fi

  echo
  echo "[2] 协议与拥塞控制"
  printf '  启用协议     : %s\n' "${PROTOCOLS:-未知}"
  if proto_on hy2; then
    # 只看合法值: state.env 被手改成 abc 时订阅实际按默认 BBR 生成,
    # 这里不能再显示 "Brutal up=abc" 骗人。
    local _spu="${HY2_BW_UP:-}" _spd="${HY2_BW_DOWN:-}"
    if [ -n "$_spu" ] && ! hy2_bw_ok "$_spu"; then _spu=""; fi
    if [ -n "$_spd" ] && ! hy2_bw_ok "$_spd"; then _spd=""; fi
    if [ -n "$_spu" ] || [ -n "$_spd" ]; then
      printf '  Hysteria2    : Brutal  up=%s Mbps  down=%s Mbps\n' \
        "${_spu:-未设}" "${_spd:-未设}"
      ok "Brutal 已写进客户端订阅(仅 clash.yaml / singbox*.json 有效)"
    else
      echo "  Hysteria2    : 默认 BBR, 未开 Brutal"
      echo "                 晚高峰/丢包链路上抢带宽能力弱 —— 这是和纯 hy2 一键脚本体感差距最大的一项"
      echo "                 开启: HY2_BW_UP=<上行> HY2_BW_DOWN=<下行> proxy sub   (单位 Mbps)"
    fi
  fi
  echo "  REALITY      : $(proto_on reality && echo 'TCP/Vision, 稳但跨境高丢包时吞吐低于 UDP' || echo 未启用)"

  echo
  echo "[3] 客户端默认节点(最容易忽略的一项)"
  local _dn _def_desc="未知" _sb_desc=""
  _dn=$(effective_default_node)
  if [ "$_dn" = "hy2" ]; then
    _def_desc="HY2 / hy2-out (UDP, 速度优先)"
  elif proto_on reality; then
    _def_desc="VLESS/REALITY / vless-out (TCP, 抗封锁优先)"
  elif proto_on ss2022; then
    _def_desc="SS2022 / ss2022-out"
  elif proto_on anytls; then
    _def_desc="AnyTLS / anytls-out"
  elif proto_on tuic; then
    _def_desc="TUIC / tuic-out"
  fi
  # sing-box 的默认出口可能与 clash/小火箭不同: 新版服务端的 REALITY 它连不上,
  # 订阅生成时已强制切到 HY2(见 sb_reality_ok)。这里必须显示真实值,
  # 否则用户照着 info 去查 singbox.json 的 route.final 会对不上。
  _sb_desc="$_def_desc"
  if proto_on reality && ! sb_reality_ok && proto_on hy2; then
    _sb_desc="HY2 / hy2-out (REALITY 与 sing-box 不兼容, 已自动切)"
  fi
  echo "  clash.yaml    : select 第一项 = ${_def_desc}"
  echo "  singbox.json  : route.final   = ${_sb_desc}"
  if proto_on reality && ! sb_reality_ok; then
    echo "  sing-box 的 REALITY 连不上 Xray >= 26.9.8 服务端(上游 #4520); 要用 REALITY 请用 mihomo / xray 内核客户端。"
  fi
  if [ "$_dn" = "hy2" ]; then
    echo "  节点已优先走 UDP; 若你的运营商限速 UDP, 用 DEFAULT_NODE=reality proxy sub 切回 TCP。"
  elif proto_on hy2; then
    echo "  TCP 在高丢包链路上吞吐低于 UDP —— 这是和纯 hy2 一键脚本体感差距最大的一项。"
    echo "  切到 UDP 提速: DEFAULT_NODE=hy2 proxy sub   (切回: DEFAULT_NODE=reality proxy sub)"
  fi

  echo
  echo "[4] 其它常见减速项"
  echo "  - singbox.json 是全代理配置, 国内站点也绕一圈; 要国内直连请用 clash.yaml"
  echo "  - TUN 模式 MTU 填 1500(默认 9000 会丢大包), 并关掉严格路由"
  echo "  - obfs / 端口跳跃会多一层开销; 不需要时可关"
  echo "  - 单核小机器用 top 看 hysteria 是否吃满一个核, 吃满就是 CPU 到顶了"

  echo
  echo "[5] 服务端出口带宽(想实测时手动跑)"
  echo '  curl -o /dev/null -s -w "%{speed_download}\n" "https://speed.cloudflare.com/__down?bytes=10000000"'
  echo "  结果是字节/秒, 乘 8 得 bit/s。它测的是 VPS 出口, 不是你本地到 VPS 的链路。"

  echo
  echo "本命令只读, 不修改任何配置。具体提速步骤见 README「速度与调优」。"
}

cmd_selftest(){
  need_root
  load_state || die "尚未安装"
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  echo
  hr
  echo -e "${M}协议连通性实测${N}  ${D}(用订阅里同一份配置, 从本机回环发起)${N}"
  hr
  selftest_protocols || true
  echo
  if [ "${SELFTEST_FAIL:-0}" != "0" ]; then
    warn "${SELFTEST_FAIL} 个协议不通, 按顺序排查:"
    echo "    ${APP_NAME} status        看进程与端口是否在监听"
    echo "    ${APP_NAME} logs sb       看 sing-box 报错"
    echo "    ${APP_NAME} logs hy2      看 hysteria 报错"
    echo "    云安全组/防火墙      是否放行了对应端口(TCP/UDP 别搞混)"
  elif [ "${SELFTEST_SKIP:-0}" != "0" ]; then
    warn "${SELFTEST_PASS} 个协议实测通过, ${SELFTEST_SKIP} 项未实测 —— 本次自检未覆盖全部协议"
  else
    ok "全部通过: ${SELFTEST_PASS} 个协议"
  fi
  if [ "${SELFTEST_SKIP:-0}" != "0" ]; then
    info "${SELFTEST_SKIP} 项跳过: ${SELFTEST_SKIP_DETAIL:-原因未知}"
    echo -e "    ${D}云安全组 UDP 放行、端口跳跃、客户端到 VPS 的链路都不在本机回环自检覆盖内${N}"
  fi
  echo
  # 协议不通必须让调用方(CI / proxy selftest && ...)看到失败, 不能恒 0。
  [ "${SELFTEST_FAIL:-0}" = "0" ] || return 1
  # 零覆盖不算通过: 缺客户端 / 临时目录建不出来时全部 SKIP, 以前照样返回 0,
  # `proxy selftest && 后续步骤` 会把"一项没测"当成"测过了"。用 2 区分。
  if [ "${SELFTEST_PASS:-0}" = "0" ]; then
    warn "本次没有任何协议被实测, 不能视为通过"
    return 2
  fi
  return 0
}

self_check(){
  info "部署后自检 ..."
  echo
  hr
  echo -e "${M}协议连通性实测${N}  ${D}(用订阅里同一份配置, 从本机回环发起)${N}"
  hr
  selftest_protocols || true
  echo
  # 跳过不能算通过。以前只看 FAIL, 于是 hy2 一次没测也照样打"全部通过",
  # 而 hy2 恰恰最容易卡在云安全组 UDP 443 / 端口跳跃上。
  if [ "${SELFTEST_FAIL:-0}" != "0" ]; then
    warn "${SELFTEST_FAIL} 个协议本机自测未通过 —— 少数 VPS 限制回环出站, 以客户端实测为准"
    echo -e "    ${D}排查: ${APP_NAME} status / ${APP_NAME} logs sb / ${APP_NAME} logs hy2 / ${APP_NAME} selftest${N}"
  elif [ "${SELFTEST_SKIP:-0}" != "0" ]; then
    warn "${SELFTEST_PASS} 个协议实测通过, ${SELFTEST_SKIP} 项未实测(${SELFTEST_SKIP_DETAIL:-原因未知}) —— 本次自检未覆盖全部协议"
    echo -e "    ${D}跳过多因缺对应客户端(hysteria/sing-box); 也可直接用客户端导入订阅实测${N}"
    echo -e "    ${D}云安全组 UDP 放行、端口跳跃、本地到 VPS 的链路都不在回环自检覆盖内${N}"
  else
    ok "全部协议本机自测通过 (${SELFTEST_PASS} 个)"
  fi
}

# ---------------- 安装前预检 ----------------
preflight(){
  local mem_mb ntp ipv6cnt
  mem_mb=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
  if [ -n "$mem_mb" ] && [ "$mem_mb" -lt 400 ]; then
    warn "内存仅 ${mem_mb}MB: Xray + Hysteria2 同时跑会吃紧, 脚本会自动补 1GB swap"
  fi

  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "")
  if [ "$ntp" = "no" ]; then
    warn "系统时间未同步: REALITY 对时间敏感, 建议 systemctl enable --now systemd-timesyncd"
  fi

  ipv6cnt=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)
  if [ "${ipv6cnt:-0}" -gt 0 ]; then
    info "检测到公网 IPv6: 客户端 v6 目标已被路由规则拦截, 建议在服务商侧也关掉"
  fi
}

# ---------------- 安装主流程 ----------------
cmd_install(){
  need_root
  # 安装_mutex: 无参调用(curl|bash / 无终端自动化)走 main 的 "" 分支, 不经
  # main 的命令行加锁 case; 这里补一道, 幂等守卫保证已在 main 加过锁的路径
  # 不重复 flock。两个并发安装同时写 state.env/凭据会互相覆盖。
  acquire_lock
  # 注意: 这里不要预先 mkdir $STATE_DIR。
  # 安装中途失败(下载失败/断网/Ctrl+C)会留下空目录, 下次重跑就会被误判成"残缺安装"弹确认。
  # 状态目录统一由 save_state 在真正写凭据时才创建。
  echo
  echo -e "${M}============================================================${N}"
  echo -e "${M}   Proxy Node Installer v${SCRIPT_VERSION}   (${BUILD_DATE})${N}"
  echo -e "${M}============================================================${N}"
  echo

  # 自动更新被跳过(网络不通 / PN_NO_SELFUPDATE=1)时, 至少把"有新版"这件事说清楚。
  # 能自动更新成功的话这里远端版本已经等于本地, 不会重复提示。
  hint_script_update

  detect_pkg
  . /etc/os-release 2>/dev/null || true
  info "系统: ${PRETTY_NAME:-unknown}  架构: $(uname -m)  内存: $(free -m | awk '/Mem:/{print $2}')MB"

  local fresh=0
  if load_state; then
    apply_env_overrides
    ok "检测到已有安装 (${INSTALLED_AT:-未知}), 复用凭据与端口"
    [ -n "${DEST:-}" ] && info "沿用伪装目标: ${DEST}"
  else
    fresh=1
    info "全新安装"
  fi

  normalize_protocols "$PROTOCOLS"
  info "启用协议: ${PROTOCOLS}"
  # 订阅端口若留空, 必须在这里就定下来再参与 validate_ports 的冲突检查。
  # 之前是在 maybe_sub_http 里随机的, 那时校验早跑完了, 有可能撞上协议端口
  # 导致 proxy-sub 起不来, 而安装过程毫无提示。只在真要开 HTTP 时才占端口。
  if [ "${SUB_HTTP:-0}" = "1" ] && [ -z "${SUB_PORT:-}" ]; then
    SUB_PORT=$(( (RANDOM % 10000) + 30000 ))
  fi
  # 端口先校验: 数字写错 / 两个协议撞同一个端口, 都在这里就中止,
  # 不要等到服务起不来再去猜
  validate_ports

  install_deps
  preflight

  # 清理决策内嵌在安装流程里: 正常安装→默认幂等; 残缺安装→主动问清理
  if ! install_clean_gate "$([ "$fresh" = "1" ] && echo 0 || echo 1)"; then
    # 清掉内存里的旧凭据, 否则会"复用"刚删掉的那套
    UUID=""; PRIV=""; PUB=""; SID=""; DEST=""
    HY2_PASS=""; OBFS_PASS=""; SUB_TOKEN=""; SERVER_IP=""; EGRESS_URL=""
    HY2_PIN=""; CERT_SPKI_B64=""; CERT_HEX=""
    SS2022_PASS=""; ANYTLS_PASS=""; TUIC_PASS=""; TUIC_UUID=""; SB_PIN=""
    fresh=1
  fi

  # 端口占用: 逐个检查已启用协议的端口
  local plist="" p port proto2 owner=""
  proto_on reality && plist="${plist} ${VLESS_PORT}/tcp"
  proto_on hy2     && plist="${plist} ${HY2_PORT}/udp"
  proto_on ss2022  && plist="${plist} ${SS2022_PORT}/tcp ${SS2022_PORT}/udp"
  proto_on anytls  && plist="${plist} ${ANYTLS_PORT}/tcp"
  proto_on tuic    && plist="${plist} ${TUIC_PORT}/udp"

  for p in $plist; do
    port="${p%%/*}"; proto2="${p##*/}"
    owner=$(port_owner "$port" "$proto2") || owner=""
    [ -n "$owner" ] || continue
    if [ "$fresh" = "0" ] && echo "$owner" | grep -qE '^(xray|hysteria|sing-box)'; then
      info "$(echo "$proto2" | tr a-z A-Z) ${port} 由本服务自身监听, 继续"
      continue
    fi
    warn "$(echo "$proto2" | tr a-z A-Z) ${port} 已被占用: ${owner}"
    if echo "$owner" | grep -qE '^(xray|hysteria|sing-box)'; then
      if ask_yes "这是本脚本残留的实例, 清理后继续?"; then
        do_clean 0; sleep 1
      fi
    else
      if ask_yes "结束该进程(${owner})并继续?"; then
        kill_port_owner "$port" "$proto2"; sleep 1
      fi
    fi
    if port_in_use "$port" "$proto2"; then
      die "端口 ${port}/${proto2} 仍被占用。重装试试: bash $(self_hint) install --clean; 或换端口: VLESS_PORT=8443 bash $(self_hint) install"
    fi
  done

  # 内核参数必须在**任何服务启动之前**生效。之前 optimize_system 排在所有
  # restart 之后: rmem_max 仍是默认 208KB 时 HY2 / TUIC 已经建好了 UDP socket,
  # 事后改 sysctl 不会扩大已创建 socket 的 SO_RCVBUF, QUIC 的 8MB/20MB 窗口
  # 被内核钳死 —— 跨洲高 BDP 链路上吞吐直接跑不满。这就是「装完慢、重启后好些」。
  optimize_system

  # xray 必须先就位: openssl 不可用时要回退到 xray x25519 生成密钥
  if proto_on reality; then
    ensure_xray
  fi

  ensure_creds
  # 设备凭据文件统一在这里创建: 只开 ss2022/anytls/tuic 时不会走 write_xray_config,
  # 少了这一步 users.txt 就不存在, sing-box 的 users 会退化成单用户分支。
  ensure_users_file || die "无法创建设备凭据文件 users.txt, 拒绝继续安装"
  if proto_on reality; then
    ensure_xray_service
  fi

  SERVER_IP=$(get_server_ip)
  [ -n "$SERVER_IP" ] || die "无法获取公网 IPv4。若这台机器是纯 IPv6(无 v4 地址), 本脚本暂不支持 —— 链接里需要带方括号的 IPv6 写法, 各协议得分别处理, 不是改一行能解决的"
  ok "服务器 IP: ${SERVER_IP}"

  # 节点备注名默认用 VPS 厂商简称: 客户端列表里显示 "RackNerd-VLESS" 比 "Node-VLESS" 有用
  # 用户显式给了 NODE_NAME 就尊重用户的选择, 不再覆盖
  if [ "$_RAW_NODE_NAME" = "__unset__" ] && [ "${NODE_NAME}" = "Node" ]; then
    local vn
    vn=$(detect_vendor)
    if [ -n "$vn" ]; then
      NODE_NAME="${vn// /-}"
      if vendor_is_upstream "$vn"; then
        # 直营用户看到这个名字正好, 转售商用户会以为认错了 —— 两种都说明白, 别让人猜
        warn "IP 段持有者: ${NODE_NAME} —— 这是机房/批发商, 不一定是卖你机器的商家"
        info "RackNerd / CloudCone 这类转售商没有自己的 ASN, 反查只会返回上游机房"
        info "如果认错了, 装完执行一次即可改名(不用重装): proxy name RackNerd"
      else
        ok "节点备注: ${NODE_NAME}  (链接名形如 ${NODE_NAME}-VLESS / ${NODE_NAME}-HY2)"
      fi
    else
      info "未识别出 VPS 厂商, 节点备注沿用 ${NODE_NAME} (可自定义: NODE_NAME=我的机器)"
    fi
  fi

  backup_config

  # 复用旧 DEST 前必须复查排除名单。旧版本里 dl.google.com / www.youtube.com
  # 这类被墙域名也进过候选表, 留着它 = ClientHello 出不了国, 直接被判机房。
  if [ -n "${DEST:-}" ] && is_blocked "$DEST"; then
    warn "当前伪装目标 ${DEST} 在排除名单里(被墙域名, 或与代理共用证书链), 重新挑一个"
    DEST=""
  fi

  # REALITY 必须做真实握手验证; 只开 hy2/anytls/tuic 时只需要一个可用的 SNI 目标。
  # 之前只按 reality 判断, 单开 hy2 会留下空的 DEST: 证书 CN 为空、
  # masquerade url 变成 https:/// , 链接里 sni 也是空的。
  if proto_on reality; then
    if [ -z "${DEST:-}" ]; then
      if ! pick_dest; then
        err "所有候选伪装站都不可达(连 HTTPS 都打不开), 不是握手问题而是出站被拦:"
        echo "    1) 先确认 443 出站:  curl -sI https://www.samsung.com  看是否 000"
        echo "    2) 再确认时间已同步:  timedatectl"
        echo "    3) 指定自己的域名:    REALITY_DEST=你的域名 bash setup-proxy.sh"
        die  "伪装目标选择失败, 完整探测过程见 /var/log/proxy-deploy.log"
      fi
    else
      info "复用伪装目标: ${DEST}"
    fi
  elif proto_on hy2 || proto_on anytls || proto_on tuic; then
    if [ -z "${DEST:-}" ]; then
      pick_dest_simple
    else
      info "复用伪装目标: ${DEST}"
    fi
  fi

  if proto_on reality; then
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
    # 轮询: 这里误判的代价是整台机器装到一半 die 掉, 而配置完全正常。
    if ! wait_active xray; then
      owner=$(port_owner "$VLESS_PORT" tcp) || owner=""
      if [ -n "$owner" ]; then
        die "Xray 启动失败: TCP ${VLESS_PORT} 被 ${owner} 占用。执行 bash $(self_hint) install --clean 清理后重装, 或换端口: VLESS_PORT=8443 bash $(self_hint) install"
      fi
      die "Xray 启动失败, 查看: journalctl -u xray -n 30 --no-pager"
    fi
    ok "Xray 运行中: TCP ${VLESS_PORT}, 伪装目标 ${DEST}"
  fi

  if proto_on hy2; then
    ensure_hy2
    setup_hy2_hop
  fi

  if sb_enabled; then
    ensure_singbox
    ensure_sb_cert
    ensure_sb_creds
    write_singbox_config
    ensure_singbox_service
  fi

  # 本次没选的协议要真的关掉, 否则端口还开着、用户以为已经关了
  stop_unused_services
  # optimize_system 已提前到服务启动之前, 这里不再重复调用
  local deploy_bad=0
  setup_firewall || deploy_bad=1
  install_healthcheck || deploy_bad=1

  save_state
  gen_links
  # 订阅生成失败必须进 deploy_bad: 否则安装报"部署完成", 用户导入订阅却全是 404。
  gen_sub_files || deploy_bad=1
  maybe_sub_http
  save_state

  write_info_file
  print_links
  print_qr
  print_sub_info
  self_check

  local self_path
  self_path=$(readlink -f "$0" 2>/dev/null || echo "")
  if [ -z "$self_path" ] || [ ! -f "$self_path" ]; then
    # curl | bash 且自动更新被跳过: 脚本没有落盘, 建不了软链
    warn "以管道方式运行, 未创建 ${APP_NAME} 命令"
    echo -e "    ${D}想要管理命令的话, 下次改用:${N}"
    echo -e "    ${D}${ONELINER}${N}"
  else
    # 关键: 按文档用 curl -o 下载再 bash 运行时, 脚本权限是 644(没有执行位)。
    # 软链过去之后 proxy 指向的是一个不可执行的文件, 一敲就是 Permission denied
    # —— root 也一样, 内核要求至少有一个 x 位。安装时顺手补上。
    [ -x "$self_path" ] || chmod 755 "$self_path" 2>/dev/null
    if [ "$self_path" = "/usr/local/bin/${APP_NAME}" ]; then
      # 脚本本身就是装在管理命令位置上的实体文件, 不需要再建软链。
      # 之前这个分支会走到 else 里报"以管道方式运行", 完全是误导。
      ok "管理命令已就位: ${APP_NAME}  (例如 ${APP_NAME} info)"
    elif ln -sf "$self_path" "/usr/local/bin/${APP_NAME}" 2>/dev/null && [ -x "/usr/local/bin/${APP_NAME}" ]; then
      ok "已安装管理命令: ${APP_NAME}  (例如 proxy info)"
    else
      warn "管理命令创建失败, 手动执行:"
      echo -e "    ${D}chmod +x ${self_path} && ln -sf ${self_path} /usr/local/bin/${APP_NAME}${N}"
    fi
    # 软链重指之后再做清理: 此时 proxy 已经指向正在运行的这份,
    # 删掉其它副本不会把管理命令一起删掉。
    cleanup_stale_scripts
  fi

  echo
  if [ "$deploy_bad" = "1" ]; then
    echo -e "${Y}============================================================${N}"
    echo -e "${Y}   部署完成, 但有项目失败${N}"
    echo -e "${Y}============================================================${N}"
    warn "防火墙放行未全部成功, 节点可能从外部连不上; 按上面的提示手动放行后跑一次 proxy status"
  else
    echo -e "${G}============================================================${N}"
    echo -e "${G}   部署完成${N}"
    echo -e "${G}============================================================${N}"
  fi
  echo -e "  节点信息: ${Y}cat /root/proxy-info.txt${N}"
  echo -e "  管理菜单: ${Y}proxy${N}"
  echo -e "  加装协议: ${Y}proxy wizard${N}      优化 VPS: ${Y}proxy optimize${N}"
  echo
  local fw=""
  proto_on reality && fw="${fw} TCP ${VLESS_PORT}"
  proto_on hy2     && fw="${fw} UDP ${HY2_PORT}"
  proto_on ss2022  && fw="${fw} TCP+UDP ${SS2022_PORT}"
  proto_on anytls  && fw="${fw} TCP ${ANYTLS_PORT}"
  proto_on tuic    && fw="${fw} UDP ${TUIC_PORT}"
  if [ "${SUB_HTTP:-0}" = "1" ] && [ "${SUB_BIND:-127.0.0.1}" != "127.0.0.1" ] \
     && [ -n "${SUB_PORT:-}" ]; then fw="${fw} TCP ${SUB_PORT}(订阅)"; fi
  echo -e "${Y}必做${N}: 云安全组放行${Y}${fw}${N}"
  [ -n "${HY2_HOP:-}" ] && echo -e "        以及 ${Y}UDP ${HY2_HOP}${N} (端口跳跃)"
  echo
  # 横幅只是给人看的, 退出码才是给 CI / 一键脚本 / 上层编排看的。
  # 防火墙没放行完时节点从外部根本连不上, 这时必须让 install 返回非 0,
  # 否则 `bash setup-proxy.sh install && 后续步骤` 会误判部署成功。
  return "$deploy_bad"
}

# ---------------- 管理子命令 ----------------
cmd_info(){
  need_root
  load_state || die "尚未安装, 先执行: bash setup-proxy.sh install"
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  if [ -n "${SUB_TOKEN:-}" ]; then
    SUB_TOKEN_DIR="${SUB_DIR}/${SUB_TOKEN}"
  fi
  gen_links
  write_info_file
  print_links
  print_qr
  print_sub_info
}

# 菜单输入 -> 目标站。纯函数, 只往 stdout 吐一个字符串:
#   空 = 不改 / random / 具体域名; 返回 1 = 输入无效(c 由调用方单独处理)。
# 抽出来是为了能脱离 systemd / 网络单独回归。
dest_choice(){
  local ans="${1:-}" i=0 d
  case "$ans" in
    ""|0|q|Q) return 0 ;;
    r|R|random) printf 'random'; return 0 ;;
    c|C|custom) return 1 ;;
  esac
  case "$ans" in
    *[!0-9]*)
      valid_domain "$ans" || return 1
      printf '%s' "$ans"; return 0 ;;
  esac
  for d in $REALITY_DESTS; do
    i=$((i + 1))
    [ "$i" = "$ans" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# 候选池列表。菜单和 `proxy dest list` 共用一份, 避免两处说明慢慢写歪。
_dest_print_pool(){
  local dn d n=0
  echo
  echo -e "${M}伪装目标候选池${N}"
  hr
  # 池子是空格分隔的字符串, 这里就是要按空格拆开 —— 不加引号是故意的。
  # shellcheck disable=SC2086
  for d in $REALITY_DESTS; do
    n=$((n + 1))
    if dn=$(dest_note "$d" 2>/dev/null); then
      printf '  %2d. %-24s %s\n' "$n" "$d" "$dn"
    else
      printf '  %2d. %-24s\n' "$n" "$d"
    fi
  done
  hr
  echo -e "${D}共 ${n} 个, 全部实测: TLS 1.3 + ALPN h2 / 不套 Cloudflare / 国内"
  echo -e "可直连 / 全球流量排名 2100 名以内。"
  echo -e "安装时随机挑一个, 也可以自己指定(换站会重签证书并重写订阅):${N}"
  echo "  REALITY_DEST=www.oracle.com bash /root/setup-proxy.sh install"
}

# 看/换伪装目标站。
#   proxy dest                   当前站 + 整个候选池, 并可当场挑一个换掉
#   proxy dest list              只看候选池
#   proxy dest set <域名|random> 非交互换站(菜单外/脚本里用)
# 安装流程故意复用旧 DEST: 静默换 SNI 会让所有已发出去的链接一次性失效。
cmd_dest(){
  need_root
  load_state || die "尚未安装, 先执行: bash setup-proxy.sh install"
  local dn ans nd choice
  case "${1:-}" in
    ""|current)
      dn=$(dest_note "${DEST:-}" 2>/dev/null) || dn=""
      echo
      echo -e "${M}当前伪装目标${N}"
      hr
      echo "域名   : ${DEST}"
      [ -n "$dn" ] && echo "是什么 : ${dn}"
      echo -e "${D}所有协议共用这一个 SNI。客户端里必须一字不差 —— 抄错不会报 SNI"
      echo -e "错误, 只会表现为连接超时或握手失败。${N}"
      _dest_print_pool
      echo -e "${Y}换站会重签证书并重写全部链接/订阅, 所有客户端必须重新导入。${N}"
      echo -e "${D}平时重装会复用当前站(避免链接静默失效); 只有这里主动换才会变。${N}"
      echo
      read_tty "输入序号 / r(随机换) / c(自填域名) / 回车取消: " ans ""
      case "$ans" in
        ""|0|q|Q) info "未改动"; return 0 ;;
        c|C|custom)
          read_tty "新域名(必须真实可直连): " nd ""
          [ -n "$nd" ] || { info "未改动"; return 0; }
          choice="$nd"
          ;;
        *)
          choice=$(dest_choice "$ans") || die "无效选择: ${ans}。填序号、域名, 或 r/c"
          ;;
      esac
      [ -n "$choice" ] || { info "未改动"; return 0; }
      change_dest "$choice"
      ;;
    list|all)
      _dest_print_pool
      echo
      ;;
    set|change)
      shift || true
      local t="${1:-}"
      [ -n "$t" ] || die "用法: proxy dest set <域名|random>"
      change_dest "$t"
      ;;
    *)
      die "用法: proxy dest [list] | proxy dest set <域名|random>
直接运行 proxy dest 可在菜单里看候选并当场挑选"
      ;;
  esac
}

# 改节点备注名。只改客户端显示, 不碰服务端配置, 所以不用重装也不用重启内核
cmd_name(){
  need_root
  load_state || die "尚未安装, 先执行: bash $(self_hint) install"

  local nn="${1:-}"
  if [ -z "$nn" ]; then
    echo
    echo -e "当前备注: ${G}${NODE_NAME}${N}"
    echo -e "${D}链接名形如 ${NODE_NAME}-VLESS / ${NODE_NAME}-HY2 / ${NODE_NAME}-SS2022${N}"
    echo
    read_tty "新备注名 (回车取消): " nn ""
  fi
  [ -n "$nn" ] || { info "未改动"; return 0; }

  nn=$(sanitize_node_name "$nn")
  if [ "$nn" = "$NODE_NAME" ]; then
    info "和当前一样, 未改动"
    return 0
  fi

  NODE_NAME="$nn"

  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  gen_links
  gen_sub_files
  # 与 cmd_sub 同序: gen_sub_files 在 token 非法时会换新 token 和新目录,
  # 必须等它跑完再 save_state, 否则 state.env 存的还是旧 token。换 token 后
  # 订阅服务也要重启才能指向新目录, 否则用户手上链接全 404 且无从得知新 token。
  maybe_sub_http
  save_state
  write_info_file

  ok "备注名已改为 ${NODE_NAME}"
  echo -e "${D}链接和订阅里的名字已同步, 服务端配置一行没动, 客户端重新导入一次即可${N}"
  echo
  print_links
  print_sub_info
}

cmd_sub(){
  need_root
  load_state || die "尚未安装"
  # sub 允许本次用环境变量指定 Brutal 带宽(会由 save_state 写入 state.env, 之后沿用)。
  # load_state 会从 state.env 逐行读出各键
  # 把环境变量冲掉, 所以按脚本开头记下的 _RAW_* 回盖。这里只回盖这两个变量,
  # 不调用 apply_env_overrides —— 那会连带清空 DEST, 对"只重生成订阅"风险太大。
  # 值非法就不覆盖(保留 state.env 里的原值), gen_sub_files 内还有一层兜底校验。
  local _u="" _d="" _ok=1 _v
  [ "$_RAW_HY2_BW_UP"   != "__unset__" ] && _u="$_RAW_HY2_BW_UP"
  [ "$_RAW_HY2_BW_DOWN" != "__unset__" ] && _d="$_RAW_HY2_BW_DOWN"
  for _v in "$_u" "$_d"; do
    [ -n "$_v" ] || continue
    hy2_bw_ok "$_v" || _ok=0
  done
  if [ "$_ok" = "1" ]; then
    [ "$_RAW_HY2_BW_UP"   != "__unset__" ] && HY2_BW_UP="$_u"
    [ "$_RAW_HY2_BW_DOWN" != "__unset__" ] && HY2_BW_DOWN="$_d"
  else
    warn "HY2_BW_UP/DOWN 必须是 1-10000 的整数(Mbps), 本次保持原有设置不变"
  fi
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  # DEFAULT_NODE 同理必须回盖: state.env 里存着上一次的值, load_state 一 source
  # 就把本次环境变量冲掉了。不补这一段, README 里主推的
  # `DEFAULT_NODE=hy2 proxy sub` 会"执行成功但没切换" —— 和带宽那次是同一个坑。
  if [ "$_RAW_DEFAULT_NODE" != "__unset__" ]; then
    case "$_RAW_DEFAULT_NODE" in
      reality|vless|hy2|hysteria2) DEFAULT_NODE="$_RAW_DEFAULT_NODE" ;;
      *) warn "DEFAULT_NODE='${_RAW_DEFAULT_NODE}' 不认识(可选 reality / hy2), 本次保持原有设置不变" ;;
    esac
  fi
  gen_links
  gen_sub_files
  maybe_sub_http
  save_state
  print_sub_info
}

cmd_status(){
  need_root
  load_state || die "尚未安装"
  echo
  hr
  echo -e "${M}服务状态${N}"
  hr
  echo -e "${D}启用协议: ${PROTOCOLS:-reality,hy2}${N}"
  proto_on reality && printf 'xray            : %s / %s\n' "$(systemctl is-active xray 2>/dev/null)" "$(systemctl is-enabled xray 2>/dev/null)"
  proto_on hy2     && printf 'hysteria-server : %s / %s\n' "$(systemctl is-active hysteria-server 2>/dev/null)" "$(systemctl is-enabled hysteria-server 2>/dev/null)"
  sb_enabled       && printf 'sing-box        : %s / %s\n' "$(systemctl is-active sing-box 2>/dev/null)" "$(systemctl is-enabled sing-box 2>/dev/null)"
  [ -n "${HY2_HOP:-}" ] && printf 'hy2-hop         : %s\n' "$(systemctl is-active hy2-hop 2>/dev/null)"
  [ "$SUB_HTTP" = "1" ] && printf 'proxy-sub       : %s\n' "$(systemctl is-active proxy-sub 2>/dev/null)"
  echo
  echo -e "${M}监听端口${N}"
  local plist="" p
  proto_on reality && plist="${plist}|${VLESS_PORT}"
  proto_on hy2     && plist="${plist}|${HY2_PORT}"
  proto_on ss2022  && plist="${plist}|${SS2022_PORT}"
  proto_on anytls  && plist="${plist}|${ANYTLS_PORT}"
  proto_on tuic    && plist="${plist}|${TUIC_PORT}"
  if [ -n "$plist" ]; then
    # 端口前必须是 : 或 .: 只写 "(443|8445)" 会把 *:18443 也匹配成 443,
    # 别人的监听被当成自己的节点在跑。
    ss -tulnp 2>/dev/null | grep -E "[:.](${plist#|})[[:space:]]" || echo "(未找到匹配端口)"
  else
    echo "(无)"
  fi
  echo
  echo -e "${M}出口 IPv4${N} : ${SERVER_IP:-未知}"
  [ -x "$XRAY_BIN" ] && echo -e "${M}Xray 版本${N} : $($XRAY_BIN version 2>/dev/null | head -1)"
  [ -x "$HY2_BIN" ]  && echo -e "${M}Hysteria2${N}  : $($HY2_BIN version 2>/dev/null | grep -m1 '^Version:' | cut -f2)"
  # sing-box 与 Xray / Hysteria2 一样默认追最新, 这里只标策略。
  # 上一版这行写的是"锁版本, 不自动追最新" —— 那是当时的实情, 留着会让用户
  # 以为脚本永远不会升级 sing-box, 看到别人用新版时误判脚本坏了。
  [ -x "$SB_BIN" ]   && echo -e "${M}sing-box${N}  : $($SB_BIN version 2>/dev/null | head -1)  ${D}(默认追最新, API 不可达时退 v${SB_FALLBACK_VERSION})${N}"
  echo -e "${M}拥塞控制${N}  : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo -e "${M}设备凭据${N}  : $([ -f "$USERS_FILE" ] && wc -l < "$USERS_FILE" || echo 0) 条 (proxy user list)"
  # 版本 + 脚本路径 + 修改时间一起给: 只给版本号看不出"这份是什么时候下的",
  # 而"一直在跑几个月前的旧脚本"正是最容易踩的坑。有新版会单独提示。
  local _sp _sm
  _sp=$(running_script_path)
  echo -e "${M}脚本版本${N}  : ${SCRIPT_VERSION} (${BUILD_DATE})"
  if [ -n "$_sp" ]; then
    _sm=$(date -r "$_sp" '+%Y-%m-%d %H:%M' 2>/dev/null)
    echo -e "${M}脚本文件${N}  : ${_sp}${_sm:+  (改于 ${_sm})}"
  fi
  echo
}

# ---------------- 自检 ----------------
# 三件事: 二进制有没有被换过 / 配置还能不能被内核接受 / 凭据文件权限有没有被放宽
VERIFY_FIX=""
# chk_perm 遇到"文件缺失 / stat 读不到"时记数: 这类失败 chmod 修不了。
# --fix 只能清零可修项造成的 perm_bad, 否则凭据文件缺失也会被误报"自检通过"。
VERIFY_UNFIXABLE=0

chk_bin_sha(){
  local file="$1" want="$2" label="$3" got
  # 调用处已按 proto_on 筛过, 到这里文件就该存在。以前缺文件直接 return 0,
  # 二进制被删掉时这一整段跳过, 末尾照样打印"自检通过"。
  [ -x "$file" ] || {
    printf '  %b%-10s%b %s (文件不存在: %s)\n' "$R" "缺失" "$N" "$label" "$file"
    return 1
  }
  got=$(file_sha256 "$file")
  if [ -z "$want" ]; then
    printf '  %b%-10s%b %s\n' "$Y" "未记录" "$N" "${label}  (重装一次即可建立基准)"
    return 0
  fi
  if [ "$got" = "$want" ]; then
    printf '  %b%-10s%b %s\n' "$G" "一致" "$N" "${label}"
    return 0
  fi
  printf '  %b%-10s%b %s\n' "$R" "被改动" "$N" "${label}"
  printf '      %b基准 %s%b\n' "$D" "${want:0:32}" "$N"
  printf '      %b当前 %s%b\n' "$D" "${got:0:32}" "$N"
  printf '      %b这台机器上的二进制和安装时不一致, 可能被人替换。%b\n' "$D" "$N"
  printf '      %b确认无误可重装覆盖: bash setup-proxy.sh install --clean%b\n' "$D" "$N"
  return 1
}

chk_perm(){
  local f="$1" want="$2" label="$3" got
  [ -e "$f" ] || {
    printf '  %b%-10s%b %s (文件不存在: %s)\n' "$R" "缺失" "$N" "$label" "$f"
    VERIFY_UNFIXABLE=$((VERIFY_UNFIXABLE + 1))
    return 1
  }
  got=$(stat -c '%a' "$f" 2>/dev/null)
  [ -n "$got" ] || {
    printf '  %b%-10s%b %s (无法读取权限)\n' "$R" "未知" "$N" "$label"
    VERIFY_UNFIXABLE=$((VERIFY_UNFIXABLE + 1))
    return 1
  }
  if [ "$got" = "$want" ]; then
    printf '  %b%-10s%b %s\n' "$G" "正常" "$N" "$label"
    return 0
  fi
  printf '  %b%-10s%b %s  (当前 %s, 应为 %s)\n' "$R" "过宽" "$N" "$label" "$got" "$want"
  VERIFY_FIX="${VERIFY_FIX}${f}|${want}"$'\n'
  return 1
}

cmd_verify(){
  need_root
  load_state || die "尚未安装, 先执行: bash $(self_hint) install"
  local fix=0 a bad=0 perm_bad=0
  # 单进程内可能连跑多次(测试 harness 就是 source 后连调), 不重置会把上一次
  # 待修的路径带进这次, 修掉本不该动的文件。
  VERIFY_FIX=""
  VERIFY_UNFIXABLE=0

  for a in "$@"; do
    case "$a" in --fix|-f) fix=1 ;; esac
  done

  echo
  hr
  echo -e "${M}安全自检${N}   ${D}检查项: 二进制指纹 / 配置合法性 / 凭据权限 / 端口监听${N}"
  hr

  echo
  echo -e "${B}1. 二进制指纹${N}  ${D}(安装时记录, 之后被替换就能看出来)${N}"
  if proto_on reality; then
    chk_bin_sha "$XRAY_BIN" "${XRAY_BIN_SHA:-}" "xray      $($XRAY_BIN version 2>/dev/null | head -1)" || bad=1
  fi
  if proto_on hy2; then
    chk_bin_sha "$HY2_BIN" "${HY2_BIN_SHA:-}" "hysteria  $($HY2_BIN version 2>/dev/null | grep -m1 '^Version:' | cut -f2)" || bad=1
  fi
  if sb_enabled; then
    chk_bin_sha "$SB_BIN" "${SB_BIN_SHA:-}" "sing-box  $($SB_BIN version 2>/dev/null | head -1)" || bad=1
  fi

  echo
  echo -e "${B}2. 配置合法性${N}"
  if proto_on reality && [ -x "$XRAY_BIN" ]; then
    if "$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
      printf '  %b%-10s%b xray config.json\n' "$G" "通过" "$N"
    else
      printf '  %b%-10s%b xray config.json\n' "$R" "失败" "$N"; bad=1
    fi
  fi
  if sb_enabled && [ -x "$SB_BIN" ]; then
    if "$SB_BIN" check -c "$SB_CFG" >/dev/null 2>&1; then
      printf '  %b%-10s%b sing-box config.json\n' "$G" "通过" "$N"
    else
      printf '  %b%-10s%b sing-box config.json\n' "$R" "失败" "$N"; bad=1
    fi
  fi
  if proto_on hy2; then
    # hysteria 没有 config check 子命令, 只做必填项存在性检查
    if [ -f "$HY2_CFG" ] && grep -q '^listen:' "$HY2_CFG" && grep -q '^auth:' "$HY2_CFG" \
       && grep -q '^tls:' "$HY2_CFG"; then
      printf '  %b%-10s%b hysteria config.yaml (listen/auth/tls 齐全)\n' "$G" "通过" "$N"
    else
      printf '  %b%-10s%b hysteria config.yaml\n' "$R" "缺项" "$N"; bad=1
    fi
  fi

  echo
  echo -e "${B}3. 凭据文件与订阅目录权限${N}  ${D}(xray 配置里就是全部设备的 UUID)${N}"
  proto_on reality && { chk_perm "$XRAY_CFG" 600 "xray 配置" || perm_bad=1; }
  proto_on hy2     && { chk_perm "$HY2_CFG" 600 "hysteria 配置(含密码)" || perm_bad=1; }
  proto_on hy2     && { chk_perm /etc/hysteria/key.pem 600 "hysteria 私钥" || perm_bad=1; }
  sb_enabled       && { chk_perm "$SB_CFG" 600 "sing-box 配置(含密码)" || perm_bad=1; }
  sb_enabled       && { chk_perm "$SB_KEY" 600 "sing-box 私钥" || perm_bad=1; }
  chk_perm "$STATE_FILE" 600 "state.env(全部凭据)" || perm_bad=1
  chk_perm "$USERS_FILE" 600 "users.txt(设备列表)" || perm_bad=1
  chk_perm /root/proxy-info.txt 600 "proxy-info.txt" || perm_bad=1
  chk_perm "$STATE_DIR" 700 "状态目录" || perm_bad=1

  # 目录里任何一个文件对其它用户可读都算问题
  local loose
  loose=$(find "$STATE_DIR" -type f -perm /o+r 2>/dev/null | head -3)
  if [ -n "$loose" ]; then
    printf '  %b%-10s%b 下列文件对其它用户可读:\n' "$R" "泄露" "$N"
    printf '%s\n' "$loose" | sed 's/^/      /'
    while IFS= read -r a; do [ -n "$a" ] && VERIFY_FIX="${VERIFY_FIX}${a}|600"$'\n'; done <<< "$loose"
    perm_bad=1
  fi

  # 订阅目录同样是全量凭据: links.txt / clash.yaml / singbox*.json 里有 UUID、
  # HY2 / SS2022 / AnyTLS / TUIC 密码和 REALITY 公钥。任何情况下都该是 700/600;
  # 开了 HTTP 时把属主交给 nobody 服务进程, 而不是 755/644 放开给同机所有用户。
  local sdir="${SUB_DIR:-/var/www/proxy-sub}/${SUB_TOKEN:-}" sub_loose=""
  if [ -n "${SUB_TOKEN:-}" ] && [ -d "$sdir" ]; then
    chk_perm "$sdir" 700 "订阅目录(仅属主可读)" || perm_bad=1
    sub_loose=$(find "$sdir" \( -perm /g+r -o -perm /o+r \) 2>/dev/null | head -3)
    if [ -n "$sub_loose" ]; then
      printf '  %b%-10s%b 订阅文件对其它用户可读(token 与全部密码):\n' "$R" "泄露" "$N"
      printf '%s\n' "$sub_loose" | sed 's/^/      /'
      while IFS= read -r a; do [ -n "$a" ] && VERIFY_FIX="${VERIFY_FIX}${a}|600"$'\n'; done <<< "$sub_loose"
      perm_bad=1
    fi
    if [ "${SUB_HTTP:-0}" = "1" ] && [ "$(stat -c '%U' "$sdir" 2>/dev/null)" != "nobody" ]; then
      printf '  %b%-10s%b 订阅目录属主不是 nobody, HTTP 服务读不到文件:\n' "$R" "异常" "$N"
      printf '      %s\n' "$sdir"
      VERIFY_UNFIXABLE=$((VERIFY_UNFIXABLE + 1))
      perm_bad=1
    fi
  fi

  echo
  echo -e "${B}4. 服务与监听${N}"
  # 只要求「当前协议组合真的会用到」的服务是活的。
  # 老版本这里是无条件判活: 用户按第 6 节建议 systemctl disable --now proxy-sub
  # 关掉订阅服务, 回到这里又被标红, 自检自己打自己。
  local svc want
  for svc in xray hysteria-server sing-box proxy-sub hy2-hop; do
    systemctl cat "${svc}.service" >/dev/null 2>&1 || continue
    case "$svc" in
      xray)            want=$(proto_on reality && echo 1 || echo 0) ;;
      hysteria-server) want=$(proto_on hy2     && echo 1 || echo 0) ;;
      sing-box)        want=$(sb_enabled       && echo 1 || echo 0) ;;
      proxy-sub)       want=$([ "${SUB_HTTP:-0}" = "1" ] && echo 1 || echo 0) ;;
      hy2-hop)         want=$([ -n "${HY2_HOP:-}" ] && echo 1 || echo 0) ;;
      *)               want=1 ;;
    esac
    if systemctl is-active --quiet "$svc"; then
      if [ "$want" = "1" ]; then
        # 进程活着不等于重启后还在: enable 失败时这里以前照样打"运行中",
        # 用户要到下次重启才发现节点没了。没自启按失败算。
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
          printf '  %b%-10s%b %s\n' "$G" "运行中" "$N" "$svc"
        else
          printf '  %b%-10s%b %s  %s\n' "$Y" "未自启" "$N" "$svc" \
            "(重启后不会自动启动, 执行 systemctl enable ${svc})"
          bad=1
        fi
      else
        # 配置说用不到它, 它却在跑 = 多一个对公网的监听端口。不算致命(不改退出码),
        # 但要指出正确的关闭方式: proxy restart 只重启需要的服务, 不会停多余服务。
        printf '  %b%-10s%b %s  %s\n' "$Y" "多余" "$N" "$svc" "(当前配置不需要, 可 systemctl disable --now ${svc})"
      fi
    elif [ "$want" = "1" ]; then
      printf '  %b%-10s%b %s\n' "$R" "未运行" "$N" "$svc"; bad=1
    else
      # 当前协议组合用不到它, 停着才是对的
      printf '  %b%-10s%b %s  %s\n' "$D" "已停用" "$N" "$svc" "(当前配置不需要, 符合预期)"
    fi
  done
  if systemctl cat proxy-healthcheck.timer >/dev/null 2>&1; then
    if systemctl is-active --quiet proxy-healthcheck.timer; then
      printf '  %b%-10s%b proxy-healthcheck.timer (每 5 分钟)\n' "$G" "运行中" "$N"
    else
      printf '  %b%-10s%b proxy-healthcheck.timer\n' "$R" "未运行" "$N"
      # 单元在但没在跑 = 定时自愈完全失效, 必须计入 bad, 否则末尾"自检通过"
      # 会和上面这行红字自相矛盾, 脚本退出码也还是 0。
      bad=1
    fi
  fi

  echo
  echo -e "${B}5. 订阅 DNS 配置${N}  ${D}(缺了会被 Google 判成中国大陆)${N}"
  local tdir="${SUB_DIR:-/var/www/proxy-sub}/${SUB_TOKEN:-}"
  if [ -z "${SUB_TOKEN:-}" ] || [ ! -d "$tdir" ]; then
    echo "  跳过: 没找到订阅目录 (执行 proxy sub 重新生成订阅)"
  else
    local dsub=0
    # 两份文件都缺时, 以前两个 if 全跳过、dsub 仍是 0, 末尾照报"订阅 DNS 已接管"。
    [ -f "$tdir/clash.yaml" ] || {
      printf '  %b%-10s%b clash.yaml 不存在\n' "$R" "缺失" "$N"; dsub=1; }
    [ -f "$tdir/singbox.json" ] || {
      printf '  %b%-10s%b singbox.json 不存在\n' "$R" "缺失" "$N"; dsub=1; }
    if [ -f "$tdir/clash.yaml" ]; then
      if grep -q 'enhanced-mode:[[:space:]]*fake-ip' "$tdir/clash.yaml" \
         && grep -q 'ipv6:[[:space:]]*false' "$tdir/clash.yaml"; then
        printf '  %b%-10s%b clash.yaml 已启用 fake-ip + 关闭 IPv6\n' "$G" "通过" "$N"
      else
        printf '  %b%-10s%b clash.yaml 缺 fake-ip/IPv6 配置\n' "$R" "缺失" "$N"; dsub=1
      fi
    fi
    if [ -f "$tdir/singbox.json" ]; then
      if grep -q '"dns"' "$tdir/singbox.json" && grep -q 'hijack-dns' "$tdir/singbox.json"; then
        printf '  %b%-10s%b singbox.json DNS 已接管\n' "$G" "通过" "$N"
      else
        printf '  %b%-10s%b singbox.json 缺 DNS 接管\n' "$R" "缺失" "$N"; dsub=1
      fi
    fi
    if [ "$dsub" = "1" ]; then
      echo -e "  ${Y}执行 proxy sub 可重新生成带 DNS 的订阅${N}"
      bad=1
    fi
  fi

  echo -e "${B}6. 订阅服务暴露面${N}  ${D}(token 即凭据)${N}"
  if [ "$SUB_HTTP" = "1" ] && systemctl is-active --quiet proxy-sub 2>/dev/null; then
    if [ "${SUB_BIND:-127.0.0.1}" = "127.0.0.1" ]; then
      printf '  %b%-10s%b 只监听 127.0.0.1, 需 SSH 隧道才能取订阅\n' "$G" "通过" "$N"
    else
      printf '  %b%-10s%b 对 %s:%s 开放, 且是明文 HTTP —— token 在链路上可见\n' \
        "$R" "暴露" "$N" "$SUB_BIND" "${SUB_PORT:-?}"
      echo -e "  ${D}明文 HTTP 且 token 在 URL 里, 对公网开放属实质暴露; 不想开放就 systemctl disable --now proxy-sub${N}"
      # 明文 + 非回环 = 实质暴露, 必须计入 bad, 不能只在最后宣布"未泄露"。
      bad=1
    fi
    # 老版本用的是 python3 -m http.server, 会在根路径列目录 = 直接泄露 token
    if grep -q 'http\.server' /etc/systemd/system/proxy-sub.service 2>/dev/null; then
      printf '  %b%-10s%b 订阅服务仍是旧版(http.server 会列目录, token 会泄露)\n' "$R" "危险" "$N"
      echo -e "  ${Y}执行 proxy sub 换成不列目录的新服务${N}"
      bad=1
    fi
  else
    echo "  未启用订阅 HTTP 服务"
  fi

  # 权限类问题可以就地修
  if [ -n "$VERIFY_FIX" ]; then
    if [ "$fix" = "1" ]; then
      echo
      local _chmod_fail=0 a2
      while IFS='|' read -r a a2; do
        [ -n "$a" ] || continue
        if chmod "$a2" "$a" 2>/dev/null; then
          echo -e "  ${G}已修正${N} $a -> $a2"
        else
          echo -e "  ${R}修正失败${N} $a -> $a2 (文件只读/属主不符?)"
          _chmod_fail=1
        fi
      done <<< "$VERIFY_FIX"
      # 以前 chmod 失败被 2>/dev/null && 吞掉后仍无条件 perm_bad=0,
      # 凭据还是 world-readable 却打印"自检通过"。只有"可修项全修好"且
      # "没有缺失/不可读这类修不了的问题"才算过。
      if [ "$_chmod_fail" = "0" ] && [ "$VERIFY_UNFIXABLE" -eq 0 ]; then
        perm_bad=0
      else
        echo -e "  ${R}仍有权限问题无法通过 --fix 修正(缺失/不可读/修正失败)${N}"
      fi
    else
      echo
      echo -e "  ${Y}加 --fix 可自动修正上面的权限问题:${N} proxy verify --fix"
    fi
  fi
  [ "$perm_bad" = "1" ] && bad=1

  echo
  if [ "$bad" = "0" ]; then
    ok "自检通过: 二进制未被替换, 配置合法, 凭据权限正常, 订阅 DNS 已接管, 订阅服务未对外暴露"
  else
    warn "自检发现上面标红的问题, 按提示处理后再跑一次 proxy verify"
  fi
  echo
  return "$bad"
}

# ---------------- 诊断报告 ----------------
# 「用不了」的时候, 让用户在服务器上跑一条命令, 把结果整段贴出来。
# 报告是要外发的, 所以凭据一律先脱敏再落盘 —— 宁可少给点信息, 也不能把 UUID 带出去。
DIAG_SECRETS=()

# 登记一个需要脱敏的值; 太短的值(端口、1、0)会把正文误伤, 只收 8 位以上
diag_sec(){
  local s="${1:-}"
  # 用户手改的自定义密码/token 可能短于自动生成的 16 位 hex; 只收 >=8 会让
  # 6 位自定义密码原样进诊断报告外泄。放到 >=4: 更短的值不足以做子串替换
  # (会把报告里每个 "a" 都抹掉), 且 4 位以下本身就是弱到没有保密意义的口令。
  [ "${#s}" -ge 4 ] && DIAG_SECRETS+=("$s")
  return 0
}

diag_redact(){
  local line s
  # 长的先替换: 若短口令恰好是长凭据的子串, 先替短的会把长的截成
  # "<已隐去>剩余部分", 反而漏出后半段。按长度降序保证长凭据整体被盖住。
  local -a sorted=()
  if [ "${#DIAG_SECRETS[@]}" -gt 0 ]; then
    while IFS= read -r s; do sorted+=("$s"); done < <(
      printf '%s\n' "${DIAG_SECRETS[@]}" | awk '{ print length"\t"$0 }' | sort -rn -k1,1 | cut -f2-
    )
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    for s in ${sorted[@]+"${sorted[@]}"}; do
      # 引号包住 pattern: 密码里的 * ? 不会被当成通配符
      line="${line//"$s"/<已隐去>}"
    done
    printf '%s\n' "$line"
  done
}

# 三个内核的 version 输出格式各不相同, 统一抠出版本号:
#   xray      -> "Xray 26.3.27 (Xray, Penetrates Everything.)"
#   hysteria  -> "Version:\t2.14.0"  (首行是空 logo, 不能 head -1)
#   sing-box  -> "sing-box version 1.14.4"
bin_ver(){
  local b="$1" v
  [ -x "$b" ] || { printf '无'; return 0; }
  case "${b##*/}" in
    hysteria*)
      # 上游 appAboutLong 的 appLogo 以换行开头, version 第一行是空的;
      # 真正的版本在 "Version:\t2.14.0" 那行。取错行会一直显示"未知"。
      v=$("$b" version 2>/dev/null | grep -m1 '^Version:' | cut -f2 \
          | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1)
      ;;
    *)
      v=$("$b" version 2>/dev/null | head -1 \
          | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1)
      ;;
  esac
  printf '%s' "${v#v}" | grep . || printf '未知'
}

# 诊断报告路径单独成函数: 这是唯一一段"用户输入直接决定 root 写哪个文件"的判断,
# 必须能被回归套件直接调用验证, 不能埋在 cmd_diag 里靠肉眼审。
# 用全局 DIAG_OUT / DIAG_PATH_ERR 传结果, 不走命令替换 —— 子 shell 里改的变量
# 传不回父进程, 失败原因会丢。
DIAG_OUT=""
DIAG_PATH_ERR=""
diag_out_path(){
  DIAG_OUT=""; DIAG_PATH_ERR=""
  local out="${1:-}"
  if [ -z "$out" ]; then
    DIAG_OUT="/root/proxy-diag-$(date +%Y%m%d-%H%M%S).txt"
    return 0
  fi
  case "$out" in
    /root/*|/tmp/*) ;;
    *) DIAG_PATH_ERR="诊断报告只能写到 /root/ 或 /tmp/ 下: ${out}"; return 1 ;;
  esac
  case "$out" in *..*) DIAG_PATH_ERR="诊断报告路径不能含 '..': ${out}"; return 1 ;; esac
  case "${out##*/}" in ''|.|..|*/*) DIAG_PATH_ERR="诊断报告文件名不合法: ${out}"; return 1 ;; esac
  [ ! -L "$out" ] || { DIAG_PATH_ERR="诊断报告路径是符号链接, 拒绝写入: ${out}"; return 1; }
  [ -d "$(dirname "$out")" ] || { DIAG_PATH_ERR="目录不存在: $(dirname "$out")"; return 1; }
  # 只挡 $out 本身不够: /tmp/lnk/x 且 lnk -> /etc 时 -L 为假、-d 为真,
  # 报告会以 root 写进 /etc。把父目录解析成物理路径后再比对前缀。
  local realdir
  realdir=$(cd -P "$(dirname "$out")" 2>/dev/null && pwd -P) || realdir=""
  case "$realdir" in
    /root|/root/*|/tmp|/tmp/*) ;;
    *) DIAG_PATH_ERR="诊断报告目录解析后不在 /root/ 或 /tmp/ 下(可能是符号链接): ${out}"; return 1 ;;
  esac
  DIAG_OUT="$out"
  return 0
}

cmd_diag(){
  need_root
  local out raw installed=0 u act en rst found _ipt _listen
  diag_out_path "${1:-}" || die "${DIAG_PATH_ERR}"
  out="$DIAG_OUT"
  raw=$(mktemp 2>/dev/null) || die "无法创建临时文件"

  load_state >/dev/null 2>&1 && installed=1
  SERVER_IP="${SERVER_IP:-$(get_server_ip 2>/dev/null)}"

  # 先把所有凭据登记进去, 后面整份报告一次性脱敏
  diag_sec "${UUID:-}";      diag_sec "${PRIV:-}";        diag_sec "${PUB:-}"
  diag_sec "${SID:-}";       diag_sec "${HY2_PASS:-}";    diag_sec "${OBFS_PASS:-}"
  diag_sec "${SS2022_PASS:-}"; diag_sec "${ANYTLS_PASS:-}"; diag_sec "${TUIC_PASS:-}"
  diag_sec "${TUIC_UUID:-}"; diag_sec "${SUB_TOKEN:-}";   diag_sec "${EGRESS_URL:-}"
  # 证书指纹不是私钥, 但它们是"客户端拿来固定服务端身份"的值 —— 连同 UUID
  # 一起外发, 等于把整套连接凭据补齐了。报告要外发, 一并隐去。
  diag_sec "${CERT_HEX:-}"; diag_sec "${CERT_SPKI_B64:-}"
  diag_sec "${SB_PIN:-}";   diag_sec "${HY2_PIN:-}"
  # 多设备凭据在 users.txt 里(每个设备一个 UUID), 只登记 state 里的主 UUID 不够,
  # 否则 [9]/[10] 段把内核日志原文贴出去时, 别的设备 UUID 会原样外泄。
  local du
  if [ -f "$USERS_FILE" ]; then
    while IFS='|' read -r du _ || [ -n "$du" ]; do [ -n "$du" ] && diag_sec "$du"; done < "$USERS_FILE"
  fi

  info "收集诊断信息 (大约 20-40 秒) ..."

  {
    echo "Proxy Node 诊断报告"
    echo "================================================================"
    printf '脚本版本 : %s (%s)\n' "$SCRIPT_VERSION" "$BUILD_DATE"
    printf '脚本路径 : %s\n' "$(running_script_path)"
    printf '生成时间 : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '主机名   : %s\n' "$(hostname 2>/dev/null)"
    printf '报告说明 : 所有 UUID / 密码 / token 已替换为 <已隐去>\n'
  } >> "$raw"

  {
    echo
    echo "[1] 系统"
    printf '  发行版   : %s\n' "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知}")"
    printf '  内核     : %s\n' "$(uname -r)"
    printf '  架构     : %s\n' "$(uname -m)"
    printf '  虚拟化   : %s\n' "$(systemd-detect-virt 2>/dev/null || echo 未知)"
    printf '  运行时长 : %s\n' "$(uptime -p 2>/dev/null || echo 未知)"
    printf '  内存     : %s\n' "$(free -m 2>/dev/null | awk '/Mem:/{printf "%sMB 总 / %sMB 可用", $2, $7}')"
    printf '  磁盘     : %s\n' "$(df -h / 2>/dev/null | awk 'NR==2{printf "%s 总 / %s 可用 (%s)", $2, $4, $5}')"
    printf '  负载     : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    printf '  swap     : %s\n' "$(free -m 2>/dev/null | awk '/Swap:/{printf "%sMB", $2}')"
  } >> "$raw"

  {
    echo
    echo "[2] 安装状态"
    if [ "$installed" = "1" ]; then
      printf '  状态     : 已安装\n'
      printf '  安装时间 : %s\n' "${INSTALLED_AT:-未知}"
      printf '  协议组合 : %s\n' "${PROTOCOLS:-未知}"
      printf '  备注名   : %s\n' "${NODE_NAME:-未知}"
      printf '  伪装目标 : %s\n' "${DEST:-未设置}"
      printf '  端口     : reality=%s hy2=%s ss2022=%s anytls=%s tuic=%s\n' \
        "${VLESS_PORT:-?}" "${HY2_PORT:-?}" "${SS2022_PORT:-?}" "${ANYTLS_PORT:-?}" "${TUIC_PORT:-?}"
      printf '  混淆/跳跃: obfs=%s hop=%s\n' \
        "$([ "${ENABLE_OBFS:-0}" = "1" ] && echo 已开 || echo 关)" "${HY2_HOP:-关}"
      printf '  上游出口 : %s\n' "$([ -n "${EGRESS_URL:-}" ] && echo 已配置 || echo 未配置)"
      printf '  订阅服务 : %s  bind=%s port=%s\n' \
        "$([ "${SUB_HTTP:-0}" = "1" ] && echo 已启用 || echo 未启用)" "${SUB_BIND:-?}" "${SUB_PORT:-?}"
      printf '  设备数   : %s\n' "$([ -f "$USERS_FILE" ] && wc -l < "$USERS_FILE" || echo 0)"
      printf '  二进制   : xray %s | hysteria %s | sing-box %s\n' \
        "$(bin_ver "$XRAY_BIN")" "$(bin_ver "$HY2_BIN")" "$(bin_ver "$SB_BIN")"
    else
      printf '  状态     : 未安装, 或 %s 不可读\n' "$STATE_FILE"
    fi
  } >> "$raw"

  {
    echo
    echo "[3] 服务状态"
    found=0
    for u in xray hysteria-server sing-box proxy-sub hy2-hop proxy-healthcheck.timer; do
      systemctl cat "$u" >/dev/null 2>&1 || continue
      found=1
      act=$(systemctl is-active "$u" 2>/dev/null)
      en=$(systemctl is-enabled "$u" 2>/dev/null)
      rst=$(systemctl show "$u" -p NRestarts --value 2>/dev/null)
      printf '  %-26s %-9s %-9s 重启次数=%s\n' "$u" "${act:-?}" "${en:-?}" "${rst:-?}"
    done
    [ "$found" = "1" ] || echo "  (没有任何相关 systemd 单元)"
  } >> "$raw"

  {
    echo
    echo "[4] 监听端口"
    # grep 无匹配返回 1, 但管道末尾是 sed(恒 0), || 永远不触发 —— 没有监听时
    # 这一节是空的, 看报告的人分不清"没监听"和"采集失败"。用 PIPESTATUS 取 grep 的码。
    _listen=$(ss -tulnp 2>/dev/null | grep -E 'xray|hysteria|sing-box|python3' | sed 's/^/  /')
    [ -n "$_listen" ] && printf '%s\n' "$_listen" || echo "  (没有 xray/hysteria/sing-box 在监听)"
  } >> "$raw"

  {
    echo
    echo "[5] 配置校验"
    if [ "$installed" = "1" ]; then
      if proto_on reality && [ -x "$XRAY_BIN" ]; then
        if "$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
          echo "  xray      : 通过"
        else
          echo "  xray      : 失败"
          "$XRAY_BIN" run -test -c "$XRAY_CFG" 2>&1 | tail -6 | sed 's/^/              /'
        fi
      fi
      if sb_enabled && [ -x "$SB_BIN" ]; then
        if "$SB_BIN" check -c "$SB_CFG" >/dev/null 2>&1; then
          echo "  sing-box  : 通过"
        else
          echo "  sing-box  : 失败"
          "$SB_BIN" check -c "$SB_CFG" 2>&1 | tail -6 | sed 's/^/              /'
        fi
      fi
      proto_on hy2 && echo "  hysteria  : 无 check 子命令, 见 [10] 日志"
    else
      echo "  跳过(未安装)"
    fi
  } >> "$raw"

  {
    echo
    echo "[6] 网络与出口"
    printf '  出口 IPv4      : %s\n' "$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || echo 获取失败)"
    printf '  state 记录 IP  : %s\n' "${SERVER_IP:-无}"
    if [ -n "${DEST:-}" ] && command -v openssl >/dev/null 2>&1; then
      printf '  伪装站握手     : %s  (版本|ALPN)\n' "$(dest_tls_info "$DEST")"
    fi
    printf '  到 Google 204  : %s\n' "$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 https://www.google.com/generate_204 2>/dev/null || echo 000)"
    printf '  到 CF 204      : %s\n' "$(curl -sI -o /dev/null -w '%{http_code}' --max-time 8 http://cp.cloudflare.com/generate_204 2>/dev/null || echo 000)"
    printf '  DNS 解析       : %s\n' "$(getent hosts www.bing.com 2>/dev/null | head -1 | awk '{print $1}' | grep . || echo 失败)"
    if [ -n "${EGRESS_URL:-}" ]; then
      local egip
      egip=$(egress_probe_ip 2>/dev/null | head -1)
      # 只写"可达"不写"可用": 这一步是直连上游代理测的, 只能证明代理活着,
      # 证明不了服务端真的把流量交给它了。真实出口在下面"隧道出口 IP"那节。
      printf '  上游代理可达   : %s  (仅表示代理本身能连上, 真实出口看隧道实测)\n' "${egip:-探测失败}"
    fi
  } >> "$raw"

  {
    echo
    echo "[7] 时间 (偏差过大会导致 TLS 握手失败)"
    printf '  本地时间 : %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '  UTC 时间 : %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf '  时区     : %s\n' "$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 未知)"
    printf '  NTP 同步 : %s\n' "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 未知)"
    local srv now skew
    srv=$(curl -sI --max-time 8 https://www.cloudflare.com 2>/dev/null \
          | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r' | head -1)
    if [ -n "$srv" ]; then
      now=$(date +%s)
      skew=$(( now - $(date -d "$srv" +%s 2>/dev/null || echo "$now") ))
      if [ "${skew#-}" -gt 60 ] 2>/dev/null; then
        printf '  与 CF 时差 : %s 秒  <== 偏差过大, TLS 握手会失败, 执行 proxy optimize time 校时\n' "$skew"
      else
        printf '  与 CF 时差 : %s 秒\n' "$skew"
      fi
    fi
  } >> "$raw"

  {
    echo
    echo "[8] 防火墙"
    if ufw_active; then
      ufw status 2>/dev/null | head -20 | sed 's/^/  /'
    fi
    if command -v nft >/dev/null 2>&1; then
      echo "  --- nftables (前 25 行) ---"
      nft list ruleset 2>/dev/null | head -25 | sed 's/^/    /'
    fi
    echo "  --- iptables filter (前 25 行) ---"
    # 同上: 管道末尾 sed 恒 0, || 不触发。用变量判空区分"没规则"和"读不到"。
    _ipt=$(iptables -S 2>/dev/null | head -25 | sed 's/^/    /')
    [ -n "$_ipt" ] && printf '%s\n' "$_ipt" || echo "    (读不到规则)"
  } >> "$raw"

  {
    echo
    echo "[9] 协议实测 (用订阅里同一份配置, 从本机回环发起)"
    if [ "$installed" = "1" ]; then
      # 报告是纯文本, 颜色转义会变成一堆 ^[[32m。
      # 不能用管道过滤(子 shell 里 SELFTEST_* 会丢), 所以临时把颜色变量清空。
      local _g="$G" _r="$R" _n="$N"
      G=""; R=""; N=""
      selftest_protocols 2>&1
      G="$_g"; R="$_r"; N="$_n"
      echo "  小结: 通过 ${SELFTEST_PASS:-0} / 不通 ${SELFTEST_FAIL:-0} / 跳过 ${SELFTEST_SKIP:-0}"
    else
      echo "  跳过(未安装)"
    fi
  } >> "$raw"

  {
    echo
    echo "[10] 最近日志 (只挑告警/错误行)"
    found=0
    for u in xray hysteria-server sing-box proxy-sub; do
      systemctl cat "$u" >/dev/null 2>&1 || continue
      found=1
      echo "  --- ${u} ---"
      journalctl -u "$u" -n 300 --no-pager -o cat 2>/dev/null \
        | grep -iE 'error|warn|fail|fatal|refus|timeout|denied' | tail -12 | sed 's/^/    /'
      echo "    (最近 5 行原文)"
      journalctl -u "$u" -n 5 --no-pager -o cat 2>/dev/null | sed 's/^/    /'
    done
    [ "$found" = "1" ] || echo "  (无相关单元)"
  } >> "$raw"

  # 重定向失败也要接住: 以前照样删掉 raw、照样打印"已生成", 采集结果全丢。
  if diag_redact < "$raw" > "$out" && chmod 600 "$out"; then
    rm -f "$raw"
  else
    rm -f "$out" 2>/dev/null || true
    warn "诊断报告写入失败: ${out} (目录不可写?)"
    warn "原始采集结果保留在 ${raw}, 含未脱敏凭据, 请手动删除"
    return 1
  fi

  echo
  hr
  ok "诊断报告已生成: ${out}"
  hr
  echo -e "${D}全部凭据已脱敏, 可以直接把内容整段发出去。查看:${N}"
  echo "  cat ${out}"
  echo
  echo -e "${D}报告含服务器公网 IP 与端口, 外发前可自行再核对一遍${N}"
  echo
}

cmd_restart(){
  need_root
  load_state || die "尚未安装"
  local svcs=() s bad=0
  proto_on reality && svcs+=(xray)
  proto_on hy2     && svcs+=(hysteria-server)
  sb_enabled       && svcs+=(sing-box)
  [ ${#svcs[@]} -gt 0 ] || die "没有已启用的协议, 先执行: proxy wizard"
  systemctl restart "${svcs[@]}" 2>/dev/null
  # 逐个轮询, 不用固定等待: 慢机器上会误报"有服务未启动", 用户照着提示去翻日志,
  # 日志里什么都没有。
  for s in "${svcs[@]}"; do
    wait_active "$s" || bad=1
  done
  for s in "${svcs[@]}"; do
    printf '  %-16s : %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
  if [ "$bad" = "1" ]; then
    warn "有服务未启动, 查看: proxy logs <xray|hy2|sb>"
  else
    ok "全部服务已重启"
  fi
}

cmd_logs(){
  need_root
  local which="${1:-xray}" unit=""
  case "$which" in
    xray|'')             unit="xray" ;;
    hy2|hysteria)        unit="hysteria-server" ;;
    sb|singbox|sing-box) unit="sing-box" ;;
    hop|hy2-hop)         unit="hy2-hop" ;;
    # 不能把"拼错了"静默当成 xray: 用户输入 hy2hop 会看到 xray 日志,
    # 甚至被告知"xray 未安装", 排查方向直接跑偏。
    *) warn "未知日志目标: ${which} (可选 xray / hy2 / sb / hop)"; return 1 ;;
  esac
  if ! systemctl cat "${unit}.service" >/dev/null 2>&1; then
    warn "${unit} 未安装(当前协议里没有它), 可用: xray / hy2 / sb / hop"
    return 1
  fi
  journalctl -u "$unit" -f -n 50
}

# 用 DNS 协议自带的 whoami 回显「本机系统解析器在权威侧看到的出口」。
# o-o.myaddr.l.google.com 的 TXT 由 Google 权威服务器按查询来源生成,
# 不用注册账号, 也不往第三方 HTTP 服务提交任何数据。
# 它只反映 VPS 自己的系统解析器; 客户端侧有没有 DNS 泄露从这里看不见 ——
# 那是 fake-ip / 浏览器 DoH / WebRTC 的事, 得在客户端自己跑 dnsleaktest。
dns_resolver_ip(){
  local txt="" tool=""
  if command -v dig >/dev/null 2>&1; then
    tool=dig
    txt=$(timeout 8 dig +short +time=3 +tries=1 TXT o-o.myaddr.l.google.com 2>/dev/null)
  elif command -v nslookup >/dev/null 2>&1; then
    tool=nslookup
    # nslookup 会先打印 "Server: 1.1.1.1", 直接从全文抓 IP 会抓到 DNS 服务器
    # 而不是 whoami 结果, 所以先把 text = "..." 那一行单独摘出来。
    txt=$(timeout 8 nslookup -type=TXT o-o.myaddr.l.google.com 2>/dev/null \
          | sed -n 's/.*text = "\(.*\)".*/\1/p')
  fi
  [ -n "$tool" ] || return 0
  printf '%s' "$(printf '%s\n' "$txt" | tr -d '"' \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
}

# 通过本地 REALITY 隧道实测真实出口 IP
# ---------------- 本地 REALITY 隧道(临时 socks5) ----------------
# 服务端要"站在客户端的位置"看东西时反复用得到: 出口 IP、DoH 端点是否真的能用、
# 域名有没有原样送到服务端。以前这段逻辑只藏在 egress_ip_via_proxy 里, 想多测
# 一项就得整段复制一份 —— 复制出来的第二份迟早和第一份漂移。抽成 start/stop。
# 用法: tunnel_start || 失败处理; 之后用 socks5h://127.0.0.1:${TUNNEL_PORT}; tunnel_stop
TUNNEL_PORT="${TUNNEL_PORT:-10897}"
TUNNEL_DIR=""
TUNNEL_PID=""
TUNNEL_PG=0

# 隧道用的临时 xray 客户端配置(stdout)。
# 单独成一个函数: 里面有带裸 "}" 的 heredoc, 留在 tunnel_start 里会让
# "按行抽函数"的测试工具在 JSON 的收尾大括号处提前截断, 抽出来的半截函数
# 语法都不成立 —— 测试于是假红, 掩盖真正的问题。
tunnel_config_json(){
  cat <<EOF
{
  "log": { "loglevel": "error" },
  "inbounds": [ { "port": ${TUNNEL_PORT}, "listen": "127.0.0.1", "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ {
    "protocol": "vless",
    "settings": { "vnext": [ { "address": "127.0.0.1", "port": ${VLESS_PORT},
      "users": [ { "id": "$(primary_uuid)", "encryption": "none", "flow": "xtls-rprx-vision" } ] } ] },
    "streamSettings": { "network": "tcp", "security": "reality",
      "realitySettings": { "serverName": "${DEST}", "fingerprint": "${REALITY_FP:-chrome}",
        "publicKey": "${PUB}", "shortId": "${SID}", "spiderX": "/" } }
  } ]
}
EOF
}

tunnel_start(){
  tunnel_stop
  [ -x "${XRAY_BIN:-}" ] || return 1
  local d; d=$(mktemp -d 2>/dev/null) || return 1
  TUNNEL_DIR="$d"
  # setsid 让临时 xray 独立成进程组, 代价是 Ctrl-C 的 SIGINT 打不到它 ——
  # 不装 trap 就会留下一个孤儿进程长期占着 10897, 之后每次隧道都判"端口被占"。
  trap 'tunnel_stop; trap - INT TERM; exit 130' INT TERM
  # 端口被别的进程占着时, 临时 xray 会 bind 失败, 但 curl 照样能连上那个
  # "别人的" socks —— 测出来的东西完全是别人的, 还查不出原因。必须先探。
  if (exec 3<>"/dev/tcp/127.0.0.1/${TUNNEL_PORT}") 2>/dev/null; then
    tunnel_stop; trap - INT TERM; return 1
  fi
  tunnel_config_json > "$d/c.json"
  # setsid 让临时 xray 独立成进程组, 收尾时能整组杀掉, 不留孤儿进程。
  if command -v setsid >/dev/null 2>&1; then
    setsid "$XRAY_BIN" -c "$d/c.json" >"$d/c.log" 2>&1 & TUNNEL_PG=1
  else
    "$XRAY_BIN" -c "$d/c.json" >"$d/c.log" 2>&1 &
  fi
  TUNNEL_PID=$!
  # setsid 在调用方已是进程组长时会 fork, 这时 $! 是那个已经退出的 setsid,
  # 真正的 xray 是它的子进程 —— 只 kill $! 会留下孤儿。按唯一配置路径找回来。
  if [ "$TUNNEL_PG" = "1" ] && command -v pgrep >/dev/null 2>&1; then
    local _xp="" _i=0
    while [ "$_i" -lt 10 ]; do
      _xp=$(pgrep -f "xray -c ${d}/c.json" 2>/dev/null | head -1)
      [ -n "$_xp" ] && break
      sleep 0.1; _i=$((_i+1))
    done
    [ -n "$_xp" ] && TUNNEL_PID="$_xp"
  fi
  # 固定 sleep 3 有两个毛病: 慢机器上 3 秒还没起来 -> 误报"连不上";
  # 快机器上白等 3 秒。改成轮询端口就绪, 进程提前退出就立刻收尾。
  local i=0
  while [ "$i" -lt 20 ]; do
    if (exec 3<>"/dev/tcp/127.0.0.1/${TUNNEL_PORT}") 2>/dev/null; then
      trap - INT TERM
      return 0
    fi
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    sleep 0.3
    i=$((i+1))
  done
  tunnel_stop
  trap - INT TERM
  return 1
}

tunnel_stop(){
  # 只有真的 setsid 过才敢按进程组 kill: 否则负 pid 可能指向当前 shell 自己的组
  if [ -n "${TUNNEL_PID:-}" ]; then
    if [ "${TUNNEL_PG:-0}" = "1" ]; then
      local _pg _mypg
      _pg=$(ps -o pgid= -p "$TUNNEL_PID" 2>/dev/null | tr -d ' ')
      _mypg=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
      # 进程组号等于自己这组时绝不能发负信号 —— 那会把当前脚本一起杀掉。
      if [ -n "$_pg" ] && [ "$_pg" != "$_mypg" ]; then
        kill -TERM -- "-${_pg}" >/dev/null 2>&1 || true
      fi
    fi
    kill -TERM "$TUNNEL_PID" >/dev/null 2>&1 || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
  [ -n "${TUNNEL_DIR:-}" ] && rm -rf "$TUNNEL_DIR"
  TUNNEL_DIR=""; TUNNEL_PID=""; TUNNEL_PG=0
  return 0
}

# 通过本地 REALITY 隧道实测真实出口 IP(隧道起不来就返回空)
egress_ip_via_proxy(){
  tunnel_start || { printf '%s' ""; return 0; }
  local raw="" ip=""
  raw=$(curl -fsS --socks5-hostname "127.0.0.1:${TUNNEL_PORT}" --max-time 12 https://api.ipify.org 2>/dev/null) \
    || raw=$(curl -fsS --socks5-hostname "127.0.0.1:${TUNNEL_PORT}" --max-time 12 https://ifconfig.me 2>/dev/null) \
    || raw=""
  ip=$(extract_ipv4 "$raw" || true)
  tunnel_stop
  printf '%s' "${ip:-}"
}

# 等服务真的起来。固定 sleep 1 有两个毛病: 慢机器上服务还没 active 就判失败,
# 把一个本来能用的配置回滚掉; 快机器上白等。轮询最多约 6 秒, active 立刻返回。
wait_active(){
  local svc="$1" i=0
  while [ "$i" -lt 20 ]; do
    systemctl is-active --quiet "$svc" && return 0
    sleep 0.3
    i=$((i+1))
  done
  systemctl is-active --quiet "$svc"
}

# 把当前 EGRESS_URL 落到实际配置里并重启服务。客户端配置不需要改。
apply_egress(){
  # hysteria2 的 outbounds 只支持 direct/block, 没有"转发到上游代理"的能力。
  # 只开 hy2 时这个功能无解, 必须直说, 不能让人以为配好了。
  #
  # 但只在"要启用出口"时才拦。关闭出口(EGRESS_URL 为空)不需要上游代理能力,
  # 只要把 egress 从配置里摘掉重启就行 —— 以前这里无条件拦, 于是
  # "先开 reality 配了出口, 后来改成只开 hy2" 的机器执行 `proxy egress off`
  # 会被判成关闭失败并回滚, 出口永远关不掉。
  if [ -n "${EGRESS_URL:-}" ] && ! proto_on reality && ! sb_enabled; then
    warn "当前只开了 Hysteria2: 它不支持上游代理, egress 不会生效"
    warn "想用住宅出口, 请再开一个 reality 或 anytls/tuic: PROTOCOLS=reality,hy2 bash setup-proxy.sh install"
    # 必须返回失败: 调用方靠返回值决定是否报"已生效"并保留 EGRESS_URL。
    # 以前返回 0 会让 cmd_egress 打印"上游出口已生效", 但配置一行没改 ——
    # state 里躺着个假的 EGRESS_URL, audit 还以为流量走了住宅出口。
    return 1
  fi
  local bad=0
  if proto_on reality; then
    write_xray_config "${DEST:-www.bing.com}"
    systemctl restart xray >/dev/null 2>&1
    wait_active xray || bad=1
  fi
  if sb_enabled; then
    write_singbox_config
    systemctl restart sing-box >/dev/null 2>&1
    wait_active sing-box || bad=1
  fi
  # 返回验活结果, 让 cmd_egress 决定要不要回滚 state —— 以前写完就报
  # "已生效", 端口填错 / JSON 写坏时 REALITY 其实已经停了。
  return "$bad"
}

# proxy egress —— 给服务端接一层上游出口
# 这是"不被 TikTok 判机房"的唯一技术解法: 换掉最终出口 IP, 而不是改协议/端口/SNI。
cmd_egress(){
  need_root
  load_state || die "尚未安装"
  local arg="${1:-}" line scheme host port ip old_egress="${EGRESS_URL:-}"

  if [ -z "$arg" ]; then
    if [ -n "${EGRESS_URL:-}" ]; then
      # parse_egress 失败时 && 短路, scheme/host/port 从未赋值 —— set -u 下
      # 直接 "scheme: unbound variable" 把整个脚本带走, 用户看到的是一行
      # bash 内部报错。这里先判成败再取值。
      if line=$(parse_egress); then
        IFS='|' read -r scheme host port _ <<< "$line"
        echo "上游出口      : ${scheme}://${host}:${port}   (账号密码已隐藏)"
        ip=$(egress_probe_ip)
        if [ -n "$ip" ]; then
          ok "实测出口 IP   : ${ip}"
          [ "$ip" = "$SERVER_IP" ] && warn "和本机 IP 相同, 这个代理没有真正改变出口"
        else
          warn "上游出口当前不通(地址失效 / 账号过期 / 本机到它被墙)"
        fi
      else
        # EGRESS_URL 形如 socks5://用户:密码@主机:端口, 原样回显等于把密码
        # 打进终端和 /var/log/proxy-deploy.log; diag 里专门做了脱敏, 这里对齐。
        warn "state 里的 EGRESS_URL 无法解析(含密码, 不回显原值); 请用 proxy egress 重设"
        echo "  重新设置: proxy egress socks5://用户:密码@主机:端口"
        echo "  关闭出口: proxy egress off"
      fi
    else
      info "未配置上游出口, 流量直接从本机 ${SERVER_IP} 出去"
      echo "  换住宅出口: proxy egress socks5://用户:密码@主机:端口"
      echo "  关闭出口  : proxy egress off"
    fi
    return 0
  fi

  case "$arg" in
    off|none|clear)
      [ -n "${EGRESS_URL:-}" ] || { info "本来就没配上游出口"; return 0; }
      EGRESS_URL=""
      save_state
      if ! apply_egress; then
        # 和"设置出口"分支一样: state.env 已写"无出口", 但服务没起来 ——
        # 配置里可能还挂着旧上游, 下次重启行为就和 state 对不上了。报失败并回滚,
        # 别打印"已关闭"让人以为成功。
        EGRESS_URL="$old_egress"
        apply_egress || warn "回滚出口后服务仍未启动, 请检查: proxy status / journalctl -u xray -n 30"
        save_state
        die "关闭上游出口时服务未能启动, 已回滚到之前的出口设置"
      fi
      ok "已关闭上游出口, 恢复本机直连"
      return 0 ;;
  esac

  # 配置是直接拼进 JSON 的, 引号和反斜杠会把整份配置写坏, 提前拦住
  case "$arg" in
    *'"'*|*\\*|*"'"*) die "地址里不能包含双引号 / 反斜杠 / 单引号" ;;
  esac
  if ! line=$(parse_egress "$arg"); then
    die "地址格式不对, 应形如 socks5://用户:密码@1.2.3.4:1080 或 http://用户:密码@1.2.3.4:8080"
  fi
  EGRESS_URL="$arg"
  info "测试上游出口连通性 ..."
  ip=$(egress_probe_ip)
  if [ -z "$ip" ]; then
    EGRESS_URL=""
    die "连不上这个上游代理: 检查地址/端口/账号密码, 以及本机到它是否可达"
  fi
  save_state
  if ! apply_egress; then
    # 配置已经写进 xray / sing-box 但服务没起来。不把 EGRESS_URL 退回原值的话,
    # 下次 load_state 会一直带着一个让服务起不来的出口, 且屏幕上刚报过"成功"。
    EGRESS_URL="$old_egress"
    apply_egress || warn "回滚出口后服务仍未启动, 请检查: proxy status / journalctl -u xray -n 30"
    save_state
    # 只开 hy2 时 apply_egress 因"不支持上游代理"返回 1, 不是服务真没起来 ——
    # 报错要说准, 否则用户照着"检查地址端口"查半天也找不到问题。
    if ! proto_on reality && ! sb_enabled; then
      die "当前只开了 Hysteria2, 不支持上游代理; 未保存出口设置 (需再开 reality 或 anytls/tuic)"
    fi
    die "上游出口已写入但服务未能启动, 已回滚到之前的出口设置; 检查地址、端口与凭据"
  fi
  # 上面那个 ip 是"直连上游代理"测出来的, 只能证明代理本身通, 证明不了
  # 服务端真的把流量交给它了 —— egress 没被放到 outbounds 首位、routing 把它
  # 绕过、配置写坏但旧进程还在跑, 这三种情况都会让上一步看起来成功。
  # 先走一次真实 REALITY 隧道复测, 再决定要不要报"已生效"。
  local eip="" verified=0
  if proto_on reality; then
    info "通过隧道复测实际出口 ..."
    eip=$(egress_ip_via_proxy)
    [ -n "$eip" ] && [ "$eip" = "$ip" ] && verified=1
  fi
  if [ "$verified" = "1" ]; then
    ok "上游出口已生效, 隧道实测出口 IP: ${eip}"
  elif [ -n "$eip" ]; then
    warn "上游代理可达(${ip}), 但隧道实际出口是 ${eip} —— 流量没有走上游出口"
    echo "   检查 xray 是否在跑新配置: journalctl -u xray -n 30"
  elif proto_on reality; then
    warn "上游代理可达(${ip}), 但隧道复测失败, 无法确认流量是否走了它"
    echo "   先确认节点本身能用: proxy status"
  else
    ok "上游出口已写入配置(未启用 REALITY, 无法走隧道复测; 直连实测代理出口 ${ip})"
  fi
  if [ "$ip" = "$SERVER_IP" ]; then
    warn "出口 IP 和本机相同, 说明这个代理是透明转发, 对平台判定没有帮助"
  fi
  # Hysteria2 由独立的 hysteria 进程承载, 跟 xray / sing-box 的 outbounds 无关,
  # 所以它一定绕开上游出口。两个协议都开的时候以前只字未提, 用户会以为
  # 两个节点都换了住宅 IP —— 实际用 hy2 那条线照样是机房 IP。
  if proto_on hy2; then
    warn "Hysteria2 不支持上游代理: 它的流量仍从 ${SERVER_IP} 直出, 不受本次设置影响"
    echo "   要让 hy2 也换出口, 只能用 reality / anytls / tuic 那几条线"
  fi
  echo "  用 proxy audit 看这个 IP 的机房/代理标记"
}

# ---------------- 客户端 DNS 泄露: 服务端能验证的那部分 ----------------
# 先说清边界: 浏览器/系统最终用了哪个 DNS, 是客户端本机的事, 服务端看不见。
# 所以这里不假装"测到了客户端", 只做三件真能验证的事:
#   1) 订阅产物里的 DNS 配置是否齐全(读真实文件, 不是查源码里有没有那个字符串)
#   2) 订阅里配的 DoH 端点经隧道是否真的能解析(端到端, 而不是"看起来配了")
#   3) 经隧道取的出口 IP 与直连出口是否不同(证明解析与出口同源)
# 测不到的部分在末尾打印成客户端清单, 不混进"通过"里。
sub_dns_issues(){
  local d="${1:-}" n=0 f nsblock
  f="$d/clash.yaml"
  if [ -f "$f" ]; then
    grep -qE 'enhanced-mode:[[:space:]]*fake-ip' "$f" || { echo "clash.yaml 没开 fake-ip"; n=$((n+1)); }
    # nameserver 段里**每一条**都必须经代理。只查"文件里有 #PROXY"会漏掉
    # "两条 nameserver 只丢了一条" 这种半截回归 —— 剩下的那条照样本地解析,
    # DNS 泄露该发生还是发生, 检查却报通过。
    nsblock=$(awk '/^[[:space:]]*nameserver:[[:space:]]*$/{f=1;next} f&&/^[[:space:]]*-[[:space:]]/{print;next} f{exit}' "$f")
    if [ -z "$nsblock" ]; then
      echo "clash.yaml 缺 nameserver 段"; n=$((n+1))
    elif printf '%s\n' "$nsblock" | grep -qv '#PROXY'; then
      echo "clash.yaml 有 nameserver 条目没经代理(#PROXY), 该条会本地解析"; n=$((n+1))
    fi
    grep -q 'nameserver-policy:' "$f" || { echo "clash.yaml 缺 nameserver-policy(国内域名会绕远)"; n=$((n+1)); }
    grep -q 'geosite:cn' "$f" || { echo "clash.yaml 的 nameserver-policy 没覆盖国内域名"; n=$((n+1)); }
    grep -q 'proxy-server-nameserver:' "$f" || { echo "clash.yaml 缺 proxy-server-nameserver(解析节点域名会走系统 DNS)"; n=$((n+1)); }
    grep -qE '^ipv6:[[:space:]]*false' "$f" || { echo "clash.yaml 没关 IPv6(AAAA 会绕过代理)"; n=$((n+1)); }
  else
    echo "clash.yaml 不存在"; n=$((n+1))
  fi
  f="$d/shadowrocket.conf"
  if [ -f "$f" ]; then
    grep -q '^dns-server = https://doh.pub/dns-query' "$f" || { echo "shadowrocket.conf 的 dns-server 不是国内 DNS(抖音会解析到境外节点)"; n=$((n+1)); }
    if grep -q '#proxy=' "$f"; then echo "shadowrocket.conf 的 dns-server 经代理(#proxy=), 直连域名会拿境外节点"; n=$((n+1)); fi
    grep -q '^direct-dns-server = ' "$f" || { echo "shadowrocket.conf 缺 direct-dns-server"; n=$((n+1)); }
    grep -q '^hijack-dns = 8.8.8.8:53,8.8.4.4:53$' "$f" || { echo "shadowrocket.conf 的 hijack-dns 不是官方值(:53 劫持全部 DNS, 国内域名被拖走)"; n=$((n+1)); }
    grep -q '^dns-direct-system = false$' "$f" || { echo "shadowrocket.conf 允许系统 DNS 直连"; n=$((n+1)); }
    grep -q '^fallback-dns-server = ' "$f" || { echo "shadowrocket.conf 缺官方 fallback-dns-server 字段"; n=$((n+1)); }
    grep -q '^FINAL,PROXY,force-remote-dns$' "$f" || { echo "shadowrocket.conf 缺 force-remote-dns 兜底(域名会在本地解析)"; n=$((n+1)); }
    grep -qE '^ipv6 = false$' "$f" || { echo "shadowrocket.conf 没关 IPv6"; n=$((n+1)); }
  else
    echo "shadowrocket.conf 不存在"; n=$((n+1))
  fi
  f="$d/singbox.json"
  if [ -f "$f" ]; then
    grep -q '"final": "remote"' "$f" || { echo "singbox.json 的 DNS 没走 remote(等于本地解析)"; n=$((n+1)); }
    grep -q '"hijack-dns"' "$f" || { echo "singbox.json 没劫持 DNS"; n=$((n+1)); }
    grep -q '"strategy": "ipv4_only"' "$f" || { echo "singbox.json 没限 ipv4_only(AAAA 会绕过)"; n=$((n+1)); }
    grep -q '"outbound": "direct"' "$f" || { echo "singbox.json 没有国内直连域名规则(国内站会绕代理)"; n=$((n+1)); }
    if grep -q '"tag": "remote"[^}]*"detour": "direct"' "$f"; then
      echo "singbox.json 的 remote DNS 走了 direct(等于本地解析)"; n=$((n+1))
    fi
  else
    echo "singbox.json 不存在"; n=$((n+1))
  fi
  return "$n"
}

# DoH 端点是否真的能解析。$1=URL  $2=socks 代理(空=直连)
# 判据必须是 Status:0 且带 Answer: 只判"有响应"会把 403/限流页当成成功 ——
# 这正是本项目之前踩过的坑(拿限流页当出口 IP)。
doh_ok(){
  local url="$1" via="${2:-}" out
  if [ -n "$via" ]; then
    out=$(curl -fsS --socks5-hostname "$via" -H 'accept: application/dns-json' --max-time 10 "$url" 2>/dev/null)
  else
    out=$(curl -fsS -H 'accept: application/dns-json' --max-time 8 "$url" 2>/dev/null)
  fi
  [ -n "$out" ] || return 1
  case "$out" in
    *'"Status":0'*|*'"Status": 0'*) ;;
    *) return 1 ;;
  esac
  case "$out" in
    *'"Answer"'*) return 0 ;;
  esac
  return 1
}

# 客户端侧自检清单: 纯文本、不带颜色。
# 不带颜色是有意的 —— 这份内容用户会从终端复制到手机上看, ANSI 转义会跟着
# 一起粘过去变成乱码。窄行宽也是同一个原因(手机屏幕)。
print_client_checklist(){
  local base=""
  if [ "${SUB_HTTP:-0}" = "1" ] && [ -n "${SUB_TOKEN:-}" ]; then
    if [ "${SUB_BIND:-127.0.0.1}" = "127.0.0.1" ]; then
      base="http://127.0.0.1:${SUB_PORT:-}/${SUB_TOKEN}"
    else
      base="http://${SERVER_IP}:${SUB_PORT:-}/${SUB_TOKEN}"
    fi
  fi

  cat <<TXT
================= DNS 泄露自检 · 客户端 =================

服务端只能验配置齐全、端点可用。你手机/电脑上到底用了哪个 DNS,
只有客户端自己知道, 所以这一步必须你亲手做一次。

【订阅地址】(含 token, 等同密码, 别发给任何人)
TXT
  if [ -n "$base" ]; then
    echo "  小火箭 : ${base}/shadowrocket.conf"
    echo "  Clash  : ${base}/clash.yaml"
    echo "  v2rayN : ${base}/v2rayn-routed.json"
  else
    echo "  未开启 HTTP 订阅。用 FinalShell 文件面板把这三个文件"
    echo "  下载到本机再导入:"
    echo "    shadowrocket.conf / clash.yaml / v2rayn-routed.json"
    echo "  路径: ${SUB_DIR:-/var/www/proxy-sub}/${SUB_TOKEN:-<token>}/"
  fi
  cat <<'TXT'

【第 1 步】导入"对的那份"
  x 不要用 base64.txt / v2rayn.txt 纯链接 —— 它们是纯节点列表,
    不带任何 DNS 配置, 导入后等于用本地运营商 DNS。
  x 不要用 singbox.json 跑 Clash, 那是给 sing-box 内核的。

  小火箭 : 用 shadowrocket.conf (配置 -> 添加 -> 从 URL 下载)
  Clash  : 用 clash.yaml      (Clash Verge / mihomo 内核)
  v2rayN : 用 v2rayn-routed.json (不是 v2rayn.txt)

【第 2 步】确认开关(漏一个就漏)
  小火箭 : 设置 -> DNS -> "DNS 覆写" 留空(配置里已带);
           全局路由 = 配置; 不要开"绕过大陆"以外的自定义规则。
  Clash  : 模式选"规则"; TUN 模式必须开(UDP 走 TUN 才不漏 WebRTC);
           不要改成 redir-host(会退回本地解析)。
  v2rayN : 路由选"使用配置文件"; 内核用 sing-box;
           别选"绕过大陆"以外的自定义路由。

【第 3 步】跑检测(连上代理之后)
  1) https://dnsleaktest.com   点 Standard test
  2) https://ipleak.net        看 DNS Addresses 和 WebRTC 两栏
  3) https://browserleaks.com/webrtc

【判定】
  通过 : 解析器只出现 VPS 所在地区的运营商/机房, 且没有你的真实 IP
  失败 : 出现"中国电信/联通/移动"、"阿里/腾讯 DNS"、你家宽带出口 IP

【失败对照】
  DNS 里出现国内运营商
    -> 大概率用了纯链接, 或客户端开了"绕过大陆"以外的直连规则。
  WebRTC 里出现真实 IP
    -> Clash 没开 TUN, 或小火箭没开"全局代理"; STUN 拦截没生效。
  检测站打不开
    -> 先确认代理本身通(proxy status / proxy selftest), 再查 DNS。

【重要】判定 Google 地区要看出口国家做基准,
  别看到 google.com.hk 就以为被"送中" —— 香港节点本来就跳香港。
TXT
  if proto_on reality && ! sb_reality_ok; then
    cat <<'TXT'

【注意】服务端 Xray 26.9.8+ 的 REALITY 与 sing-box 内核不兼容(上游 #4520)
  v2rayN 用 sing-box 内核导入 v2rayn-routed.json 时 REALITY 节点必然连不上,
  所以那份配置已默认走 HY2。想用 REALITY 就把 v2rayN 的内核换成 Xray,
  导入 v2rayn.txt / links.txt(纯链接, 路由要自己配)。
  Clash/mihomo(clash.yaml)与 xray 内核客户端不受影响。
TXT
  fi
  echo
  echo "（这份清单可以存下来: proxy dnstest --client > dns-check.txt）"
}

cmd_dnstest(){
  need_root
  load_state || die "尚未安装"
  local tdir="${SUB_DIR:-/var/www/proxy-sub}/${SUB_TOKEN:-}"
  local bad=0 mode="full" a
  for a in "$@"; do
    case "$a" in
      --client|-c) mode="client" ;;
      --all|-a)    mode="full" ;;
    esac
  done
  # --client 只输出清单, 不跑服务端检查: 用户可能正在手机上操作,
  # 只想看"下一步点哪里", 不想再读一遍服务端结论。
  if [ "$mode" = "client" ]; then
    print_client_checklist
    return 0
  fi

  echo
  hr
  echo -e "${M}DNS 泄露自检${N}   ${D}只测服务端能验证的; 客户端侧见末尾清单${N}"
  hr

  echo
  echo -e "${B}1. 订阅产物 DNS 配置${N}"
  if [ -z "${SUB_TOKEN:-}" ] || [ ! -d "$tdir" ]; then
    echo -e "  ${Y}跳过${N}: 没找到订阅目录(执行 proxy sub 重新生成)"
    bad=1
  else
    local issues n
    issues=$(sub_dns_issues "$tdir")
    n=$?
    if [ "$n" = "0" ]; then
      printf '  %b%-8s%b clash / shadowrocket / sing-box 三端 DNS 配置齐全\n' "$G" "通过" "$N"
    else
      printf '  %b%-8s%b 发现 %s 处问题:\n' "$R" "缺失" "$N" "$n"
      printf '%s\n' "$issues" | sed 's/^/      - /'
      echo -e "  ${Y}执行 proxy sub 重新生成订阅${N}"
      bad=1
    fi
  fi

  echo
  echo -e "${B}2. DoH 端点实测${N}  ${D}(订阅里配的解析器是否真的能用)${N}"
  local via="" tun=0 raw=""
  if proto_on reality; then
    if tunnel_start; then
      tun=1; via="127.0.0.1:${TUNNEL_PORT}"
    else
      echo -e "  ${Y}隧道起不来${N}: 境外 DoH 无法验证(先 proxy status 看服务是否在跑)"
    fi
  else
    echo -e "  ${D}未启用 REALITY, 跳过隧道内测试(该项走 VLESS/REALITY 链路)${N}"
  fi
  # 境外 DoH 只在隧道里测。没有隧道时"直连测"在国内 VPS 上必然失败 ——
  # 那是噪音不是信号: 报红只会让人以为配置坏了, 实际是"没条件验证"。
  # 这种情况明确写"未验证", 不掺进通过/失败里。
  if [ -n "$via" ]; then
    if doh_ok "https://cloudflare-dns.com/dns-query?name=example.com&type=A" "$via"; then
      printf '  %b%-8s%b Cloudflare DoH (经隧道)\n' "$G" "通过" "$N"
    else
      printf '  %b%-8s%b Cloudflare DoH 经隧道解析失败\n' "$R" "失败" "$N"; bad=1
    fi
    if doh_ok "https://dns.google/dns-query?name=example.com&type=A" "$via"; then
      printf '  %b%-8s%b Google DoH (经隧道)\n' "$G" "通过" "$N"
    else
      printf '  %b%-8s%b Google DoH 经隧道解析失败\n' "$R" "失败" "$N"; bad=1
    fi
  else
    printf '  %b%-8s%b 境外 DoH 未验证(需要隧道; 直连测在国内 VPS 上必然失败, 没有意义)\n' "$Y" "未验证" "$N"
  fi
  if doh_ok "https://doh.pub/dns-query?name=www.taobao.com&type=A" ""; then
    printf '  %b%-8s%b 国内 doh.pub 直连解析\n' "$G" "通过" "$N"
  else
    printf '  %b%-8s%b 国内 doh.pub 解析失败(国内站点会变慢或打不开)\n' "$Y" "注意" "$N"
  fi

  echo
  echo -e "${B}3. 出口与解析是否同源${N}"
  local direct_ip="" tun_ip=""
  direct_ip=$(get_server_ip 2>/dev/null)
  if [ "$tun" = "1" ]; then
    raw=$(curl -fsS --socks5-hostname "127.0.0.1:${TUNNEL_PORT}" --max-time 12 https://api.ipify.org 2>/dev/null) || raw=""
    tun_ip=$(extract_ipv4 "$raw" || true)
  fi
  echo "  直连出口 IP    : ${direct_ip:-未取到}"
  if [ -n "$tun_ip" ]; then
    echo "  隧道出口 IP    : ${tun_ip}"
    if [ -n "${EGRESS_URL:-}" ]; then
      ok "已配上上游出口, 隧道出口与直连不同属正常"
    elif [ "$tun_ip" = "$direct_ip" ]; then
      ok "隧道出口与直连一致, 无额外中转"
    else
      warn "隧道出口与直连不一致(${tun_ip} != ${direct_ip}), 有中转或存在泄漏"
      bad=1
    fi
  else
    echo -e "  ${D}隧道出口 IP    : 未测到(未启用 REALITY 或隧道失败)${N}"
  fi
  tunnel_stop

  echo
  echo -e "${B}4. 客户端侧(服务端测不到, 必须自己做)${N}"
  cat <<'CLIENT'
  连上代理后, 分别打开下面两个站, 结果里只能出现 VPS 所在地区的解析器:
    https://dnsleaktest.com     (Standard test, 看结果表里的国旗/ISP)
    https://ipleak.net          (看 DNS Addresses 与 WebRTC 两栏)
  判定: 出现"中国电信/联通/移动"或你家宽带出口 IP = 泄露。

  小火箭 : 用订阅里的 shadowrocket.conf(不要用纯链接), 设置里"DNS 覆写"留空即可,
           配置本身已带国内 dns-server(直连域名就近)与 force-remote-dns(境外域名远端解析)。
  Clash  : 用 clash.yaml, 不要自己改成 redir-host; TUN 模式必须开(否则 UDP 直连漏 WebRTC)。
  v2rayN : 导入 v2rayn-routed.json(不要用纯链接), 它已带 fake-ip 与 STUN 拦截。
CLIENT

  echo
  if [ "$bad" = "0" ]; then
    ok "服务端侧全部通过; 客户端请按上面第 4 节自查一次"
  else
    warn "有未通过项, 见上面标记"
  fi
  return "$bad"
}

cmd_audit(){
  need_root
  load_state || die "尚未安装"
  local dnsbl=0
  [ "${1:-}" = "--dnsbl" ] && dnsbl=1
  # 换过 IP 的机器上, state.env 里存的是旧地址, 拿它查 PTR / 地区 / 时区比对
  # 全是错的。以本机当前探测到的为准, 并提示用户链接还是旧的。
  local live_ip
  live_ip=$(get_server_ip 2>/dev/null)
  if [ -n "$live_ip" ] && [ -n "$SERVER_IP" ] && [ "$live_ip" != "$SERVER_IP" ]; then
    warn "本机公网 IP 已变化: ${SERVER_IP} -> ${live_ip}"
    echo -e "  ${D}订阅链接里仍是旧 IP; 确认无误后执行 proxy install 重新生成${N}"
    SERVER_IP="$live_ip"
  fi
  SERVER_IP="${SERVER_IP:-$live_ip}"

  echo
  hr
  echo -e "${M}出口 IP 实测${N}"
  hr
  echo "节点 IP        : ${SERVER_IP}"
  # egress_ip_via_proxy 起的是 VLESS/REALITY 临时客户端; 只开 hy2 / ss2022 的
  # 机器上它必然失败 —— 那是"这个协议没启用", 不是"服务坏了", 不能报成故障。
  local eip=""
  proto_on reality && eip=$(egress_ip_via_proxy)
  if ! proto_on reality; then
    echo -e "  ${D}未启用 REALITY, 跳过隧道出口实测(该项探测走 VLESS/REALITY 链路)${N}"
  elif [ -z "$eip" ]; then
    warn "隧道实测失败, 无法确认出口(检查服务是否正常: proxy status)"
  elif [ "$eip" = "$SERVER_IP" ]; then
    ok "隧道出口 IP    : ${eip}  (与本机一致, 无中转/无泄漏)"
  else
    if [ -n "${EGRESS_URL:-}" ]; then
      ok "隧道出口 IP    : ${eip}  (已配置上游出口, 与本机 ${SERVER_IP} 不同, 符合预期)"
    else
      warn "隧道出口 IP    : ${eip}  (与本机 ${SERVER_IP} 不同!)"
      echo "   说明流量经过了中转或存在泄漏, TikTok 会看到 ${eip} 这个地址"
    fi
  fi

  echo
  hr
  echo -e "${M}DNS 解析归属实测${N}"
  hr
  # 服务端能测的是「自己的解析路径」和「域名有没有真的交给远端解析」。
  # 客户端侧 DNS 泄露(浏览器 DoH / 系统 DNS 绕过 fake-ip)从 VPS 上看不见,
  # 这里不假装测得到, 只把客户端侧验证清单写清楚。
  local sysdns="" resolver=""
  sysdns=$(awk '/^[[:space:]]*nameserver/{printf "%s%s", (n++?" ":""), $2} END{print ""}' \
           /etc/resolv.conf 2>/dev/null)
  echo "本机系统解析器 : ${sysdns:-读取失败}"
  if proto_on reality && [ -r "${XRAY_CFG:-}" ]; then
    if grep -q '"dns"' "$XRAY_CFG"; then
      ok "服务端内置 DNS : 已启用 (1.1.1.1 / 8.8.8.8, UseIPv4, 不再回落系统解析器)"
    else
      warn "服务端内置 DNS : 已回退系统解析(当前 Xray 不认内置 DNS 块) —— 域名会走上面那几个 nameserver"
    fi
  else
    echo -e "  ${D}未启用 REALITY 或配置不可读, 跳过 Xray 内置 DNS 检查${N}"
  fi
  resolver=$(dns_resolver_ip)
  if [ -n "$resolver" ]; then
    echo "解析器出口     : ${resolver}  (whoami TXT 回显; 这是递归解析器的地址, 不是 VPS IP)"
  else
    echo -e "  ${D}解析器出口     : 未查到(缺 dig/nslookup 或查询超时), 跳过${N}"
  fi
  if [ -n "$eip" ]; then
    ok "远端域名解析   : 已验证 —— 上面的出口 IP 经 socks5-hostname 取得, 域名由服务端解析"
  else
    echo -e "  ${D}远端域名解析   : 本次未验证(没启用 REALITY / 隧道实测失败)${N}"
  fi
  if [ -n "${EGRESS_URL:-}" ]; then
    warn "上游出口提示   : DNS 查询仍由 VPS 直发, 不经 egress —— 解析地区可能与出口地区不一致"
  fi
  echo -e "  ${D}客户端侧请自行验证(先跑 proxy dnstest 看服务端侧是否齐全): 用浏览器打开 https://dnsleaktest.com 与 https://ipleak.net ,${N}"
  echo -e "  ${D}结果里应只出现 VPS 所在地区的解析器, 不能出现国内运营商 DNS 或本机内网 IP。${N}"

  echo
  hr
  echo -e "${M}IP 画像${N}"
  hr
  local ptr
  ptr=$(getent hosts "$SERVER_IP" 2>/dev/null | awk '{print $2}' | head -1)
  if [ -n "$ptr" ]; then
    echo "反向解析 PTR   : ${ptr}"
  else
    warn "反向解析 PTR   : 无记录 (会提高可疑度, 可找服务商加一条)"
  fi

  local ipv6pub
  ipv6pub=$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)
  if [ "${ipv6pub:-0}" -gt 0 ]; then
    warn "公网 IPv6      : 存在 ${ipv6pub} 个地址 (客户端订阅已按 IPv4 优先生成; 代理端口可能同时监听 IPv6, 建议在服务商侧关掉)"
  else
    ok "公网 IPv6      : 无 (不会出现 IPv6 泄漏)"
  fi

  # 平台看 IP 不只看归属公司, 更看"这段是不是机房"。ip-api 的 hosting 字段
  # 是一个参考口径, 和 TikTok / Google 各自的风控库不一定一致 ——
  # 实测同一台 RackNerd 机器这里给 hosting=false, 平台侧仍按机房处理。
  # 所以这里只作参考, 不作结论。
  # 有上游出口时要查"平台真正看到的那个 IP", 查本机 IP 没有意义。
  #
  # 一次请求把后面几节要用的字段全取回来(countryCode 给 Google 判定用,
  # timezone 给时区一致性用)。免费接口 45 次/分钟, 每节各查一次很容易被限速。
  local ipq="${eip:-$SERVER_IP}"
  local pr hst prx mob cc etz
  pr=$(curl -s --max-time 6 "http://ip-api.com/line/${ipq}?fields=hosting,proxy,mobile,countryCode,timezone" 2>/dev/null | tr -d '\r')
  hst=$(printf '%s\n' "$pr" | sed -n 1p)
  prx=$(printf '%s\n' "$pr" | sed -n 2p)
  mob=$(printf '%s\n' "$pr" | sed -n 3p)
  cc=$(printf '%s\n' "$pr" | sed -n 4p | tr '[:lower:]' '[:upper:]')
  etz=$(printf '%s\n' "$pr" | sed -n 5p)
  # 校验: 接口失败时会返回 "fail" 或空行, 别让这些值流到下游
  case "$cc" in [A-Z][A-Z]) ;; *) cc="" ;; esac
  case "$etz" in */*) ;; *) etz="" ;; esac
  if [ -n "$cc" ]; then
    echo "出口国家/地区  : ${cc}$(cc_note "$cc")"
  fi
  # PTR 机房特征先算好, 供下面各分支共用(不用再发请求)。两段匹配: 先认机房
  # 品牌名(出现在哪都算), 再认带边界的通用词(vps/server/dedicated...), 避免误伤。
  local ptr_host=0
  if printf '%s' "$ptr" | grep -qiE '(hostpapa|colocrossing|psychz|quadranet|vultr|linode|digitalocean|contabo|hetzner|amazonaws|choopa|buyvm|racknerd|hosthatch|netcup|leaseweb|serverius|worldstream|melbicom|aeza|justhost|oraclecloud|alibabacloud|tencentcloud|(^|[^a-z])(vps|vds|dedicated|bare-?metal|colo|hosting|cloud|server)([^a-z]|$))'; then
    ptr_host=1
  fi
  case "$hst" in
    true)
      warn "IP 类型        : 机房段 (hosting=true) —— 平台大概率按机房处理, 换协议换端口都改不了" ;;
    false)
      # hosting=false 不能当绿灯: 实测 RackNerd 这类机器 ip-api 报 false, 平台仍按
      # 机房处理。只有 PTR 也不带机房特征时, 才给"可能更接近家宽"的弱结论。
      if [ "$ptr_host" = "1" ]; then
        warn "IP 类型        : ip-api 报非机房, 但 PTR \"${ptr}\" 含机房品牌 —— 平台大概率仍按机房处理"
      else
        echo "IP 类型        : ip-api 报非机房(hosting=false, 仅供参考); 平台另有数据库, 以实际表现为准"
      fi ;;
    *)
      # ip-api 免费接口会限速, 也会对部分网段直接不返回。此时用本地 PTR 作第二信号。
      if [ "$ptr_host" = "1" ]; then
        warn "IP 类型        : 疑似机房段 (ip-api 无返回, 按 PTR \"${ptr}\" 推断)"
        echo "   依据: 主机名含机房品牌或通用词。这是本地推断, 平台侧结论以实际表现为准"
      else
        echo "IP 类型        : 查询失败(接口限速或不可达), PTR 也看不出机房特征"
      fi ;;
  esac
  [ "$prx" = "true" ] && warn "代理标记       : 已被标为 proxy/VPN (比机房标记更难绕)"
  [ "$mob" = "true" ] && echo "移动网络标记   : mobile=true"

  # Google 的"送中"是它按出口 IP 判地区。服务端直连一次就能看出它怎么认这台机器。
  # 这里踩过三个坑, 都会把"已经送中"误报成"正常":
  #  ① 连不上(HTTP 000) 和 连上但没跳转 是两回事 —— 只看 redirect_url 会把前者当成后者
  #  ② Google 现在多数情况不再回 302, 而是回 200 + 页面里 JS 跳转。只看 header 必然漏报
  #  ③ 只发 Accept-Language: en-US。真实浏览器发的是 zh-CN, Google 对"IP 归属模糊 +
  #     中文用户"会额外偏向港区 —— 拿 en-US 探等于替用户美颜。同时 curl 默认 UA 是
  #     curl/8.x, Google 见到就给一套更保守的响应。
  # 所以: 用真实 UA, 先 zh-CN 再 en-US, 每次先看 header 跳转、再看页面里的 ccTLD 域名,
  # 任一命中即判定。gdom 记命中的域名, gsrc 记是 header 还是页面命中的(输出要诚实)。
  local gcode="" gdom="" gsrc="" _lang _r _c _h
  for _lang in 'zh-CN,zh;q=0.9' 'en-US,en;q=0.9'; do
    _r=$(curl -s -o /dev/null -w '%{http_code}|%{redirect_url}' --max-time 8 \
         -H "Accept-Language: ${_lang}" \
         -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
         'https://www.google.com/' 2>/dev/null)
    _c=$(printf '%s' "$_r" | cut -d'|' -f1)
    [ -n "$_c" ] && [ "$_c" != "000" ] && gcode="$_c"
    _h=$(printf '%s' "$_r" | cut -d'|' -f2-)
    [ -n "$_h" ] && gsrc="header"
    if [ -z "$_h" ] && [ -n "$_c" ] && [ "$_c" != "000" ]; then
      _h=$(curl -s --max-time 8 -H "Accept-Language: ${_lang}" \
           -A 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
           'https://www.google.com/' 2>/dev/null | head -c 40000 \
           | grep -oE "$GOOGLE_TLD_RE" \
           | head -1)
      [ -n "$_h" ] && gsrc="页面"
    fi
    if [ -n "$_h" ]; then
      gdom=$(printf '%s' "$_h" | sed -E 's#^https?://##; s#^www\.##; s#[/"].*$##')
      break
    fi
  done
  case "${gcode:-000}" in
    000|"")
      warn "Google 地区    : 连不上 (HTTP ${gcode:-000}), 无法判定 —— 先修出口: proxy status" ;;
    *)
      # 判"有没有被换区"要拿出口国家做基准, 不能把 google.com.hk 一律当送中。
      # 香港 / 澳门的机器 Google 本来就该跳 .com.hk, 一律报送中等于 100% 误报。
      if [ "$cc" = "CN" ]; then
        # 出口在中国大陆 = 流量根本没出去, 这时看 Google 跳哪个域名没意义
        warn "Google 地区    : 出口 IP 在中国大陆 —— 代理没生效, 或 egress 指到了国内中转"
      else
        local gwant
        gwant=$(google_cc_tld "$cc")
        case "$gdom" in
          # google.cn 是 Google 中国的残骸, 现在一律跳 .com.hk。见到它就是送中。
          google.cn)
            warn "Google 地区    : 被判为中国大陆 (${gsrc}跳 ${gdom}) —— 这台机器的 IP 在 Google 库里是 CN" ;;
          google.com.hk)
            # ip-api 被限速 / 无返回时 cc 为空, 这时既不知道出口是不是 HK,
            # 也不该拿"预期 google.com"当基准去断言 Google 判成了 CN ——
            # 以前这里会直接报"被判为中国大陆", 属于没有依据的假红。
            if [ -z "$cc" ]; then
              echo "Google 地区    : ${gsrc}跳 ${gdom} (出口国家没查到, 无法判定是否换区; 稍后重跑 proxy audit)"
            elif [ "$cc" = "HK" ] || [ "$cc" = "MO" ]; then
              ok "Google 地区    : 跳 ${gdom} —— 出口在 ${cc}, 这是当地域名, 正常"
            else
              warn "Google 地区    : 被判为中国大陆 (${gsrc}跳 ${gdom}) —— 出口登记在 ${cc}, 但 Google 判成 CN"
            fi ;;
          # 跳到 google.com 本身(带 gws_rd=cr 那种)等于"Google 决定不换区", 属正常。
          # 不这么判的话, 一条"跳转到 google.com"的噪音会让人以为出了事。
          ""|google.com)
            if [ -z "$cc" ]; then
              echo "Google 地区    : 未跳转 (HTTP ${gcode}, 出口国家没查到, 无法比对)"
            elif [ "$gwant" = "google.com" ]; then
              ok "Google 地区    : 未跳转 (HTTP ${gcode}) —— 出口 ${cc}, 这个国家本来就用 google.com"
            else
              ok "Google 地区    : 未跳转 (HTTP ${gcode}) —— 出口 ${cc}, 预期 ${gwant} 但 Google 没换区, 通常没问题"
            fi ;;
          *)
            if [ "$gdom" = "$gwant" ]; then
              ok "Google 地区    : ${gsrc}跳 ${gdom} —— 与出口 ${cc} 一致, 正常"
            elif [ -z "$cc" ]; then
              echo "Google 地区    : ${gsrc}跳转到 ${gdom} (HTTP ${gcode}, 出口国家没查到, 无法比对)"
            else
              warn "Google 地区    : ${gsrc}跳 ${gdom}, 但出口在 ${cc} (预期 ${gwant}) —— 可能被判成 ${gdom} 所在地区"
            fi ;;
        esac
      fi ;;
  esac

  echo
  hr
  echo -e "${M}系统状态${N}"
  hr
  local ntp
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  case "$ntp" in
    yes) ok "时间同步       : 已同步 ($(date '+%Z %z'))" ;;
    no)  warn "时间同步       : 未同步 (REALITY 依赖时间校验, 请开 NTP)" ;;
    *)   echo "时间同步       : $(date '+%Z %z')" ;;
  esac

  # 说清楚: 远程平台看不到 VPS 的系统时区 —— 代理只转发字节流, TLS 报文里没有时区。
  # 这一项不是风控项, 只是排障时的可读性: 机器在东京、日志却按上海时间走,
  # 对日志容易对错时间。真正要跟 IP 对齐的是客户端(手机/浏览器)的时区。
  # etz 已经在上面那次合并请求里拿到了, 查不到才单独再探一次(走另外两家接口)。
  local ltz
  ltz=$(cur_timezone)
  [ -n "$etz" ] || etz=$(detect_exit_tz "$ipq")
  if [ -z "$etz" ]; then
    echo "时区一致性     : 出口时区查询失败, 跳过 (不影响其它结论)"
  elif [ "$etz" = "$ltz" ]; then
    ok "时区一致性     : ${ltz} (与出口 IP 一致)"
  else
    echo "时区一致性     : 系统 ${ltz} / 出口 ${etz} —— 不一致"
    echo -e "   ${D}只影响本机日志显示, 平台看不到 VPS 时区。想让日志跟 IP 对上: proxy timezone auto${N}"
  fi
  echo "拥塞控制       : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  echo "journald 上限  : $(journalctl --disk-usage 2>/dev/null | sed 's/.*take up //')"
  echo "磁盘占用       : $(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
  echo "内存           : $(free -m | awk '/Mem:/{print $3"MB / "$2"MB"}')"

  echo
  hr
  echo -e "${M}链路质量(判断「为什么慢」看这里)${N}"
  hr
  local ndrop retr outseg
  ndrop=$(awk 'NR>2{gsub(":"," "); s+=$5+$13} END{print s+0}' /proc/net/dev 2>/dev/null)
  echo "网卡丢包       : ${ndrop:-0}  (累计; 涨得快=带宽或收包队列不足)"
  if command -v nstat >/dev/null 2>&1; then
    retr=$(nstat -az TcpRetransSegs 2>/dev/null | awk '/TcpRetransSegs/{print $2}')
    outseg=$(nstat -az TcpOutSegs 2>/dev/null | awk '/TcpOutSegs/{print $2}')
    if [ -n "$retr" ] && [ -n "$outseg" ] && [ "$outseg" -gt 0 ] 2>/dev/null; then
      awk -v r="$retr" -v o="$outseg" 'BEGIN{
        p=r*100/o;
        printf "TCP 重传率     : %.2f%% (%d/%d)", p, r, o;
        if (p > 2) printf "  <- 偏高, 说明这条线路在丢包, 换线路比换协议有用\n";
        else printf "  (正常)\n";
      }'
    fi
  fi
  echo "UDP 缓冲上限   : $(sysctl -n net.core.rmem_max 2>/dev/null) / udp_mem $(sysctl -n net.ipv4.udp_mem 2>/dev/null | tr -s ' ' ' ')"

  if [ "$dnsbl" = "1" ]; then
    echo
    hr
    echo -e "${M}反垃圾库查询 (仅 DNS 查询, 不涉及账号)${N}"
    hr
    local rev r
    rev=$(echo "$SERVER_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
    r=$(getent hosts "${rev}.zen.spamhaus.org" 2>/dev/null | awk '{print $1}' | head -1)
    case "$r" in
      "")              ok "Spamhaus ZEN   : 未列入" ;;
      127.255.255.*)   warn "Spamhaus ZEN   : 查询被拒(公共 DNS 限制), 换本地 DNS 再试" ;;
      127.0.0.*)       warn "Spamhaus ZEN   : 已列入 ${r}" ;;
      *)               echo "Spamhaus ZEN   : ${r}" ;;
    esac
  else
    echo
    echo -e "${D}反垃圾库查询默认关闭(会把 IP 提交给第三方 DNS 库)。需要时: proxy audit --dnsbl${N}"
  fi

  echo
  hr
  echo -e "${M}客户端侧检查清单 (服务端改不了, 但直接影响账号安全)${N}"
  hr
  cat <<'CHECK'
  [ ] 关闭 WebRTC         浏览器里 WebRTC 会绕过代理暴露真实 IP
  [ ] 关闭 IPv6           手机/电脑网络设置里关掉, 避免绕过代理
  [ ] DNS 别乱改         小火箭只有一个 DNS 覆写且全局生效, 填境外 DNS 会让
                          GEOIP 分流把国内流量也判成国外; 留空最稳
                         v2rayN 有直连/远程两个入口, 才需要分开填
  [ ] 时区/语言/地区一致  做哪个区就全设那个区, 三者必须对得上
  [ ] 一号一 IP           多个账号共用同一出口 IP 是最典型的关联信号
  [ ] 固定不切换          频繁换 IP 会触发异常登录
  [ ] 指纹浏览器          多账号运营不要用同一个浏览器指纹
  [ ] Claude 别断线       用 Claude 时小火箭切全局代理, 真实 IP 露几秒就可能封号
                          客户端指南详见订阅里的 client-guide.md
CHECK
  echo
}

# ---------------- 多设备凭据管理 ----------------
user_vless_link(){
  local _frag; _frag=$(uri_fragment "${NODE_NAME}-${2}")
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp&headerType=none#%s' \
    "$1" "$SERVER_IP" "$VLESS_PORT" "$DEST" "${REALITY_FP:-chrome}" "$PUB" "$SID" "$_frag"
}

# 输出某个设备的全部协议链接(只输出已启用的协议)
user_links_for(){
  local u="$1" name="$2" hb ui _frag
  _frag=$(uri_fragment "${NODE_NAME}-${name}")
  if proto_on reality; then
    user_vless_link "$u" "$name"
    echo
  fi
  if proto_on hy2; then
    hb="hysteria2://${HY2_PASS}@${SERVER_IP}:${HY2_PORT}?sni=${DEST}"
    [ -n "${HY2_HOP:-}" ] && hb="${hb}&mport=${HY2_HOP}"
    if [ "$ENABLE_OBFS" = "1" ]; then
      hb="${hb}&obfs=salamander&obfs-password=${OBFS_PASS}"
    fi
    if [ -n "${HY2_PIN:-}" ]; then
      hb="${hb}&insecure=1&pinSHA256=${HY2_PIN}"
    else
      hb="${hb}&insecure=1"
    fi
    printf '%s#%s-HY2\n' "$hb" "$_frag"
  fi
  if proto_on ss2022; then
    ui=$(printf '2022-blake3-aes-128-gcm:%s' "$(ss_pass_for "$u")" \
      | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    printf 'ss://%s@%s:%s#%s-SS2022\n' "$ui" "$SERVER_IP" "$SS2022_PORT" "$_frag"
  fi
  if proto_on anytls; then
    printf 'anytls://%s@%s:%s?sni=%s&insecure=1#%s-AnyTLS\n' \
      "$(derive_hex "$u")" "$SERVER_IP" "$ANYTLS_PORT" "$DEST" "$_frag"
  fi
  if proto_on tuic; then
    printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&congestion_control=bbr&allow_insecure=1#%s-TUIC\n' \
      "$u" "$(derive_hex "$u")" "$SERVER_IP" "$TUIC_PORT" "$DEST" "$_frag"
  fi
}

# 设备增删后必须重载内核:
# 只重写 xray 的话, 新设备在 anytls/tuic/ss2022 上依然进不来,
# 被吊销的设备也还能继续用这三个协议 —— 等于吊销没生效。
reload_after_user_change(){
  local bad=0
  if proto_on reality; then
    # 写配置失败时旧进程还在跑, restart 和 wait_active 都会成功 —— 吊销不生效、
    # 新设备进不来, 函数却返回 0。必须把写入失败算进 bad。
    write_xray_config "$DEST" || bad=1
    systemctl restart xray >/dev/null 2>&1
  fi
  if sb_enabled; then
    write_singbox_config || bad=1
    systemctl restart sing-box >/dev/null 2>&1
  fi
  # 两个服务都重启完之后再分别轮询(而不是固定等 2 秒一起看): 慢机器上
  # 会误报"内核重载异常", 让用户以为增删设备没生效。
  proto_on reality && { wait_active xray || bad=1; }
  sb_enabled       && { wait_active sing-box || bad=1; }
  # 订阅也要跟着重生成: 主凭据就是订阅里那一条, 增删设备后不刷新的话,
  # 新设备导入订阅看不到自己, 删掉主设备后订阅还留着旧 UUID。
  # 每次 proxy user 都是新进程, load_state 只从 state.env 逐行读键, 里面没有
  # VLESS_LINK / HY2_LINK 等键。少了 gen_links, gen_sub_files 里裸引用这些链接
  # 会在 set -u 下直接退出 —— 表现为增删设备后订阅没刷新、服务却已经重启了。
  gen_links
  # 不吞 stderr: 订阅生成失败时至少要看得见原因。
  if ! gen_sub_files; then
    warn "订阅重新生成失败, 手动执行一次: proxy sub"
    bad=1
  fi
  # gen_sub_files 在 SUB_TOKEN 为空/含非法字符时会重新生成 token, 订阅随即
  # 写进新目录。少了这两步, sub.env / state.env 仍是旧 token、订阅服务没重启,
  # 手上的订阅链接全部 404, 而新 token 没人知道 —— 下次 proxy sub 又换一个。
  maybe_sub_http
  save_state
  return "$bad"
}

# 按名字(第2列)或 UUID 前缀(第1列)找一行
find_user_line(){
  awk -F'|' -v k="$1" '$2==k || ($1!="" && index($1,k)==1) {print; exit}' "$USERS_FILE"
}

cmd_user(){
  need_root
  load_state || die "尚未安装"
  ensure_users_file
  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  # u/n/d 是下面 list 分支 `read -r u n d` 的接收变量。不声明成 local 就会
  # 泄漏成全局, 和 state.env 里的同名键(没有, 但将来可能有)撞车。
  local sub="${1:-list}" u n d

  case "$sub" in
    add)
      local name="${2:-}"
      [ -n "$name" ] || die "用法: proxy user add <名字>   例如 proxy user add iPhone"
      name="${name//|/_}"
      # 名字会写进 users.txt(竖线分隔) 和两份 JSON, 控制字符直接清掉
      name=$(printf '%s' "$name" | tr -d '\000-\037\177')
      [ -n "$name" ] || die "名字不能为空"
      # 名字会拼进分享链接的 fragment, 过长会让整条 URI 超限, 这里先卡住
      [ "${#name}" -le 64 ] || die "名字太长(最多 64 字符): ${name}"
      # 只对"名字"精确查重。不能用 find_user_line —— 它还会按 UUID 前缀匹配,
      # 名字取 "a"/"ab" 这类短串时会撞上某个 UUID 的开头, 误报"已存在同名凭据"。
      [ -z "$(awk -F'|' -v n="$name" '$2==n {print; exit}' "$USERS_FILE")" ] \
        || die "已存在同名凭据: ${name}"
      local nu bak; nu=$(gen_uuid)
      # 与 rm 分支对称: 先备份原凭据文件。重载失败时若只 warn 仍报"已添加"并
      # 发出分享链接, 用户导入后必然连不上(内核没认这个用户), 属假成功。
      bak=$(mktemp "$(dirname "$USERS_FILE")/.users.XXXXXXXX") \
        || die "无法创建凭据备份文件"
      cp -f "$USERS_FILE" "$bak" 2>/dev/null \
        || { rm -f "$bak"; die "添加失败: 无法备份原凭据文件"; }
      printf '%s|%s|%s\n' "$nu" "$name" "$(date '+%Y-%m-%d')" >> "$USERS_FILE" \
        || { cp -f "$bak" "$USERS_FILE" 2>/dev/null; rm -f "$bak"; die "写入 ${USERS_FILE} 失败, 凭据未添加"; }
      if ! reload_after_user_change; then
        # 内核没认新凭据 -> 恢复原文件再 die, 绝不发出一条连不上的链接。
        cp -f "$bak" "$USERS_FILE" 2>/dev/null \
          && chmod 600 "$USERS_FILE" 2>/dev/null \
          && reload_after_user_change >/dev/null 2>&1 || true
        rm -f "$bak"
        die "添加失败: 内核重载异常, 已恢复原凭据文件; 请检查 proxy status / proxy logs 后重试"
      fi
      rm -f "$bak"
      ok "已添加凭据: ${name}"
      echo
      user_links_for "$nu" "$name"
      echo
      ;;
    rm|del)
      local key="${2:-}" line tmp before after
      [ -n "$key" ] || die "用法: proxy user rm <名字或UUID前缀>"
      [ "$(wc -l < "$USERS_FILE")" -gt 1 ] || die "至少保留一条凭据, 不能删光"
      line=$(find_user_line "$key")
      [ -n "$line" ] || die "未找到凭据: ${key}"
      # 以前是 grep > 固定名 .tmp; mv 无条件覆盖。grep 读失败 / 重定向失败 /
      # 内容被并发改过时 .tmp 会是空文件, 一 mv 就把全部设备凭据清空了 ——
      # 所有已分发链接瞬间失效, 且没有备份。改成同目录随机临时文件 + 结果校验。
      tmp=$(mktemp "$(dirname "$USERS_FILE")/.users.XXXXXXXX") \
        || die "无法创建 users.txt 临时文件"
      bak=$(mktemp "$(dirname "$USERS_FILE")/.users.XXXXXXXX") \
        || { rm -f "$tmp"; die "无法创建 users.txt 备份文件"; }
      cp -f "$USERS_FILE" "$bak" 2>/dev/null \
        || { rm -f "$tmp" "$bak"; die "吊销失败: 无法备份原凭据文件"; }
      before=$(wc -l < "$USERS_FILE")
      grep -vxF "$line" "$USERS_FILE" > "$tmp" 2>/dev/null || true
      after=$(wc -l < "$tmp" 2>/dev/null || echo 0)
      if [ "$after" -ge "$before" ] || [ "$after" -lt 1 ]; then
        rm -f "$tmp" "$bak"
        die "吊销失败: 结果异常(${before} -> ${after} 行), 原文件未改动"
      fi
      mv -f "$tmp" "$USERS_FILE" || { rm -f "$tmp"; die "吊销失败: 写回 users.txt 出错"; }
      chmod 600 "$USERS_FILE"
      if ! reload_after_user_change; then
        # 内核没认新配置就绝不能报"已吊销": 把原文件恢复回去再 die,
        # 否则用户以为设备已失效, 实际旧链接仍可连。
        cp -f "$bak" "$USERS_FILE" 2>/dev/null \
          && chmod 600 "$USERS_FILE" 2>/dev/null \
          && reload_after_user_change >/dev/null 2>&1 || true
        rm -f "$bak"
        die "吊销失败: 内核重载异常, 已恢复原凭据文件; 请检查 proxy status / proxy logs 后重试"
      fi
      rm -f "$bak"
      ok "已吊销: $(echo "$line" | cut -d'|' -f2)  (该设备的旧链接立即失效)"
      ;;
    link)
      local key="${2:-}" line
      [ -n "$key" ] || die "用法: proxy user link <名字或UUID前缀>"
      line=$(find_user_line "$key")
      [ -n "$line" ] || die "未找到凭据: ${key}"
      user_links_for "$(echo "$line" | cut -d'|' -f1)" "$(echo "$line" | cut -d'|' -f2)"
      echo
      ;;
    *)
      echo
      hr
      echo -e "${M}设备凭据${N}  (每台设备一条, 丢设备可单独吊销)"
      hr
      printf '%-38s %-16s %s\n' "UUID" "名称" "添加日期"
      while IFS='|' read -r u n d || [ -n "$u" ]; do
        [ -n "$u" ] || continue
        printf '%-38s %-16s %s\n' "$u" "$n" "$d"
      done < "$USERS_FILE"
      echo
      echo -e "${D}proxy user add <名字>     添加设备"
      echo -e "proxy user link <名字>    取该设备的链接"
      echo -e "proxy user rm <名字>      吊销该设备${N}"
      echo
      ;;
  esac
}

# ---------------- 备份 / 迁移 ----------------
_BACKUP_TMP=""
cmd_backup(){
  need_root
  local out="${1:-/root/proxy-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
  # 以 root 跑 tar -czf "$out" 能覆盖任意路径。至少挡住明显的误操作、
  # 跟随符号链接, 以及重复执行时静默覆盖上一份备份。
  case "$out" in *..*) die "备份路径不能含 '..': ${out}" ;; esac
  [ ! -L "$out" ] || die "备份目标是符号链接, 拒绝写入: ${out}"
  [ ! -e "$out" ] || die "备份文件已存在, 拒绝覆盖: ${out}"
  # 只查 $out 本身不够: /root/lnk/backup.tar.gz 且 lnk -> /etc 时,
  # -L 为假、-d 为真, tar 会以 root 写进 /etc。把父目录整条链解析成物理路径。
  local _bdir _breal
  _bdir=$(dirname "$out")
  [ -d "$_bdir" ] || die "备份目录不存在: ${_bdir}"
  [ ! -L "${_bdir%/}" ] || die "备份目录是符号链接, 拒绝写入: ${_bdir}"
  _breal=$(cd -P "$_bdir" 2>/dev/null && pwd -P) \
    || die "无法解析备份目录: ${_bdir}"
  case "$_breal" in
    /etc|/etc/*|/usr|/usr/*|/bin|/sbin|/lib|/lib64|/lib/*|/lib64/*|/boot|/boot/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*)
      die "备份目录解析后落在系统目录(${_breal}), 拒绝写入: ${out}" ;;
  esac
  local tmp; tmp=$(mktemp -d) || die "无法创建临时目录"
  _BACKUP_TMP="$tmp"
  trap 'rm -rf "$_BACKUP_TMP" 2>/dev/null' EXIT
  mkdir -p "$tmp/etc-proxy-node" "$tmp/etc-hysteria" "$tmp/etc-sing-box"

  [ -d "$STATE_DIR" ] && cp -a "$STATE_DIR/." "$tmp/etc-proxy-node/" 2>/dev/null
  [ -f /etc/hysteria/cert.pem ] && cp -a /etc/hysteria/cert.pem /etc/hysteria/key.pem "$tmp/etc-hysteria/" 2>/dev/null
  # sing-box 的自签证书也要带上, 否则迁移后 anytls/tuic 的指纹全变, 客户端要重导
  [ -f "$SB_CERT" ] && cp -a "$SB_CERT" "$SB_KEY" "$tmp/etc-sing-box/" 2>/dev/null
  [ -f /root/proxy-info.txt ] && cp -a /root/proxy-info.txt "$tmp/" 2>/dev/null
  # 没开对应协议时上面会留下空目录; 打包进去的话, restore 到新机器会凭空
  # 建出 /etc/hysteria、/etc/sing-box, 之后又被 residue_report 当成残留。
  rmdir "$tmp/etc-hysteria" 2>/dev/null || true
  rmdir "$tmp/etc-sing-box" 2>/dev/null || true

  if [ -z "$(ls -A "$tmp/etc-proxy-node" 2>/dev/null)" ]; then
    rm -rf "$tmp"
    die "没有可备份的内容, 先安装: bash setup-proxy.sh install"
  fi

  # 排除 $STATE_DIR/backup: 否则每次 backup -> restore -> backup 都会把上一轮
  # 备份整份塞进新包, 体积逐层膨胀。
  # umask 077 必须包住 tar 本身: 包里有私钥与全部凭据, tar 建文件用
  # 0666 & ~umask, 先建后 chmod 会留一个"全世界可读"的窗口。
  ( umask 077; tar -czf "$out" -C "$tmp" --exclude='./etc-proxy-node/backup' . ) \
    || { rm -rf "$tmp"; rm -f "$out"; die "打包失败"; }
  # 校验包内真的有 state.env: 上面的 cp 都是尽力而为, 磁盘满时可能只丢一部分,
  # 只看"目录非空"会把缺凭据的包当成功。
  local _tl
  _tl=$(tar -tzf "$out" 2>/dev/null) || { rm -rf "$tmp"; rm -f "$out"; die "备份包无法读取, 打包失败"; }
  case "$_tl" in
    *./etc-proxy-node/state.env*) ;;
    *) rm -rf "$tmp"; rm -f "$out"; die "备份包缺少 state.env, 打包不完整" ;;
  esac
  chmod 600 "$out"
  rm -rf "$tmp"
  trap - EXIT; _BACKUP_TMP=""
  ok "已备份: ${out}  ($(du -h "$out" 2>/dev/null | awk '{print $1}'))"
  echo -e "${D}含全部凭据与私钥, 权限 600, 请勿外传${N}"
  echo -e "${D}迁移到新 VPS: 拷过去后 proxy restore <文件>${N}"
}

# restore 覆盖 state.env / 证书之后还有多处 die(load_state / 服务启动),
# 以前没有 trap: 半套状态留在机器上, 解压出的私钥也一直躺在 /tmp。
_RESTORE_TMP=""
_RESTORE_BACKUP=""
_RESTORE_CERT_BACKUP=""
_RESTORE_STARTED=0
_restore_rollback(){
  [ -n "$_RESTORE_TMP" ] && [ -d "$_RESTORE_TMP" ] && rm -rf "$_RESTORE_TMP"
  [ "$_RESTORE_STARTED" = "1" ] || return 0
  if [ -n "$_RESTORE_BACKUP" ] && [ -d "$_RESTORE_BACKUP" ] \
     && cp -a "$_RESTORE_BACKUP/." "$STATE_DIR/" 2>/dev/null; then
    # write_xray_config / write_singbox_config 可能已经改过服务配置,
    # 复用重置那套快照一起还原(两个命令不会同时执行)。
    _reset_svc_restore
    # 证书必须一起回滚: 恢复会覆盖 /etc/hysteria 与 $SB_DIR 的 cert/key,
    # 而 state.env 里的 HY2_PIN / SB_PIN 是旧证书指纹。只回滚 state.env 的话,
    # 旧 PIN 配新证书 -> 所有固定证书的客户端握手失败, 却提示"已自动回滚"。
    if [ -n "$_RESTORE_CERT_BACKUP" ] && [ -d "$_RESTORE_CERT_BACKUP" ]; then
      [ -d "$_RESTORE_CERT_BACKUP/hysteria" ] && \
        cp -a "$_RESTORE_CERT_BACKUP/hysteria/." /etc/hysteria/ 2>/dev/null
      [ -d "$_RESTORE_CERT_BACKUP/sing-box" ] && \
        cp -a "$_RESTORE_CERT_BACKUP/sing-box/." "$SB_DIR/" 2>/dev/null
    fi
    warn "恢复未完成, 已自动回滚到恢复前的状态; 原状态另存于 ${_RESTORE_BACKUP}"
  else
    warn "恢复未完成且自动回滚失败! 恢复前的状态在 ${_RESTORE_BACKUP:-未创建}, 请手动处理"
  fi
}

cmd_restore(){
  need_root
  local f="${1:-}" tmp
  [ -n "$f" ] && [ -f "$f" ] || die "用法: proxy restore /root/proxy-backup-xxx.tar.gz"
  # 同进程里二次调用时, 上一次的回滚状态可能残留; 不清会让 trap 拿已删除的
  # 目录回滚并误报"自动回滚失败"。
  _RESTORE_STARTED=0
  _RESTORE_BACKUP=""

  # 防路径穿越: 含绝对路径或 .. 的备份包直接拒绝。
  # 不能写成 `tar -tzf "$f" | grep -q ...`: 脚本开了 pipefail, grep -q 命中后立刻退出,
  # tar 接着写就会吃到 SIGPIPE(141), 整条管道判为失败 —— 于是"包里有非法路径"这个
  # 分支反而不成立, 恶意包会被放行。先落到变量里再判断, 与管道退出码无关。
  local badpath
  badpath=$(tar -tzf "$f" 2>/dev/null | grep -E '^/|(^|/)\.\.(/|$)' | head -5)
  if [ -n "$badpath" ]; then
    printf '%s\n' "$badpath" | sed 's/^/    /' >&2
    die "备份包内含非法路径, 已中止"
  fi
  # 名字合法不代表类型合法: 设备节点 / FIFO 会被 root 的 tar 真的 mknod 出来,
  # 事后删符号链接也救不了。只允许普通文件和目录。
  local badtype
  badtype=$(tar -tvzf "$f" 2>/dev/null \
    | awk 'substr($1,1,1)!="-" && substr($1,1,1)!="d" {print; n++} n>=5{exit}')
  if [ -n "$badtype" ]; then
    printf '%s\n' "$badtype" | sed 's/^/    /' >&2
    die "备份包内含非普通文件(链接/设备/FIFO), 已中止"
  fi

  ask_yes "恢复会覆盖当前配置与凭据, 确认?" || { info "已取消"; return 0; }

  tmp=$(mktemp -d) || die "无法创建临时目录"
  _RESTORE_TMP="$tmp"
  trap _restore_rollback EXIT
  # 加固参数优先; 极简系统(BusyBox tar)不认长选项时退回普通解压 ——
  # 恢复功能不能因为一个加固开关就用不了。选项错误时 tar 在解压前就退出,
  # 不会留下半套文件, 所以这里的二次尝试是安全的。
  tar -xzf "$f" -C "$tmp" --no-same-owner --no-same-permissions 2>/dev/null \
    || tar -xzf "$f" -C "$tmp" \
    || { rm -rf "$tmp"; die "解压失败"; }
  # 只校验成员名字不够: 包里可以放一个名字正常、目标指向 /etc/passwd 的符号链接。
  # cp -a 会把链接原样带过去, 紧跟着的 chmod 600 就打到系统文件上。备份里的
  # 凭据本就应是普通文件, 解压后一律剥掉链接再往下走。
  find "$tmp" -type l -delete 2>/dev/null || true

  # 覆盖之前先验一遍包里的 state.env: 那份是坏的就等于把一套能用的安装换成
  # 一堆读不出来的凭据, 而且不可逆。校验不过时当前安装一个字都没动。
  local bstate="$tmp/etc-proxy-node/state.env" bk
  [ -f "$bstate" ] || { rm -rf "$tmp"; die "备份包内没有 state.env, 不像本脚本的备份, 已中止"; }
  bash -n "$bstate" 2>/dev/null \
    || { rm -rf "$tmp"; die "备份包内 state.env 语法损坏, 已中止(当前安装未改动)"; }
  # 只接受注释行或 KEY=值 行。新版 load_state 已不 source, 但备份包可能来自
  # 任何地方, 这里再挡一层: 不允许包里夹带命令行。
  local badline
  badline=$(grep -nEv '^($|#|[A-Z_][A-Z0-9_]*=)' "$bstate" 2>/dev/null | head -3)
  if [ -n "$badline" ]; then
    printf '%s\n' "$badline" | sed 's/^/    /' >&2
    rm -rf "$tmp"; die "备份包内 state.env 含非键值的行, 已中止(当前安装未改动)"
  fi
  for bk in UUID PRIV PUB SID SUB_TOKEN; do
    grep -q "^${bk}=" "$bstate" \
      || { rm -rf "$tmp"; die "备份包内 state.env 缺少 ${bk}, 已中止(当前安装未改动)"; }
  done

  # 换 VPS 时公网 IP 会变。探测必须放在任何覆盖动作之前: 以前是覆盖完
  # state.env 和证书后才发现拿不到 IP, die 了却回不去, 只丢一句备份路径。
  local _newip
  _newip=$(get_server_ip)
  [ -n "$_newip" ] || die "无法获取公网 IPv4, 恢复中止(尚未改动现有配置)"

  # 旧状态留一份, 恢复中途失败时还能照着回滚
  if [ -d "$STATE_DIR" ]; then
    rm -rf "${STATE_DIR}.before-restore"
    cp -a "$STATE_DIR" "${STATE_DIR}.before-restore" || die "无法备份当前状态, 恢复已取消"
    _RESTORE_BACKUP="${STATE_DIR}.before-restore"
  fi
  # 服务配置也会被 write_*_config 覆盖, 单独存一份供回滚。
  _reset_svc_snapshot || die "无法备份当前服务配置, 恢复已取消"
  _RESTORE_STARTED=1

  # 证书单独留一份回滚点(放在 STATE_DIR 外, 不会被下面的 cp -a 冲掉)
  _RESTORE_CERT_BACKUP="${STATE_DIR}.before-restore.certs"
  rm -rf "$_RESTORE_CERT_BACKUP"
  if [ -d /etc/hysteria ] || [ -d "$SB_DIR" ]; then
    mkdir -p "$_RESTORE_CERT_BACKUP" || die "无法备份当前证书, 恢复已取消"
    [ -d /etc/hysteria ] && cp -a /etc/hysteria "$_RESTORE_CERT_BACKUP/hysteria" 2>/dev/null
    [ -d "$SB_DIR" ] && cp -a "$SB_DIR" "$_RESTORE_CERT_BACKUP/sing-box" 2>/dev/null
  fi

  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  [ -d "$tmp/etc-proxy-node" ] && cp -a "$tmp/etc-proxy-node/." "$STATE_DIR/" 2>/dev/null
  if [ -d "$tmp/etc-hysteria" ]; then
    mkdir -p /etc/hysteria
    cp -a "$tmp/etc-hysteria/." /etc/hysteria/ 2>/dev/null
    chmod 600 /etc/hysteria/key.pem 2>/dev/null || true
  fi
  if [ -d "$tmp/etc-sing-box" ]; then
    mkdir -p "$SB_DIR"; chmod 700 "$SB_DIR"
    cp -a "$tmp/etc-sing-box/." "$SB_DIR/" 2>/dev/null
    chmod 600 "$SB_KEY" 2>/dev/null || true
  fi
  rm -rf "$tmp"
  chmod 600 "$STATE_FILE" 2>/dev/null || true
  [ -f "$USERS_FILE" ] && chmod 600 "$USERS_FILE"

  load_state || die "恢复后的状态文件无法读取"

  # 老备份的 state.env 可能没有 DEST(该字段是后加的)。set -u 下直接拿
  # write_xray_config "$DEST" / sni=${DEST} 会因未定义变量中止, 恢复卡在半途。
  # 和 ensure_hy2 / write_singbox_config 的兜底保持一致。
  DEST="${DEST:-www.bing.com}"

  # 换 VPS 时公网 IP 会变, 重新探测, 否则链接里还是旧地址。
  # 探测不到就中止: 空 IP 写进 state.env 会让所有链接变成 uuid@:443, 之后每次
  # 启动都沿用这个空值 —— 比直接失败更难查。
  SERVER_IP="$_newip"
  info "服务器 IP: ${SERVER_IP}"

  # 新机器上内核参数还是默认值(rmem_max 208KB), 必须在服务启动前生效,
  # 否则 HY2 / TUIC 的 UDP socket 一建好就被钳死, 恢复出来的节点照样慢。
  optimize_system

  # 按恢复出来的协议组合重建服务, 不要把没启用的协议也拉起来
  if proto_on reality; then
    ensure_xray
    ensure_xray_service
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
    wait_active xray || die "xray 启动失败, 查看: journalctl -u xray -n 30"
  fi
  if proto_on hy2; then
    ensure_hy2
    # 端口跳跃是 iptables NAT 规则, 不随配置文件恢复, 必须在新机器上重建,
    # 否则订阅里带 mport、服务端却没有那条 REDIRECT, 跳跃端口全连不上。
    setup_hy2_hop
  fi
  if sb_enabled; then
    ensure_singbox
    ensure_sb_cert
    ensure_sb_creds
    write_singbox_config
    ensure_singbox_service
    systemctl restart sing-box >/dev/null 2>&1
    wait_active sing-box || die "sing-box 启动失败, 查看: journalctl -u sing-box -n 30"
  fi
  local fw_bad=0
  setup_firewall || fw_bad=1
  install_healthcheck || true
  stop_unused_services
  save_state
  gen_links
  # 换 VPS 后 IP 必变: 订阅生成失败会让用户导入旧 IP 的订阅, 却被告知"恢复完成"。
  gen_sub_files || warn "订阅生成失败, 请手动执行一次: proxy sub"
  maybe_sub_http
  save_state
  # 恢复后必须重写 /root/proxy-info.txt: 备份包里那份是旧 IP 的, 新机器上
  # 直接看会误导。
  write_info_file
  print_links
  trap - EXIT
  _RESTORE_TMP=""
  _RESTORE_STARTED=0
  _RESTORE_BACKUP=""
  rm -rf "${STATE_DIR}.before-restore" "$_RESTORE_CERT_BACKUP" "$_RESET_SVC_BACKUP"
  _RESTORE_CERT_BACKUP=""
  _RESET_SVC_BACKUP=""
  if [ "$fw_bad" = "1" ]; then
    warn "恢复完成, 但防火墙放行失败: 节点可能无法从外部连接, 请检查安全组与 proxy status"
  else
    ok "恢复完成, 凭据与设备列表都已沿用"
  fi
}

# cmd_reset 的回滚兜底。die 是 exit 1, 只有 EXIT trap 能在中途失败时把清空
# 前的 state.env / users.txt / 证书整份恢复回去。不这么做, 一次 pick_dest
# 失败就会留下全空的 state.env, 服务还在跑旧配置, 用户却再也拿不到凭据。
_RESET_BACKUP=""
_RESET_SVC_BACKUP=""

# 重置会重写 xray / sing-box / hysteria2 的配置并重启服务。只回滚 state.env
# 是不够的: 那时磁盘上已经是新 UUID、服务也用新配置在跑, 提示却说"已回滚"。
# 单独存一份服务配置快照(放进 STATE_DIR 会跟着 cp -a 一起被复制回去, 所以另开目录)。
_reset_svc_snapshot(){
  # 换站也复用这套快照, 只是换个目录名; 否则每次换站都复制一遍同样的代码,
  # 下次改了证书路径只修一处则另一处静默失效。
  local tag="${1:-reset}"
  _RESET_SVC_BACKUP="${STATE_DIR}.before-${tag}.svc"
  rm -rf "$_RESET_SVC_BACKUP"
  mkdir -p "$_RESET_SVC_BACKUP" || return 1
  [ -f "${XRAY_CFG:-}" ] && cp -a "$XRAY_CFG" "$_RESET_SVC_BACKUP/xray.json" 2>/dev/null
  [ -f "${SB_CFG:-}" ]   && cp -a "$SB_CFG"   "$_RESET_SVC_BACKUP/singbox.json" 2>/dev/null
  [ -f "${HY2_CFG:-}" ]  && cp -a "$HY2_CFG"  "$_RESET_SVC_BACKUP/hy2.yaml" 2>/dev/null
  # 证书也必须存。重置会重新挑伪装站, CN 一变就重签证书; 而 state.env 里的
  # CERT_HEX / SB_PIN 是**旧**证书的指纹。只回滚 state.env 与服务配置的话,
  # 磁盘上是新证书、旧状态里是旧指纹 —— 客户端固定的正是旧指纹, 握手全挂,
  # 提示却说"已自动回滚"。这与修订 13 修的 restore 是同一个形态。
  mkdir -p "$_RESET_SVC_BACKUP/certs" || return 1
  [ -f /etc/hysteria/cert.pem ] && cp -a /etc/hysteria/cert.pem "$_RESET_SVC_BACKUP/certs/hy2-cert.pem" 2>/dev/null
  [ -f /etc/hysteria/key.pem ]  && cp -a /etc/hysteria/key.pem  "$_RESET_SVC_BACKUP/certs/hy2-key.pem"  2>/dev/null
  [ -f "${SB_CERT:-}" ] && cp -a "$SB_CERT" "$_RESET_SVC_BACKUP/certs/sb-cert.pem" 2>/dev/null
  [ -f "${SB_KEY:-}" ]  && cp -a "$SB_KEY"  "$_RESET_SVC_BACKUP/certs/sb-key.pem"  2>/dev/null
  return 0
}

_reset_svc_restore(){
  [ -n "$_RESET_SVC_BACKUP" ] && [ -d "$_RESET_SVC_BACKUP" ] || return 0
  # 先还原证书再重启服务: 服务配置与 state.env 里的指纹都指向旧证书,
  # 顺序反过来会有一小段"新证书 + 旧指纹"的窗口。
  if [ -d "$_RESET_SVC_BACKUP/certs" ]; then
    [ -f "$_RESET_SVC_BACKUP/certs/hy2-cert.pem" ] && cp -a "$_RESET_SVC_BACKUP/certs/hy2-cert.pem" /etc/hysteria/cert.pem 2>/dev/null
    [ -f "$_RESET_SVC_BACKUP/certs/hy2-key.pem" ]  && cp -a "$_RESET_SVC_BACKUP/certs/hy2-key.pem"  /etc/hysteria/key.pem  2>/dev/null
    [ -f "$_RESET_SVC_BACKUP/certs/sb-cert.pem" ] && [ -n "${SB_CERT:-}" ] && cp -a "$_RESET_SVC_BACKUP/certs/sb-cert.pem" "$SB_CERT" 2>/dev/null
    [ -f "$_RESET_SVC_BACKUP/certs/sb-key.pem" ]  && [ -n "${SB_KEY:-}" ]  && cp -a "$_RESET_SVC_BACKUP/certs/sb-key.pem"  "$SB_KEY"  2>/dev/null
  fi
  if [ -f "$_RESET_SVC_BACKUP/xray.json" ] && [ -n "${XRAY_CFG:-}" ]; then
    cp -a "$_RESET_SVC_BACKUP/xray.json" "$XRAY_CFG" 2>/dev/null
    systemctl restart xray >/dev/null 2>&1
  fi
  if [ -f "$_RESET_SVC_BACKUP/singbox.json" ] && [ -n "${SB_CFG:-}" ]; then
    cp -a "$_RESET_SVC_BACKUP/singbox.json" "$SB_CFG" 2>/dev/null
    systemctl restart sing-box >/dev/null 2>&1
  fi
  if [ -f "$_RESET_SVC_BACKUP/hy2.yaml" ] && [ -n "${HY2_CFG:-}" ]; then
    cp -a "$_RESET_SVC_BACKUP/hy2.yaml" "$HY2_CFG" 2>/dev/null
    systemctl restart hysteria-server >/dev/null 2>&1
  fi
}

_reset_rollback(){
  [ -n "$_RESET_BACKUP" ] && [ -d "$_RESET_BACKUP" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null
  if cp -a "$_RESET_BACKUP/." "$STATE_DIR/" 2>/dev/null; then
    _reset_svc_restore
    warn "重置未完成, 已自动回滚到重置前的凭据、设备列表与服务配置"
  else
    warn "重置未完成且自动回滚失败! 原始状态保存在 ${_RESET_BACKUP}, 请手动恢复"
  fi
}

# 换伪装目标站。安装流程刻意复用旧 DEST: 静默换 SNI 会让所有已发出去的
# 客户端链接一次性失效。只有这里(显式操作)才会真的改。
_DEST_BACKUP=""
change_dest(){
  need_root
  acquire_lock
  local target="${1:-}" old="${DEST:-}"
  local _old_rd="${REALITY_DEST:-}"

  case "$target" in
    random) ;;
    *)
      valid_domain "$target" || die "伪装目标必须是合法域名或 random, 收到: ${target}"
      is_blocked "$target" && die "${target} 在排除名单里, 不能当伪装目标"
      [ "$target" = "$old" ] && { info "当前已经是 ${target}, 未改动"; return 0; }
      ;;
  esac

  # state / 服务配置 / 证书三样一起备份。只回滚 state 会留下"新证书 + 旧指纹",
  # 客户端固定的还是旧值, 全线握手失败却提示已回滚。
  _DEST_BACKUP="${STATE_DIR}.before-dest"
  rm -rf "$_DEST_BACKUP"
  cp -a "$STATE_DIR" "$_DEST_BACKUP" || die "无法备份当前状态, 换站已取消"
  _reset_svc_snapshot dest || die "无法备份服务配置, 换站已取消"
  trap _dest_rollback EXIT

  if [ "$target" = "random" ]; then
    # 随机换也不能抽到当前站, 否则用户点了"换"却什么都没变
    DEST_EXCLUDE="$old"
    REALITY_DEST="random"
  else
    REALITY_DEST="$target"
  fi

  DEST=""
  if proto_on reality; then
    pick_dest || die "伪装目标探测失败(所有候选都不可达), 已回滚"
  else
    pick_dest_simple
  fi
  DEST_EXCLUDE=""
  REALITY_DEST="$_old_rd"

  [ -n "${DEST:-}" ] || die "伪装目标为空, 已回滚"
  # pick_dest_simple 全不可达时会硬兜底 www.bing.com, 可能又绕回当前站。
  [ "$target" != "random" ] || [ "$DEST" != "$old" ] \
    || die "随机挑到的还是当前站, 已回滚; 可显式指定别的域名"
  if [ "$target" != "random" ] && [ "$DEST" != "$target" ]; then
    die "指定的 ${target} 没通过验证, 实际挑到了 ${DEST}; 为避免换错站已回滚"
  fi

  backup_config
  if proto_on reality; then
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
    wait_active xray || die "xray 用新伪装目标启动失败, 查看: journalctl -u xray -n 30 --no-pager"
  fi
  if proto_on hy2; then
    # CN 变了会自动重签证书并重算 pinSHA256 / SPKI, 再跑一次本机握手自测
    ensure_hy2
  fi
  if sb_enabled; then
    ensure_sb_cert
    write_singbox_config
    systemctl restart sing-box >/dev/null 2>&1
    wait_active sing-box || die "sing-box 用新伪装目标启动失败, 查看: journalctl -u sing-box -n 30 --no-pager"
  fi

  SERVER_IP="${SERVER_IP:-$(get_server_ip)}"
  save_state
  gen_links
  gen_sub_files
  maybe_sub_http
  save_state
  write_info_file

  trap - EXIT
  rm -rf "$_DEST_BACKUP" "$_RESET_SVC_BACKUP"
  _DEST_BACKUP=""; _RESET_SVC_BACKUP=""
  echo
  ok "伪装目标已换成 ${DEST}"
  warn "SNI 变了: 所有客户端必须重新导入链接/订阅, 旧链接里的 sni 还是 ${old}"
  echo
  print_links
  print_sub_info
}

_dest_rollback(){
  DEST_EXCLUDE=""
  [ -n "$_DEST_BACKUP" ] && [ -d "$_DEST_BACKUP" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null
  if cp -a "$_DEST_BACKUP/." "$STATE_DIR/" 2>/dev/null; then
    _reset_svc_restore
    warn "换站未完成, 已回滚到换站前的 state、服务配置与证书"
  else
    warn "换站未完成且自动回滚失败! 原始状态在 ${_DEST_BACKUP}, 请手动恢复"
  fi
}

cmd_reset(){
  need_root
  load_state || die "尚未安装"
  warn "重置会生成新的 UUID / 密钥 / hy2 密码, 所有客户端必须重新导入!"
  ask_yes "确认重置凭据?" || { info "已取消"; return 0; }
  local _rsbak="${STATE_DIR}.before-reset"
  rm -rf "$_rsbak"
  cp -a "$STATE_DIR" "$_rsbak" || die "无法备份当前状态, 重置已取消"
  _RESET_BACKUP="$_rsbak"
  # 服务配置快照失败必须中止: 否则回滚提示会声称"已回滚服务配置", 实际没有。
  _reset_svc_snapshot || die "无法备份当前服务配置, 重置已取消"
  trap _reset_rollback EXIT
  UUID=""; PRIV=""; PUB=""; SID=""; HY2_PASS=""; OBFS_PASS=""; DEST=""
  SS2022_PASS=""; ANYTLS_PASS=""; TUIC_PASS=""; TUIC_UUID=""; SB_PIN=""
  HY2_PIN=""; CERT_SPKI_B64=""; CERT_HEX=""
  rm -f "$USERS_FILE"
  save_state
  info "重新生成凭据..."
  ensure_creds
  # 上面 rm 了 users.txt; 纯 hy2 组合后续不会走 write_xray_config,
  # 不在这里重建设备列表的话, 重置完 users.txt 会一直不存在。
  ensure_users_file
  backup_config
  # 伪装目标按协议组合重新挑: 没开 reality 时不能走 REALITY 握手验证
  if proto_on reality; then
    pick_dest || die "目标站选择失败"
    write_xray_config "$DEST"
    systemctl restart xray >/dev/null 2>&1
    wait_active xray || die "xray 重启失败, 查看: journalctl -u xray -n 30"
  elif proto_on hy2 || proto_on anytls || proto_on tuic; then
    pick_dest_simple
  fi
  if proto_on hy2; then
    ensure_hy2
  fi
  if sb_enabled; then
    # 证书本身可以留着(客户端已固定), 但指纹要重算, 否则订阅会退回 insecure
    ensure_sb_cert
    ensure_sb_creds
    write_singbox_config
    systemctl restart sing-box >/dev/null 2>&1
    wait_active sing-box || die "sing-box 重启失败, 查看: journalctl -u sing-box -n 30"
  fi
  save_state
  gen_links
  gen_sub_files || warn "订阅生成失败, 请手动执行一次: proxy sub"
  maybe_sub_http
  save_state
  trap - EXIT
  _RESET_BACKUP=""
  rm -rf "$_rsbak" "$_RESET_SVC_BACKUP"
  _RESET_SVC_BACKUP=""
  print_links
  ok "凭据已重置, 请重新导入所有客户端"
}

# 查 Xray 最新版本号。升级路径必须先解析出确切版本, 才能和内置哈希对上;
# 直接用 /releases/latest/download/ 下载等于绕开校验。
xray_latest_version(){
  local v=""
  v=$(curl -fsSL --max-time 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
      | tr ',' '\n' | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([0-9][^"]*\)".*/\1/p' | head -1)
  printf '%s' "$v"
}

# Hysteria2 官方最新版。仓库已从 apernet/hysteria 改名/转移到 HyNetworks/hysteria
# (旧地址目前仍 301 过去, 但按新址写才不依赖重定向; 仓库 ID 一致, 是同一个仓库)。
# tag 历史上是 `app/v2.14.0` 这种带前缀的形式, 也有过纯 `v2.14.0`, 所以先去掉
# 最后一段路径再去掉 v, 只留 x.y.z。
# 只认纯数字加点的形式; 解析不出就返回空, 由调用方沿用本机版本。
hy2_latest_version(){
  local v=""
  v=$(curl -fsSL --max-time 20 https://api.github.com/repos/HyNetworks/hysteria/releases/latest 2>/dev/null \
      | tr ',' '\n' | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  v="${v##*/}"
  v="${v#v}"
  case "$v" in
    ''|*[!0-9.]*|.*|*.) return 0 ;;
  esac
  # 至少要有一个点(x.y), 排除 "2" 这种半截值
  case "$v" in *.*) ;; *) return 0 ;; esac
  printf '%s' "$v"
}

# sing-box 官方最新版。tag 是纯 `v1.14.4`, 没有路径前缀(和 hysteria 的 app/ 不同),
# 但同样只认纯数字加点的形式, 解析不出就返回空, 由调用方沿用本机版本。
sb_latest_version(){
  local v=""
  v=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
      | tr ',' '\n' | sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([0-9][^"]*\)".*/\1/p' | head -1)
  case "$v" in
    ''|*[!0-9.]*|.*|*.) return 0 ;;
  esac
  case "$v" in *.*) ;; *) return 0 ;; esac
  printf '%s' "$v"
}

# 本机已装 sing-box 的版本号, 拿不到返回空。
# 抽成函数是因为 ensure_singbox 里两处要用: API 不通时的"沿用本机版本", 以及
# "新版读不懂现有配置"时给用户的回退提示 —— 后者如果拿不到版本, 提示会变成
# `SB_VERSION= bash ...` 这种照抄不了的东西。
# `sing-box version` 首行形如 "sing-box version 1.14.4", 后面可能还跟 go 版本,
# 所以按"第一段 x.y.z"抠, 不按列取(和 ensure_hy2 同一套做法)。
sb_installed_version(){
  local out=""
  [ -x "$SB_BIN" ] || return 0
  out=$("$SB_BIN" version 2>/dev/null) || out=""
  printf '%s\n' "$out" \
    | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1
}

# ---------------- 脚本自更新 ----------------
# 为什么必须有这个:
#   第一次按文档 curl -o 下载之后, 用户后面一直敲 proxy, 跑的就是那份下载时的
#   旧代码。脚本原来没有任何更新机制, 菜单里也看不出自己是不是旧的, 于是出现
#   "上游已经修了 bug, 机器上还在跑几个月前的脚本"。这里给一个明确入口。
# SCRIPT_URL 在文件顶部的常量区定义。

# 取远端版本号, 只返回 "<version>" 一个字段。
# 拉整份脚本前 8KB 再 sed 抠 —— 比 GitHub API 稳: API 对单 IP 限 60 次/小时。
fetch_remote_version(){
  command -v curl >/dev/null 2>&1 || return 0
  local p meta ver
  # 必须和 download_with_mirror 用同一组镜像。
  # 以前只直连 raw.githubusercontent.com: 国内 VPS 上十有八九超时, 于是
  #   - 网络好的那天 -> 拉到版本号 -> 自动更新 -> 新界面
  #   - 网络差的那天 -> 拉不到 -> 静默跳过 -> 跑磁盘上的旧版 -> 旧界面
  # 用户看到的就是"每次选项都不一样", 而且完全找不到规律。
  for p in "" "https://ghfast.top/" "https://gh-proxy.com/"; do
    meta=$(curl -fsSL -r 0-8191 --connect-timeout 6 --max-time 20 "${p}${SCRIPT_URL}" 2>/dev/null \
          | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' | head -1)
    ver="$meta"
    [ -n "$ver" ] || continue
    printf '%s' "$ver"
    return 0
  done
  return 0
}

# 版本比较: 远端比本地新返回 0。只比 x.y.z 三段数字, 脏版本号当 0 处理。
ver_gt(){
  # 变量名别用 A / B: 文件顶部 B 是全局的青色(\033[0;36m), 这里 `local -a B=()`
  # 会把颜色变量在这个函数里遮成数组。现在函数内没用到颜色所以没炸, 但这是
  # "复制代码就变真 bug"的形态 —— 静态检查也一直在 ${B} 处报 SC2128。
  # 改名把这个隐患直接消掉。
  local i x y
  local -a va=() vb=()
  IFS=. read -r -a va <<< "${1:-}"
  IFS=. read -r -a vb <<< "${2:-}"
  for i in 0 1 2; do
    x="${va[$i]:-0}"; y="${vb[$i]:-0}"
    case "$x" in ''|*[!0-9]*) x=0 ;; esac
    case "$y" in ''|*[!0-9]*) y=0 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 1
}

# 某份脚本的版本号 rv 是否比"当前正在跑的这份"更新。
# 纯版本号比较: 从今往后版本严格递增(1.0 -> 1.1 ...), 不再回退,
# 所以不需要额外计数器 —— 版本号本身就是唯一判据。
script_newer(){
  ver_gt "${1:-}" "$SCRIPT_VERSION"
}

# 当前正在运行的脚本路径。用 proxy 命令跑时 $0 是软链, readlink 解到真实文件。
running_script_path(){
  local p
  p=$(readlink -f "$0" 2>/dev/null || echo "")
  [ -n "$p" ] && [ -f "$p" ] && printf '%s' "$p"
}

# 提示里让用户照抄的命令。curl | bash 时 $0 是 "bash", 直接 basename 会得到
# "bash bash install" —— 恰恰是装失败时最需要照做的那条提示。退回落盘位置。
self_hint(){
  local p; p=$(running_script_path 2>/dev/null)
  case "$p" in
    ''|*/bash|*/sh|*/dash) printf '%s' "/root/setup-proxy.sh" ;;
    *) printf '%s' "$p" ;;
  esac
}

# 界面顶部印一行"实际在跑的是哪份文件"。
# 用户反馈"每次看到的选项都不一样", 实际都是跑到了不同版本 / 不同副本 ——
# 把这行印出来, 差异一眼可见, 不用再靠猜。管道运行(curl | bash)时没有落盘文件,
# 直接标明, 免得用户以为脚本凭空变了。
ui_stamp(){
  local p=""
  p=$(running_script_path 2>/dev/null) || p=""
  # 只印路径: 让用户一眼看到实际在跑哪份文件。
  printf '  %b脚本%b %s%b\n' "$D" "$N" "${p:-<管道运行, 未落盘>}" "$N"
}

# 清掉磁盘上残留的旧脚本副本。
#
# 场景: 第一次下到 /root/setup.sh, 后来改成 /root/setup-proxy.sh, 旧的那份就
# 一直躺在 /root 下 —— 哪天顺手敲一次 bash /root/setup.sh, 又跑回几个月前的
# 代码, 而且看起来"和文档一模一样", 极难发现。
#
# 只删同时满足三条的文件:
#   1) 文件名像我们的脚本 (setup*.sh / proxy-node*.sh)
#   2) 内容确实是这份脚本 (有 SCRIPT_VERSION= 且有 "Proxy Node Installer")
#   3) 不是当前正在运行的那一份
# 软链不碰: 指向当前文件的要保留, 指向别处的由安装流程重新指向。
cleanup_stale_scripts(){
  local self c rp n=0 cv
  self=$(running_script_path)
  [ -n "$self" ] || return 0
  self=$(readlink -f "$self" 2>/dev/null || printf '%s' "$self")

  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -L "$c" ] && continue
    rp=$(readlink -f "$c" 2>/dev/null || printf '%s' "$c")
    [ "$rp" = "$self" ] && continue
    # 身份校验: 光看文件名会误删用户自己的脚本
    grep -q '^SCRIPT_VERSION=' "$c" 2>/dev/null || continue
    grep -q 'Proxy Node Installer' "$c" 2>/dev/null || continue
    # 比当前这份还新的不删。说明用户手里有更新的副本(比如这次误跑了旧路径),
    # 删掉它等于把唯一的新版扔了 —— 保留并提示, 让用户自己决定跑哪份。
    cv=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$c" 2>/dev/null | head -1)
    if [ -n "$cv" ] && script_newer "$cv"; then
      echo -e "  ${D}保留更新的副本: ${c} (v${cv} > 当前 v${SCRIPT_VERSION})${N}"
      continue
    fi
    if rm -f "$c" 2>/dev/null; then
      n=$((n + 1))
      echo -e "  ${D}已删除旧脚本: ${c}${N}"
    fi
  done < <(find /root /tmp /usr/local/bin -maxdepth 2 -type f \
             \( -name 'setup*.sh' -o -name 'proxy-node*.sh' \) 2>/dev/null)

  # 别的地方可能还有一份改名后的旧副本, 但那种靠文件名找不到。
  # 这里只处理"标准位置 + 标准命名", 覆盖真实会踩的场景。
  if [ "$n" -gt 0 ]; then
    echo -e "  ${D}共清理 ${n} 份旧副本, 当前脚本: ${self}${N}"
  fi
  return 0
}

# 安装前提醒一次。只在真正要部署时查, 菜单/查看信息不查 —— 那些命令不该等网络。
hint_script_update(){
  local rv meta
  # maybe_self_update 已经查过一次就复用结果: 没必要为了一句提示再下一次。
  if [ -n "${_PN_REMOTE_VER:-}" ]; then
    rv="$_PN_REMOTE_VER"
  else
    rv=$(fetch_remote_version)
  fi
  [ "$rv" = "__unavailable__" ] && return 0   # 上一步已经提示过网络失败
  [ -n "$rv" ] || return 0
  if script_newer "$rv"; then
    warn "有新版本: 当前 v${SCRIPT_VERSION}, 远端 v${rv}"
    echo -e "    ${D}先更新再部署: ${APP_NAME} update install${N}"
    echo -e "    ${D}本次仍按 v${SCRIPT_VERSION} 执行${N}"
    echo
  fi
}

# 部署前把自己换成最新版, 然后 exec 新版继续跑。
#
# 为什么要在"部署入口"上做这件事, 而不是只提供一个 update 子命令:
#   用户的真实用法是"复制那条一键命令 -> 粘进 SSH"。只要他哪天改成敲 proxy
#   install, 或者用了收藏的旧命令, 跑的就是磁盘上那份老脚本。指望用户自己
#   记得先 update 是不现实的 —— 那就让脚本自己在动手前对齐到最新版。
#
# 多道校验(版本更新 / 语法 / 哈希交叉核对 / 体积下限 / 版本一致 / 身份),
# 任何一道不过都退回"用当前版本继续", 绝不阻塞部署:
# PN_SELFUPDATED=1 是一次性闸门: exec 过去之后新版会看到它, 不再重复检查,
# 避免版本号解析异常时 exec 死循环。
maybe_self_update(){
  [ "${PN_NO_SELFUPDATE:-0}" = "1" ] && return 0
  [ "${PN_SELFUPDATED:-0}" = "1" ] && return 0
  # 非 root 跑不到部署那一步(need_root 会拦), 没必要为此下一次两百多 KB,
  # 更没必要因为写不进 /root 而多打一条警告。
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0

  local rv rmeta self tmp newv
  rmeta=$(fetch_remote_version)
  rv="$rmeta"
  if [ -z "$rv" ]; then
    # 拉不到(断网/被墙)不能静默: 用户得知道"这次没确认过是不是最新版"。
    _PN_REMOTE_VER="__unavailable__"
    warn "无法获取远端脚本版本(网络不通或被拦截), 本次按本地 v${SCRIPT_VERSION} 执行"
    return 0
  fi
  # 记下来, 后面的 hint_script_update 直接复用, 不用再下一次
  _PN_REMOTE_VER="$rv"
  script_newer "$rv" || return 0

  self=$(running_script_path)
  if [ -z "$self" ]; then
    # curl | bash: 没有落盘文件。落到标准位置, 顺便让后面能建 proxy 软链。
    self="/root/setup-proxy.sh"
  fi

  warn "发现新版本 v${SCRIPT_VERSION} -> v${rv}, 自动更新后继续部署"
  tmp=$(mktemp 2>/dev/null) || { warn "无法创建临时文件, 继续用 v${SCRIPT_VERSION}"; return 0; }
  if ! fetch_script_verified "$tmp"; then
    rm -f "$tmp"; warn "下载/校验失败, 继续用 v${SCRIPT_VERSION} 部署"; return 0
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"; warn "下载到的文件语法检查失败(可能被劫持), 已丢弃, 继续用 v${SCRIPT_VERSION}"; return 0
  fi
  # 半截文件也能通过 bash -n(语法恰好截断在语句边界), 加一道体积下限
  local sz
  sz=$(wc -c < "$tmp" 2>/dev/null || echo 0)
  if [ "$sz" -lt 100000 ]; then
    rm -f "$tmp"; warn "下载到的文件只有 ${sz} 字节(正常 200KB+), 已丢弃, 继续用 v${SCRIPT_VERSION}"; return 0
  fi
  newv=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" 2>/dev/null | head -1)
  if [ -z "$newv" ]; then
    rm -f "$tmp"; warn "下载到的文件里没有版本号(多半是错误页), 已丢弃, 继续用 v${SCRIPT_VERSION}"; return 0
  fi
  # 镜像可能返回旧版 / 缓存版 / 被替换过的文件: 文件里的版本必须和刚探测到的
  # 远端版本一致, 且必须确实比本地新。cmd_update 早有这两道保护, 自动更新不能漏。
  if [ "$newv" != "$rv" ] || ! script_newer "$newv"; then
    rm -f "$tmp"
    warn "下载到的脚本是 v${newv}(远端声明 v${rv}), 与声明不符或并不比本地新, 已丢弃, 继续用 v${SCRIPT_VERSION}"
    return 0
  fi
  # 身份校验: 只认版本号不够 —— 一个被替换过的文件同样可以带一行 SCRIPT_VERSION。
  # 加这一条, 至少要求它确实是这份脚本(和 cleanup_stale_scripts 用的是同一组标记)。
  if ! grep -q 'Proxy Node Installer' "$tmp" 2>/dev/null; then
    rm -f "$tmp"; warn "下载到的文件不是本脚本(缺少身份标记), 已丢弃, 继续用 v${SCRIPT_VERSION}"; return 0
  fi

  # mv 而不是覆盖: 万一 $self 就是正在跑的这一份, 就地覆盖会让 bash 读到
  # 半新半旧的内容。mv 换 inode, 当前进程继续读旧 inode, 不受影响。
  if ! install_script_file "$tmp" "$self"; then
    rm -f "$tmp"; warn "写入 ${self} 失败, 继续用 v${SCRIPT_VERSION}"; return 0
  fi
  ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null

  ok "已更新到 v${newv}, 用新版本继续"
  echo
  # 参数原样带过去(--clean / fresh 都在里面)。这一步之所以安全, 是因为调用点
  # 在 main 的最前面 —— 那时还没开始攒状态。放在 cmd_install 里就会出事:
  # 向导已经把 PROTOCOLS / CLEAN 这些攒在 shell 变量里了, exec 换进程就全丢。
  if [ "$#" -gt 0 ]; then
    PN_SELFUPDATED=1 exec bash "$self" "$@"
  fi
  PN_SELFUPDATED=1 exec bash "$self"
}

# 把新脚本原子落到 $self, 并留一份 .prev 供 proxy update rollback。
# 临时文件必须在 $self 同目录: /tmp 与 /root 常分属不同挂载, 跨分区 mv 会
# 退化成 copy+unlink, 既不是原子替换, 中途 Ctrl-C 也会留下半截文件 ——
# 注释里「mv 换 inode、当前进程继续读旧 inode」的前提同样不成立。
install_script_file(){
  local tmp="$1" self="$2" dir stmp ptmp=""
  dir=$(dirname "$self")
  mkdir -p "$dir" 2>/dev/null || return 1
  stmp=$(mktemp "${dir}/.pn-update.XXXXXXXXXX") || return 1
  cp -f "$tmp" "$stmp" 2>/dev/null || { rm -f "$stmp"; return 1; }
  chmod 755 "$stmp" 2>/dev/null || { rm -f "$stmp"; return 1; }
  bash -n "$stmp" 2>/dev/null || { rm -f "$stmp"; return 1; }
  # .prev 是唯一的回滚入口, 同样不能就地 cp: 磁盘满时会把好端端的旧版截成
  # 半截, 而新版本已经 mv 成功 —— 用户既回不去, 回滚校验也会被 bash -n 拒掉。
  if [ -f "$self" ]; then
    ptmp=$(mktemp "${dir}/.pn-prev.XXXXXXXXXX") || { rm -f "$stmp"; return 1; }
    cp -f "$self" "$ptmp" 2>/dev/null || { rm -f "$stmp" "$ptmp"; return 1; }
    chmod 755 "$ptmp" 2>/dev/null || { rm -f "$stmp" "$ptmp"; return 1; }
    mv -f "$ptmp" "${self}.prev" 2>/dev/null || { rm -f "$stmp" "$ptmp"; return 1; }
  fi
  mv -f "$stmp" "$self" 2>/dev/null || { rm -f "$stmp"; return 1; }
  chmod 755 "$self" 2>/dev/null
  rm -f "$tmp"
  return 0
}

# 用户自定义 / 远程国内直连名单的管理入口。
# 改完名单要重新生成订阅才生效 —— _rule_after_change 统一处理这件事。
_rule_after_change(){
  if [ -f "$STATE_FILE" ]; then
    if cmd_sub >/dev/null 2>&1; then
      ok "订阅已重新生成, 重新导入客户端后生效"
    else
      warn "名单已保存, 但订阅重新生成失败, 请手动执行: proxy sub"
    fi
  else
    echo "尚未安装节点, 名单已保存, 安装后自动生效"
  fi
}

cmd_rule(){
  local sub="${1:-list}" arg="${2:-}" d f line bad=0 total cnt
  case "$sub" in
    list)
      load_cn_direct
      local _uc=0 _rc=0
      [ -f "$CN_DIRECT_FILE" ] && _uc=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "$CN_DIRECT_FILE" 2>/dev/null)
      [ -f "$CN_DIRECT_REMOTE_FILE" ] && _rc=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "$CN_DIRECT_REMOTE_FILE" 2>/dev/null)
      cnt=0
      for d in $CN_DIRECT_ACTIVE; do cnt=$((cnt + 1)); done
      echo
      echo "国内直连名单 (三端订阅共用同一份)"
      echo "──────────────────────────────────────────────"
      echo "内置清单    : $(echo $CN_DIRECT_SUFFIXES | wc -w) 个域名"
      echo "用户自定义  : ${_uc:-0} 个  ($CN_DIRECT_FILE)"
      echo "远程更新    : ${_rc:-0} 个  ($CN_DIRECT_REMOTE_FILE)"
      echo "合并去重后  : ${cnt} 个域名 + $(echo $CN_DIRECT_KEYWORDS | wc -w) 个关键词"
      echo
      echo "用户文件: $CN_DIRECT_FILE   (一行一个域名, # 开头是注释)"
      echo "远程文件: $CN_DIRECT_REMOTE_FILE   (proxy rule update 更新, 别手改)"
      echo
      echo "当前生效的全部直连域名:"
      for d in $CN_DIRECT_ACTIVE; do echo "  $d"; done
      ;;
    check)
      echo
      for f in "$CN_DIRECT_FILE" "$CN_DIRECT_REMOTE_FILE"; do
        if [ ! -f "$f" ]; then echo "$f : 不存在(可选)"; continue; fi
        echo "$f :"
        total=0
        while IFS= read -r line || [ -n "$line" ]; do
          d="${line%%#*}"; d="${d//[[:space:]]/}"
          [ -n "$d" ] || continue
          total=$((total + 1))
          d="${d,,}"
          if ! valid_domain "$d"; then
            echo "  非法(已忽略): ${line}"
            bad=$((bad + 1))
          fi
        done < "$f"
        echo "  共 ${total} 条域名"
      done
      echo
      if [ "$bad" -eq 0 ]; then ok "名单格式检查通过"; else warn "有 ${bad} 行非法(已忽略, 不影响订阅)"; fi
      ;;
    add)
      need_root
      d="${arg,,}"
      if [ -z "$d" ] || ! valid_domain "$d"; then
        die "域名不合法: '${arg}' (要形如 taobao.com, 不带通配/路径/IP)"
      fi
      mkdir -p "$STATE_DIR" 2>/dev/null
      if [ -f "$CN_DIRECT_FILE" ] && grep -qxF "$d" "$CN_DIRECT_FILE" 2>/dev/null; then
        echo "$d 已在用户名单中"
      else
        printf '%s\n' "$d" >> "$CN_DIRECT_FILE"
        ok "已加入用户名单: $d"
      fi
      _rule_after_change
      ;;
    rm|del)
      need_root
      d="${arg,,}"
      [ -n "$d" ] || die "要删除的域名不能为空"
      if [ ! -f "$CN_DIRECT_FILE" ] || ! grep -qxF "$d" "$CN_DIRECT_FILE" 2>/dev/null; then
        echo "$d 不在用户名单中(内置/远程名单不受此命令影响)"
      else
        # grep 没有匹配行时返回 1 —— 删的正是名单里唯一一条时就会这样,
        # 原来的 `&& mv` 于是不执行, 却照样报"已移除", 还留下 .tmp 垃圾。
        local rf=""
        rf=$(mktemp "${CN_DIRECT_FILE}.XXXXXX" 2>/dev/null) || die "无法创建临时文件"
        # grep 读失败会写出部分行甚至空文件; 原来 || true 吞掉非零, 下面的校验
        # 在空文件里自然查不到目标就放行, 再把空文件 mv 过去 —— 整个名单被清空。
        if ! grep -vxF "$d" "$CN_DIRECT_FILE" > "$rf" 2>/dev/null; then
          rm -f "$rf"; die "删除失败: 过滤用户名单出错"
        fi
        if grep -qxF "$d" "$rf" 2>/dev/null; then
          rm -f "$rf"; die "删除失败: ${d} 仍在名单中"
        fi
        mv -f "$rf" "$CN_DIRECT_FILE" 2>/dev/null || { rm -f "$rf"; die "写入用户名单失败"; }
        ok "已从用户名单移除: $d"
      fi
      _rule_after_change
      ;;
    update)
      need_root
      local tmp
      tmp=$(mktemp 2>/dev/null) || die "无法创建临时文件"
      if ! fetch_rules_verified "$tmp"; then
        rm -f "$tmp"; die "规则更新失败, 现有名单保持不变"
      fi
      mkdir -p "$STATE_DIR" 2>/dev/null
      [ -f "$CN_DIRECT_REMOTE_FILE" ] && cp -f "$CN_DIRECT_REMOTE_FILE" "${CN_DIRECT_REMOTE_FILE}.bak" 2>/dev/null
      if ! mv -f "$tmp" "$CN_DIRECT_REMOTE_FILE" 2>/dev/null; then
        rm -f "$tmp"; die "写入规则文件失败"
      fi
      cnt=$(grep -cv '^[[:space:]]*#\|^[[:space:]]*$' "$CN_DIRECT_REMOTE_FILE" 2>/dev/null)
      cnt=${cnt:-0}
      ok "远程规则已更新: ${cnt} 条域名 (旧版备份在 ${CN_DIRECT_REMOTE_FILE}.bak)"
      _rule_after_change
      ;;
    *)
      cat <<'RULEUSAGE'
用法: proxy rule <子命令>
  list              查看当前生效的国内直连名单(内置+用户+远程, 已去重)
  check             检查用户/远程名单文件格式, 报告非法行
  add <域名>        加一个域名到用户名单, 如 proxy rule add taobao.com
  rm <域名>         从用户名单移除一个域名(不影响内置/远程)
  update            从官方源更新远程规则(官方优先+镜像交叉核对, 失败不动现有名单)
RULEUSAGE
      ;;
  esac
}

cmd_update(){
  need_root
  local next="${1:-}" extra="${2:-}" self tmp newv cur
  cur="$SCRIPT_VERSION"

  echo
  echo -e "${M}============================================================${N}"
  echo -e "${M}   更新脚本${N}"
  echo -e "${M}============================================================${N}"
  echo
  echo -e "  当前版本: ${Y}v${cur}${N} (${BUILD_DATE})"

  self=$(running_script_path)
  if [ -z "$self" ]; then
    # curl | bash 方式运行: 没有落盘的文件, 只能装到标准位置
    self="/root/setup-proxy.sh"
    warn "当前不是从文件运行的, 更新会写到 ${self}"
  fi
  echo -e "  脚本路径: ${self}"

  # 更新后跑不起来时唯一的自救入口。.prev 由 install_script_file 留。
  case "$next" in
    rollback|revert|--rollback)
      [ -f "${self}.prev" ] || die "没有可回滚的版本 (${self}.prev 不存在)"
      bash -n "${self}.prev" 2>/dev/null || die "备份版本语法损坏, 拒绝回滚"
      # 不能 cp -a 直接覆盖正在运行的脚本: cp 先 truncate, 磁盘满/被 kill 会
      # 把唯一自救入口写成半截文件。同目录临时文件 + mv 换 inode 才是原子的。
      # 也不用 install_script_file: 它会把当前(坏)版本写进 .prev, 毁掉回滚点。
      local _rb
      _rb=$(mktemp "$(dirname "$self")/.pn-rollback.XXXXXXXX") || die "无法创建回滚临时文件"
      cp -f "${self}.prev" "$_rb" 2>/dev/null || { rm -f "$_rb"; die "回滚写入失败(磁盘满/权限?)"; }
      chmod 755 "$_rb" 2>/dev/null
      bash -n "$_rb" 2>/dev/null || { rm -f "$_rb"; die "回滚副本语法损坏, 已中止(原文件未改动)"; }
      mv -f "$_rb" "$self" || { rm -f "$_rb"; die "回滚替换失败, 原文件未改动"; }
      chmod 755 "$self" 2>/dev/null
      ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null
      ok "已回滚到上一版: $(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/v\1/p' "$self" | head -1)"
      return 0 ;;
  esac

  tmp=$(mktemp 2>/dev/null) || die "无法创建临时文件"
  info "正在下载最新版本 ..."
  # 自更新走"多源交叉比对": 语法/版本/身份校验都来自下载物自证, 镜像被
  # 替换时挡不住。见 fetch_script_verified。
  if ! fetch_script_verified "$tmp"; then
    rm -f "$tmp"
    die "下载/校验失败 (网络不通、被拦截, 或各源内容不一致)。手动更新: curl -fsSL ${SCRIPT_URL} -o ${self}"
  fi

  # 三道校验: 语法能过、里面有版本号。缺一不可 —— 网络劫持/半截文件/错误页
  # 直接覆盖上去, 下次敲 proxy 就是一屏语法错误。
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "下载到的文件语法检查失败, 已丢弃(可能是网络劫持或文件不完整)"
  fi
  newv=$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' "$tmp" | head -1)
  if [ -z "$newv" ]; then
    rm -f "$tmp"
    die "下载到的文件里没有版本号, 已丢弃(多半是被替换成了错误页)"
  fi
  # 和 maybe_self_update 同一道身份校验: 镜像返回的也可能是一张 200 的错误页
  if ! grep -q 'Proxy Node Installer' "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "下载到的文件不是本脚本(缺少身份标记), 已丢弃"
  fi

  # 版本号相同才算"已是最新"。改成只比版本号后, 每次发版必须递增版本号,
  # 否则改了代码却同号, proxy update 会把修复挡在门外。
  if [ "$newv" = "$cur" ]; then
    rm -f "$tmp"
    ok "已经是最新版 v${cur}, 无需更新"
    # 内容一样也顺手修一遍权限和软链 —— 之前踩过 644 导致 Permission denied
    chmod 755 "$self" 2>/dev/null
    ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null
    # proxy update install: 即使已是最新版, 后续动作也必须照跑。以前这里直接
    # return 0, 导致"更新+重装"组合命令在已是最新版时静默丢掉 install ——
    # 用户以为重装完成, 实际什么都没做。和下面"不比远端新"分支保持一致。
    case "$next" in
      "") ;;
      *) info "用本地 v${cur} 继续执行: ${next}"; exec bash "$self" "$next" ${extra:+"$extra"} ;;
    esac
    return 0
  fi

  # 远端不比本地新才跳过(开发版 / 仓库回滚)。版本号严格递增, 纯比 x.y.z 即可。
  # maybe_self_update / hint_script_update 用的是同一个判据。
  if ! script_newer "$newv"; then
    rm -f "$tmp"
    ok "本地 v${cur} 不比远端 v${newv} 旧, 已跳过更新(不降级)"
    echo -e "  ${D}远端可能还没发布该版本; 确实要强制回退请手动 curl -o 覆盖 ${self}${N}"
    chmod 755 "$self" 2>/dev/null
    ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null
    # proxy update install 之类的组合命令: 更新虽跳过, 后续动作照跑
    case "$next" in
      "") ;;
      *) info "用本地 v${cur} 继续执行: ${next}"; exec bash "$self" "$next" ${extra:+"$extra"} ;;
    esac
    return 0
  fi

  # 用 mv 而不是重定向覆盖: bash 是边读边执行脚本文件的, 就地覆盖会让正在跑的
  # 这一份读到半新半旧的内容。mv 换 inode, 当前进程继续读旧 inode, 不受影响。
  install_script_file "$tmp" "$self" || { rm -f "$tmp"; die "写入 ${self} 失败(旧版本未改动, 可用 proxy update rollback 确认)"; }
  ln -sf "$self" "/usr/local/bin/${APP_NAME}" 2>/dev/null

  ok "已更新: v${cur} -> v${newv}"
  echo -e "  ${D}本次仍由旧版跑完, 新版本从下一条命令开始生效${N}"
  # 顺手把其它位置的旧副本清掉, 免得哪天顺手 bash 了旧路径又跑回老代码
  cleanup_stale_scripts

  # 脚本只是入口: healthcheck.sh / 订阅 server.py / systemd unit 都是安装时
  # 由本脚本内嵌 heredoc 写死的。只换 .sh 会让它们永远停在旧版 ——
  # 安全修复看似更新了, 实际没生效。
  # 注意: 当前进程已经把旧版函数读进内存了, 在这里直接调 install_healthcheck
  # 跑的还是旧代码。必须交给新脚本进程(它读的是刚替换的文件)去做。
  if load_state >/dev/null 2>&1; then
    if FORCE_UNIT_REFRESH=1 bash "$self" __refresh_units >/dev/null 2>&1; then
      ok "已用新版本刷新: healthcheck / 订阅服务 / xray + sing-box 单元"
    else
      warn "刷新单元失败, 执行 proxy install(幂等, 凭据不变) 可重试"
    fi
    echo -e "  ${D}hysteria2 单元与内核二进制不在 update 范围, 需要时执行 proxy install(幂等, 凭据不变)${N}"
  fi
  echo

  # proxy update install: 更新完直接接着部署, 省得再敲一遍
  case "$next" in
    "") ;;
    *)
      info "用新版本继续执行: ${next}"
      exec bash "$self" "$next" ${extra:+"$extra"}
      ;;
  esac
}

cmd_upgrade(){
  need_root
  # 不 load_state 的话 proto_on reality 会用默认值恒真: 纯 hy2 节点执行 upgrade
  # 会装出一个没有 service / 配置的孤儿 xray, 再误报"启动失败且无备份"。
  load_state || die "尚未安装"
  proto_on reality || die "当前未启用 REALITY, 没有可升级的 xray 内核"
  local target="${1:-latest}" asset tmp sha_arch
  case "$(uname -m)" in
    x86_64|amd64)  asset="Xray-linux-64.zip";        sha_arch="64" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip"; sha_arch="arm64" ;;
    *) die "不支持的架构" ;;
  esac

  # 回滚: 用 upgrade 时留下的上一版二进制
  if [ "$target" = "--rollback" ] || [ "$target" = "rollback" ]; then
    [ -x "${XRAY_BIN}.prev" ] || die "没有可回滚的版本(只有执行过 upgrade 才会留下备份)"
    systemctl stop xray >/dev/null 2>&1
    # cp -f 是 O_TRUNC: 磁盘满时先截掉旧二进制再失败, 留下半截文件, die 之后
    # 服务还停在停止状态 —— 比不回滚更糟。改成同目录临时文件 + mv 原子替换,
    # 任何一步失败都先把服务拉起来再说。
    local rb_tmp=""
    rb_tmp=$(mktemp "${XRAY_BIN}.XXXXXX") || {
      systemctl start xray >/dev/null 2>&1
      die "回滚失败: 无法创建临时文件, 已尝试重新启动当前 xray"
    }
    if ! cp -f "${XRAY_BIN}.prev" "$rb_tmp" 2>/dev/null \
       || ! chmod 755 "$rb_tmp" 2>/dev/null \
       || ! mv -f "$rb_tmp" "$XRAY_BIN" 2>/dev/null; then
      rm -f "$rb_tmp"
      systemctl start xray >/dev/null 2>&1
      die "回滚失败: 无法覆盖 ${XRAY_BIN} (磁盘满/权限?), 已尝试重新启动当前 xray"
    fi
    systemctl start xray >/dev/null 2>&1
    wait_active xray || die "回滚后启动失败, 查看: journalctl -u xray -n 30"
    # 二进制换了, 安装时记的基准哈希就过期了。不同步的话, 下一次 proxy verify
    # 会报"二进制被改动, 可能被人替换" —— 自己升级造成的假警报, 比真报警更糟
    XRAY_BIN_SHA=$(file_sha256 "$XRAY_BIN")
    update_state_kv XRAY_BIN_SHA "$XRAY_BIN_SHA"
    # 版本号也必须跟着回退: ensure_xray 是按 XRAY_VERSION 判断"已装哪一版"的,
    # 只改哈希不改版本, 下一次 install / restore 会把内核下回 state 里那个旧版本。
    # 先整段落变量再抠版本: `... | head -1` 在 pipefail 下会让上游吃 SIGPIPE。
    local rv rvout=""
    rvout=$("$XRAY_BIN" version 2>/dev/null) || rvout=""
    rv=$(printf '%s\n' "$rvout" | head -1 | awk '{print $2}' | tr -d 'v')
    [ -n "$rv" ] || die "回滚后无法读取 xray 版本, 请人工检查 $XRAY_BIN"
    XRAY_VERSION="$rv"; update_state_kv XRAY_VERSION "$XRAY_VERSION"
    ok "已回滚: $($XRAY_BIN version 2>/dev/null | head -1)"
    # 与升级成功分支对称: 订阅里的 MLKEM 开关 / REALITY 出口按 XRAY_VERSION 决定。
    # 只回退内核与 state 却不重生成, 客户端仍拿"新版"配置连旧内核, 回滚不彻底。
    if ( gen_links && gen_sub_files >/dev/null 2>&1 ); then
      ok "订阅已按回滚后的内核版本重新生成, 客户端重新导入即可"
    else
      warn "订阅重新生成失败, 请手动执行: proxy sub"
    fi
    return 0
  fi

  # latest 先解析成具体版本号, 否则既没法校验, 也不知道装了什么
  if [ "$target" = "latest" ]; then
    info "查询 Xray 最新版本..."
    target=$(xray_latest_version)
    if [ -z "$target" ]; then
      die "查询最新版本失败(GitHub API 不可达)。请直接指定版本: proxy upgrade 26.3.27"
    fi
    info "最新版本: ${target}"
  fi
  target="${target#v}"

  # 兼容性提示(实测矩阵见 write_clash_yaml 上方): 26.9.8+ 服务端强制要求
  # MLKEM key share, xray 内核原生支持, mihomo 1.19.10+ 加开关即可(本脚本
  # 生成的 clash.yaml 已按版本自动写), sing-box 1.14.4 仍不支持(上游 #4520)。
  echo
  warn "升级到 ${target} 后如出现「开关变绿但打不开网页」: Xray >= 26.9.8 的 REALITY"
  echo "  强制要求 X25519MLKEM768, 客户端不支持就会认证失败(不是升级失败)。"
  echo "  xray 内核原生支持; mihomo >= 1.19.10 用 clash.yaml 即可; sing-box 请用 HY2。"
  echo

  local url="https://github.com/XTLS/Xray-core/releases/download/v${target}/${asset}"

  ask_yes "安装 Xray ${target}?  当前: $($XRAY_BIN version 2>/dev/null | head -1)" || { info "已取消"; return 0; }

  tmp=$(mktemp -d) || die "无法创建临时目录"
  download_with_mirror "$url" "$tmp/x.zip" || { rm -rf "$tmp"; die "下载失败(版本号是否存在?)"; }
  # 升级同样要校验: 安装时校验再严, 一条 upgrade 也能装进被换过的内核。
  # 用 xray_expected_sha 从官方 .dgst 动态取该版本哈希 —— 否则升级到任何
  # 未内置哈希的新版本都会被 verify_sha256 拒掉(旧实现就是这么把升级卡死的)。
  local _want_sha _prev_tmp=""
  _want_sha=$(xray_expected_sha "$target" "$sha_arch" "$asset") \
    || { rm -rf "$tmp"; die "Xray 校验值获取失败, 已中止升级"; }
  verify_sha256 "$tmp/x.zip" "$_want_sha" "Xray ${target}" \
    || { rm -rf "$tmp"; die "Xray 校验未通过, 已中止升级"; }
  unzip -o -q "$tmp/x.zip" -d "$tmp/pkg" || { rm -rf "$tmp"; die "解压失败"; }
  [ -f "$tmp/pkg/xray" ] || { rm -rf "$tmp"; die "压缩包内未找到 xray"; }

  # 留一份当前版本, 便于 --rollback。就地 cp -f 会用 O_TRUNC 截断 .prev,
  # 磁盘满/中断时留下半截文件, 之后 --rollback 或升级失败回滚会装上损坏二进制。
  # 同目录临时文件 + 原子 mv, 失败即中止升级(没有回滚点就别动主二进制)。
  if [ -x "$XRAY_BIN" ]; then
    _prev_tmp=$(mktemp "$(dirname "$XRAY_BIN")/.xray-prev.XXXXXX" 2>/dev/null) || _prev_tmp=""
    if [ -z "$_prev_tmp" ] || ! cp -f "$XRAY_BIN" "$_prev_tmp" 2>/dev/null \
       || ! mv -f "$_prev_tmp" "${XRAY_BIN}.prev" 2>/dev/null; then
      rm -f "$_prev_tmp"
      die "无法保存 Xray 回滚点, 已中止升级"
    fi
    chmod 755 "${XRAY_BIN}.prev" 2>/dev/null || true
  fi
  systemctl stop xray >/dev/null 2>&1
  # 装失败(磁盘满/只读/权限)必须当场中止: 否则旧二进制还在、下面 start 又能起来、
  # wait_active 误判成功, 最后却把新版本号和新哈希写进 state —— state 声称新版,
  # 实际跑的是旧内核。失败时先恢复旧二进制再启动, 保证不留半截状态。
  if ! install -m 755 "$tmp/pkg/xray" "$XRAY_BIN"; then
    rm -rf "$tmp"
    [ -x "${XRAY_BIN}.prev" ] && cp -f "${XRAY_BIN}.prev" "$XRAY_BIN" 2>/dev/null
    systemctl start xray >/dev/null 2>&1 || true
    die "安装 Xray 新二进制失败(磁盘空间或权限?), 已恢复旧版本。查看: journalctl -u xray -n 30"
  fi
  rm -rf "$tmp"
  systemctl start xray >/dev/null 2>&1
  # 这里误判的代价最大: 一个完全可用的新版本会被判成"启动失败"然后回滚,
  # 用户看到的是升级失败, 实际上什么都没坏。轮询到底再下结论。
  if ! wait_active xray; then
    warn "新版本启动失败, 尝试回滚"
    if [ -x "${XRAY_BIN}.prev" ] && cp -f "${XRAY_BIN}.prev" "$XRAY_BIN" 2>/dev/null; then
      systemctl start xray >/dev/null 2>&1
      if wait_active xray; then
        XRAY_BIN_SHA=$(file_sha256 "$XRAY_BIN")
        update_state_kv XRAY_BIN_SHA "$XRAY_BIN_SHA"
        local rv2
        rv2=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}' | tr -d 'v')
        [ -n "$rv2" ] && { XRAY_VERSION="$rv2"; update_state_kv XRAY_VERSION "$XRAY_VERSION"; }
        die "新版本启动失败, 已回滚到上一版本并恢复服务。查看: journalctl -u xray -n 30"
      fi
      die "新版本启动失败, 二进制已回滚但服务仍未起来。手动排查: journalctl -u xray -n 50"
    fi
    die "新版本启动失败, 且没有可回滚的备份(${XRAY_BIN}.prev 不存在)。手动排查: journalctl -u xray -n 50"
  fi
  ok "已安装: $($XRAY_BIN version 2>/dev/null | head -1)"
  # 同步基准哈希: 否则 proxy verify 会把这次升级当成"二进制被人替换"
  XRAY_BIN_SHA=$(file_sha256 "$XRAY_BIN")
  update_state_kv XRAY_BIN_SHA "$XRAY_BIN_SHA"
  # 版本号一起写回 state: ensure_xray 靠它判断"已装哪一版", 不写的话下一次
  # install / restore 会把内核静默下载回 26.3.27, 等于把刚升的版本降回去。
  XRAY_VERSION="$target"
  update_state_kv XRAY_VERSION "$XRAY_VERSION"
  # clash.yaml 里的 reality-opts(MLKEM 开关)是按 XRAY_VERSION 决定的。升完内核
  # 不重新生成, 手上的订阅还是按旧版本写的 —— 客户端表现为"认证失败", 而
  # 脚本刚刚才提示"用 clash.yaml 即可"。放子 shell 里跑, 失败也不影响已完成的升级。
  if ( gen_links && gen_sub_files >/dev/null 2>&1 ); then
    ok "订阅已按新内核版本重新生成, 客户端重新导入即可"
  else
    warn "订阅重新生成失败, 请手动执行: proxy sub"
  fi
  echo -e "${D}回滚: proxy upgrade --rollback${N}"
}

# ---------------- 清理 ----------------
# 只删本脚本创建的东西; remove_script=1 时连管理命令与脚本一起删
# 列出旧实例残留项; 有残留返回 0 并把清单打到 stdout
residue_report(){
  local found=0 out=""
  [ -f /etc/systemd/system/xray.service ]            && { out+="    - systemd: xray.service"$'\n'; found=1; }
  [ -f /etc/systemd/system/hysteria-server.service ] && { out+="    - systemd: hysteria-server.service"$'\n'; found=1; }
  [ -f /etc/systemd/system/hy2-hop.service ]         && { out+="    - systemd: hy2-hop.service"$'\n'; found=1; }
  [ -f /etc/systemd/system/proxy-sub.service ]       && { out+="    - systemd: proxy-sub.service"$'\n'; found=1; }
  [ -f /etc/systemd/system/proxy-healthcheck.timer ] && { out+="    - systemd: proxy-healthcheck.timer"$'\n'; found=1; }
  [ -f /etc/systemd/system/sing-box.service ]        && { out+="    - systemd: sing-box.service"$'\n'; found=1; }
  [ -x "$SB_BIN" ]                                   && { out+="    - 二进制: $SB_BIN"$'\n'; found=1; }
  [ -d /etc/sing-box ]                               && { out+="    - 配置: /etc/sing-box"$'\n'; found=1; }
  [ -x "$XRAY_BIN" ]                                 && { out+="    - 二进制: $XRAY_BIN"$'\n'; found=1; }
  [ -x "$HY2_BIN" ]                                  && { out+="    - 二进制: $HY2_BIN"$'\n'; found=1; }
  [ -d /usr/local/etc/xray ]                         && { out+="    - 配置: /usr/local/etc/xray"$'\n'; found=1; }
  [ -d /etc/hysteria ]                               && { out+="    - 配置: /etc/hysteria"$'\n'; found=1; }
  # 状态/订阅目录若是空的(上次装一半就退出留下的壳), 直接抹掉, 不拿它打扰用户
  local d
  for d in "$STATE_DIR" "$SUB_DIR"; do
    [ -d "$d" ] || continue
    if [ -n "$(find "$d" -mindepth 1 ! -type d -print -quit 2>/dev/null)" ]; then
      out+="    - 状态: $d"$'\n'; found=1
    else
      rm -rf "$d" 2>/dev/null || true
    fi
  done
  [ "$found" = "0" ] && return 1
  printf '%s' "$out"
  return 0
}

# 安装前的清理闸门, 内嵌在 install 流程里, 不需要单独跑 clean
# $1: 1=状态文件可读(正常安装过) 0=状态缺失
# 返回 0=直接继续, 1=已清理(调用方要重置内存凭据并按全新安装处理)
install_clean_gate(){
  local state_ok="${1:-0}" residue=""

  if [ "$CLEAN" = "1" ]; then
    info "CLEAN=1 / --clean: 先清理旧实例再安装"
    do_clean 0
    # 消费掉这个开关: 菜单/向导是同一个 shell 里的循环, 不复位的话下一次
    # "部署"会再次无确认清空凭据(users.txt 一起删), 所有客户端静默失效。
    CLEAN=0; export CLEAN
    return 1
  fi

  # 正常安装(状态可读): 原地幂等重部署, 不弹菜单打扰
  if [ "$state_ok" = "1" ]; then
    info "如需全新安装(换凭据/清端口), 加 --clean 参数重跑"
    return 0
  fi

  # 状态缺失但有残留文件, 可能是"本脚本上次装到一半", 也可能是"这台机器上原本
  # 就有别的脚本 / 用户自己装的 xray、hysteria、sing-box"。后者绝对不能删 ——
  # 非交互模式(ASSUME_YES=1, 一键部署最常见)下以前会直接 do_clean 把它们抹掉。
  # 只认本脚本自己留下的标记。
  local ours=0
  if [ -d "$STATE_DIR" ] || [ -f /root/proxy-info.txt ] \
     || [ -e "/usr/local/bin/${APP_NAME}" ] \
     || [ -f /usr/local/bin/proxy-healthcheck.sh ]; then
    ours=1
  fi

  # 状态缺失但有残留文件 = 上次装到一半的残缺安装, 不清理必然端口冲突
  residue=$(residue_report) || return 0

  if [ "$ours" != "1" ]; then
    echo
    warn "机器上已有 xray / hysteria / sing-box, 但没有本脚本的安装标记:"
    printf '%s' "$residue"
    warn "这些不是本脚本装的, 不会自动清理(删掉别人的节点是不可逆的)"
    warn "若端口冲突, 先自行停用它们, 或换端口安装:"
    echo -e "    ${D}VLESS_PORT=8443 HY2_PORT=8443 bash /root/setup-proxy.sh install${N}"
    return 0
  fi

  echo
  warn "检测到残缺安装的残留文件:"
  printf '%s' "$residue"
  echo
  echo -e "${D}  这些是上次安装中断留下的, 不清理会占端口导致新配置起不来。${N}"

  # 真正试着打开一次 /dev/tty 再决定要不要问, 和 read_tty 的行为保持一致
  if [ "$ASSUME_YES" = "1" ] || ! { : 2>/dev/null >/dev/tty; }; then
    warn "非交互模式: 自动清理残缺安装"
    # state 读不出来不等于没救: users.txt 里可能是唯一一份设备 UUID。
    # 自动清理前先留一份, 至少还能人工翻回来(do_clean 会整目录删掉)。
    if [ -d "$STATE_DIR" ] && [ -n "$(ls -A "$STATE_DIR" 2>/dev/null)" ]; then
      local _bak
      _bak="/root/proxy-state-before-clean.$(date +%Y%m%d-%H%M%S).tar.gz"
      if ( umask 077; tar -czf "$_bak" -C "$STATE_DIR" . 2>/dev/null ); then
        warn "清理前已备份状态目录: ${_bak}"
      else
        warn "状态目录备份失败, 仍继续清理(原目录会被删除)"
      fi
    fi
    do_clean 0
    return 1
  fi

  if ask_yes "清理这些残留并全新安装?"; then
    do_clean 0
    return 1
  fi
  die "已取消。加 --clean 参数重跑即可自动清理: bash setup-proxy.sh install --clean"
}

do_clean(){
  # 清理是所有路径(命令行 clean、菜单 c/u、向导 c、协议变更、安装前闸门)的
  # 汇合点, 锁必须放在这里才能全覆盖。之前只在 main 的命令行分支加锁,
  # 菜单和向导绕过 main 的 case, 与并发安装/升级同时改系统状态会互相踩踏。
  # acquire_lock 同进程幂等, 已在 main 加过锁的路径不会重复 flock。
  acquire_lock
  local remove_script="${1:-0}" hop="" hp="" p o
  local vport="" hport="" allports="" _sp

  # 端口跳跃信息随后就被删掉, 先取出来
  # 注意: 不能在这里 load_state, 会把命令行传入的 VLESS_PORT 等环境变量覆盖回旧值
  if [ -f "$STATE_FILE" ]; then
    # 一律走 state_get: 只按白名单键逐行读纯字符串, 不 source 也不执行文件
    [ -n "$hop" ]   || hop=$(state_get "$STATE_FILE" HY2_HOP 2>/dev/null)
    [ -n "$hp" ]    || hp=$(state_get "$STATE_FILE" HY2_PORT 2>/dev/null)
    # 复查端口用旧配置的端口, 比内存里的更准
    [ -n "$vport" ] || vport=$(state_get "$STATE_FILE" VLESS_PORT 2>/dev/null)
    [ -n "$hport" ] || hport=$(state_get "$STATE_FILE" HY2_PORT 2>/dev/null)
    # 复查必须覆盖所有启用过的端口, 不能只看 VLESS/HY2 两个。
    # state 目录随后就被删了, 所以要在这里先取出来。
    for _sp in VLESS_PORT HY2_PORT SS2022_PORT ANYTLS_PORT TUIC_PORT SUB_PORT; do
      p=$(state_get "$STATE_FILE" "$_sp" 2>/dev/null) || p=""
      [ -n "$p" ] && allports="${allports} ${p}"
    done
  fi

  # 旧版还有个 hysteria.service(无 -server 后缀), 不清会留下一个孤儿 unit
  systemctl disable --now xray hysteria-server hysteria sing-box hy2-hop proxy-sub proxy-healthcheck.timer >/dev/null 2>&1 || true

  rm -f /etc/systemd/system/xray.service /etc/systemd/system/hysteria-server.service \
        /etc/systemd/system/hysteria.service /etc/systemd/system/sing-box.service \
        /etc/systemd/system/hy2-hop.service /etc/systemd/system/proxy-sub.service \
        /etc/systemd/system/proxy-healthcheck.service /etc/systemd/system/proxy-healthcheck.timer
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true

  # 只杀本脚本自己的二进制, 不碰系统里其它程序
  pkill -f '^/usr/local/bin/xray' >/dev/null 2>&1 || true
  pkill -f '^/usr/local/bin/hysteria' >/dev/null 2>&1 || true
  pkill -f '^/usr/local/bin/sing-box' >/dev/null 2>&1 || true
  sleep 1

  # 端口跳跃的 NAT 规则(可能残留多条)。
  # iptables 的区间写法是 start:end, 而 state 里存的是 20000-30000 —— 直接用
  # 连字符去 -C 永远匹配不上, 规则会一直留在这台机器上。
  if [ -n "$hop" ] && [ -n "$hp" ]; then
    local hop_r="${hop/-/:}"
    while iptables -t nat -C PREROUTING -p udp --dport "$hop_r" -j REDIRECT --to-ports "$hp" 2>/dev/null; do
      iptables -t nat -D PREROUTING -p udp --dport "$hop_r" -j REDIRECT --to-ports "$hp" 2>/dev/null || break
    done
  fi
  # 上面只认 state.env 里当前那一段; 改过区间的机器还有历史规则, 全量枚举清一遍
  hop_cleanup_rules
  # ufw/firewalld 放行的端口也必须撤: 否则 clean 完旧端口还开着
  firewall_undo

  rm -rf /usr/local/etc/xray /usr/local/share/xray /etc/hysteria /etc/sing-box "$SUB_DIR" "$STATE_DIR" "${STATE_DIR}.before-restore" "${STATE_DIR}.before-restore.certs"
  # 订阅 HTTP 服务的 server.py 也在 /usr/local/lib 下, 不删就是一套没人管的订阅服务端
  rm -rf /usr/local/lib/proxy-sub
  rm -f "$XRAY_BIN" "${XRAY_BIN}.prev" "$HY2_BIN" "$SB_BIN" /root/proxy-info.txt \
        /usr/local/bin/proxy-healthcheck.sh \
        /etc/sysctl.d/99-proxy-optimize.conf \
        /etc/security/limits.d/99-proxy-nofile.conf \
        /etc/systemd/journald.conf.d/99-proxy-size.conf \
        "$LOG_FILE" /root/proxy-diag-*.txt "${STATE_DIR}.before-reset" "${STATE_DIR}.before-reset.svc" \
        "${STATE_DIR}.before-dest" "${STATE_DIR}.before-dest.svc"
  sysctl --system >/dev/null 2>&1 || true
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  rm -f /run/proxy-healthcheck.fail /run/proxy-healthcheck.tick
  rm -rf /run/proxy-hc

  if [ "$remove_script" = "1" ]; then
    rm -f "/usr/local/bin/${APP_NAME}" /root/setup-proxy.sh
    # 脚本也可能从改名过的路径运行。只删通过身份校验的本脚本副本,
    # 别把用户自己的 .sh 一起删了。
    local cur=""
    cur=$(running_script_path 2>/dev/null || echo "")
    if [ -n "$cur" ] && [ -f "$cur" ] && [ "$cur" != "/root/setup-proxy.sh" ]; then
      if grep -q '^SCRIPT_VERSION=' "$cur" 2>/dev/null \
         && grep -q 'Proxy Node Installer' "$cur" 2>/dev/null; then
        rm -f "$cur" 2>/dev/null && ok "已删除当前运行的脚本副本: ${cur}"
      fi
    fi
  fi

  # 复查端口是否真的空了: 以前只查 VLESS/HY2, 扩展协议端口漏检
  [ -n "$allports" ] || allports="${vport:-${VLESS_PORT:-443}} ${hport:-${HY2_PORT:-443}}"
  for p in $allports; do
    o=$(port_owner "$p" tcp) || o=""
    [ -n "$o" ] && warn "TCP ${p} 仍被其它进程占用: ${o}"
    o=$(port_owner "$p" udp) || o=""
    [ -n "$o" ] && warn "UDP ${p} 仍被其它进程占用: ${o}"
  done
  return 0
}

cmd_clean(){
  need_root
  local remove_script=0 force=0 a
  for a in "$@"; do
    case "$a" in
      --all|--purge)   remove_script=1 ;;
      --yes|-y|--force) force=1 ;;
    esac
  done

  echo
  err "即将清除本脚本创建的全部内容"
  echo "  服务   xray / hysteria-server / hy2-hop / proxy-sub / proxy-healthcheck"
  echo "  配置   ${XRAY_CFG}"
  echo "         ${HY2_CFG}"
  echo "         ${STATE_DIR}   (含全部凭据与设备列表)"
  echo "  订阅   ${SUB_DIR}"
  echo "  系统   sysctl / 句柄数 / journald 限容 / 端口跳跃 iptables 规则 / 本脚本放行的防火墙端口"
  [ "$remove_script" = "1" ] && echo "  脚本   管理命令 ${APP_NAME} 与 /root/setup-proxy.sh"
  echo
  echo -e "${D}swap 会保留(不影响重装); 不会动系统里的其它服务${N}"
  echo
  if [ "$force" != "1" ] && [ "$ASSUME_YES" != "1" ]; then
    ask_yes "确认清除?" || { info "已取消"; return 0; }
  fi

  do_clean "$remove_script"
  ok "已清除, 端口应已释放"
  if [ "$remove_script" != "1" ]; then
    echo -e "${D}管理命令 ${APP_NAME} 仍在, 运行 ${APP_NAME} 选 1 即可重新部署${N}"
  fi
  echo
}

# ---------------- 部署向导 ----------------
# 无参数运行(或管理菜单选"部署向导")时进入: 先点选要开的协议, 再开始装
wizard(){
  local sel="" picked="" tok cur="" want_clean=0 want_opt=0 want_tz=0 bad=0 _pause=""

  # 没有可用终端就没法点选, 直接给出等价的非交互写法
  if ! { : 2>/dev/null >/dev/tty; }; then
    die "当前没有可交互的终端。改用: PROTOCOLS=reality,hy2 bash $(self_hint) install"
  fi

  while true; do
    # 每轮都要重置: 清理后状态文件已删, 旧的 cur 留着会误判成"协议变更"
    sel=""; cur=""
    echo
    echo -e "${M}============================================================${N}"
    echo -e "${M}   Proxy Node Installer v${SCRIPT_VERSION}   ·   部署向导${N}"
    echo -e "${M}============================================================${N}"
    ui_stamp
    echo
    if [ -f "$STATE_FILE" ]; then
      cur=$(state_get "$STATE_FILE" PROTOCOLS 2>/dev/null)
      echo -e "  ${D}已安装: ${G}${cur:-?}${N}${D}   $(state_get "$STATE_FILE" INSTALLED_AT 2>/dev/null)${N}"
    else
      echo -e "  ${D}当前状态: 尚未安装${N}"
    fi
    echo
    echo -e "  ${D}选择要部署的协议, 输入编号, 可多选(如 ${Y}1 2${D} 表示两个都开):${N}"
    echo
    echo "   1) Reality       VLESS + Vision    抗封锁最强, 不需要证书"
    echo "   2) Hysteria2     UDP 高速          弱网 / 高丢包环境最强"
    echo "   3) SS2022        Shadowsocks-2022  兼容性最好, 老客户端也能用"
    echo "   4) AnyTLS        抗主动探测        新一代 TLS 伪装"
    echo "   5) TUIC v5       低延迟 UDP        基于 QUIC"
    echo
    echo -e "   6) Reality + Hysteria2             ${G}推荐: TCP/UDP 双保险${N}"
    echo "   7) 全协议                          1~5 全部开启"
    echo
    echo -e "  ${D}── VPS 优化 (可单独执行, 不装代理也能用) ──────────────────${N}"
    echo -e "   8) ${G}一键优化 VPS${N}                    BBR + 内核参数 + swap + 时间同步 + 日志限容"
    echo -e "   9) 设置时区                          ${D}按机器所在地区设, 别留默认的 UTC${N}"
    echo
    echo -e "  ${D}── 维护 ────────────────────────────────────────────────────${N}"
    echo -e "   c) ${R}清理所有配置${N}                    端口被占用 / 想彻底重来时用"
    echo "   0) 退出"
    echo

    read_tty "  ${B}请选择${N} [直接回车 = ${G}6 推荐${N}]: " sel "6" || { info "无终端, 已退出"; exit 0; }
    sel="${sel//,/ }"; sel="${sel//，/ }"; sel="${sel//、/ }"

    picked=""; want_clean=0; want_opt=0; want_tz=0; bad=0
    # 用 read -ra 拆数组, 不用裸 $sel: 后者会做路径名展开, 用户手滑输入
    # * / ? 时会被当前目录的文件名替换, 表现为莫名其妙选中协议或刷屏。
    local toks=()
    read -ra toks <<< "$sel"
    for tok in "${toks[@]}"; do
      case "$tok" in
        0) info "已退出"; exit 0 ;;
        8) want_opt=1 ;;
        9) want_tz=1 ;;
        c|C) want_clean=1 ;;
        1) picked="${picked}reality," ;;
        2) picked="${picked}hy2," ;;
        3) picked="${picked}ss2022," ;;
        4) picked="${picked}anytls," ;;
        5) picked="${picked}tuic," ;;
        6) picked="${picked}reality,hy2," ;;
        7) picked="${picked}reality,hy2,ss2022,anytls,tuic," ;;
        *) warn "无效选项: ${tok}"; bad=1 ;;
      esac
    done

    # 维护项(8/9/c)是"只做这一件事"的分支, 与协议选择互斥。以前输入 "1 8"
    # 会静默丢掉协议却毫无提示, 用户以为部署完成了。
    if [ -n "$picked" ] && { [ "$want_opt" = "1" ] || [ "$want_tz" = "1" ] || [ "$want_clean" = "1" ]; }; then
      warn "维护项(8/9/c)不能与协议选择同时使用; 本次只执行维护项, 协议未部署"
    fi

    # 8: 只做 VPS 优化, 不进入安装
    if [ "$want_opt" = "1" ]; then
      echo
      cmd_optimize all
      continue
    fi

    # 9: 只改时区, 不进入安装
    if [ "$want_tz" = "1" ]; then
      cmd_timezone
      continue
    fi

    # c 优先: 清理完回到向导, 让用户接着选协议。
    # 关键: 之前"没东西可清"时只打一行 info 就 continue, 向导立刻重绘把那行
    # 冲掉, 用户看到的就是"按 c 什么都没变"。清理分支必须自己给足反馈并停一下。
    if [ "$want_clean" = "1" ]; then
      echo
      echo -e "${M}── 清除配置 ──────────────────────────────────────────────${N}"
      if [ -f "$STATE_FILE" ] || residue_report >/dev/null 2>&1; then
        warn "将删除: 全部服务 / 配置 / 凭据 / 订阅 / 二进制"
        if ask_yes "确认清除所有代理配置?"; then
          do_clean 0
          CLEAN=0
          ok "已清除, 端口已释放"
          echo -e "${D}接下来选协议即可重新部署。${N}"
        else
          info "已取消清理, 什么都没删"
        fi
      else
        # 向导是"未安装"才进的界面, 本来就没有本脚本的配置可清 —— 这不是错误,
        # 而是正常结果, 要说清楚, 别让用户以为按键失灵。
        ok "当前没有本脚本的配置或残留需要清除"
        echo -e "${D}如果你是想清除别的脚本装的 xray/hysteria, 本命令不会动它们${N}"
        echo -e "${D}(避免误删别人的节点)。要全新安装直接选协议即可, 脚本会自动处理。${N}"
      fi
      echo
      read_tty "按回车返回向导..." _pause "" || true
      continue
    fi

    picked="${picked%,}"
    if [ "$bad" = "1" ] || [ -z "$picked" ]; then
      [ -n "$picked" ] || warn "没有选中任何协议"
      echo
      continue
    fi

    # 已装过且协议组合变了: 必须清干净再装, 否则旧协议继续占端口。
    # 比较用归一化后的顺序: 用户把 `1 2` 敲成 `2 1` 不算换协议, 否则会误清理、
    # 把 users.txt 和全部 UUID 一起删掉。
    picked=$(canon_protocols "$picked")
    if [ -n "$cur" ] && [ "$(canon_protocols "$cur")" != "$picked" ]; then
      echo
      warn "协议变更: ${cur}  ->  ${picked}"
      warn "换协议要先清掉旧实例, 否则旧服务还在跑、端口还占着"
      if ! ask_yes "清理旧实例并按新协议部署?"; then
        info "已取消, 回到选择"
        echo
        continue
      fi
      CLEAN=1
    fi

    PROTOCOLS="$picked"
    echo
    ok "部署协议: ${PROTOCOLS}"
    echo
    # 向导里点"开始部署"也要走自动更新。必须先 export: exec 只继承环境变量,
    # 不继承 shell 变量 —— 不 export 就会变成"选了全协议却按默认组合装"。
    export PROTOCOLS CLEAN
    maybe_self_update install
    # 不能无条件 return 0: 那会把 cmd_install 的失败退出码吞掉
    cmd_install || return 1
    return 0
  done
}

# ---------------- 菜单 ----------------
# 直接部署指定协议组合(菜单里的"一键部署"走这里)
# 已装且组合不同时必须先清理: 否则旧协议的服务还在跑、端口还占着
deploy_preset(){
  local want="$1" curp=""
  want=$(canon_protocols "$want")
  if [ -f "$STATE_FILE" ]; then
    curp=$(state_get "$STATE_FILE" PROTOCOLS 2>/dev/null)
    curp=$(canon_protocols "$curp")
  fi
  if [ -n "$curp" ] && [ "$curp" != "$want" ]; then
    echo
    warn "当前已装协议: ${curp}"
    warn "要换成 ${want}, 必须先清掉旧实例, 否则旧协议继续占端口"
    if ! ask_yes "清理旧实例并按 ${want} 部署?"; then
      info "已取消"
      return 0
    fi
    CLEAN=1
  fi
  _RAW_PROTOCOLS="$want"
  PROTOCOLS="$want"
  # 菜单里点"重新部署"同样先对齐版本。export 的理由见 wizard 里那段注释。
  export PROTOCOLS CLEAN
  maybe_self_update install
  cmd_install
}

menu(){
  while true; do
    echo
    echo -e "${M}============================================${N}"
    echo -e "${M}   Proxy Node 管理菜单${N}   ${D}v${SCRIPT_VERSION}${N}"
    echo -e "${M}============================================${N}"
    ui_stamp
    if load_state 2>/dev/null; then
      local mp="" _dn=""
      proto_on reality && mp="${mp} VLESS/${VLESS_PORT}"
      proto_on hy2     && mp="${mp} HY2/${HY2_PORT}"
      proto_on ss2022  && mp="${mp} SS/${SS2022_PORT}"
      proto_on anytls  && mp="${mp} AnyTLS/${ANYTLS_PORT}"
      proto_on tuic    && mp="${mp} TUIC/${TUIC_PORT}"
      echo -e "  节点 ${G}${NODE_NAME}${N}   IP ${SERVER_IP:-?}  ${D}${mp# }${N}"
      # 菜单是最常看到的界面: 只印一个裸域名, 用户认不出 www.kernel.org 是什么站,
      # 也没法核对 SNI 抄得对不对。dest_note 取不到(自定义域名)就只印域名。
      _dn=$(dest_note "${DEST:-}" 2>/dev/null) || _dn=""
      echo -e "  SNI  ${DEST:-?}${_dn:+  ${D}(${_dn})${N}}"
    else
      echo -e "  ${Y}尚未安装${N}"
    fi
    echo
    echo -e "  ${G}1) 一键部署 Reality + Hysteria2${N}   ${D}(推荐: TCP/UDP 双保险, 直接开装)${N}"
    echo "  2) 部署向导 (选协议 / 换协议 / 重新部署)"
    echo "  3) 查看节点信息与链接"
    echo "  4) 重新生成订阅文件"
    echo "  5) 服务状态"
    echo "  6) 重启服务"
    echo "  7) 实时日志 (xray)"
    echo "  8) 实时日志 (hysteria2)"
    echo "  l) 实时日志 (sing-box: ss2022/anytls/tuic)"
    echo "  9) 线路体检 (出口 IP / PTR / 时间 / 客户端清单)"
    echo "  n) 改节点备注名 (只改客户端显示, 不用重装)"
    echo "  x) 伪装目标站 (当前 SNI / 看全部候选 / 换站)"
    echo "  v) 安全自检 (二进制指纹 / 配置 / 凭据权限)"
    echo "  d) 诊断报告 (用不了时跑这个, 凭据自动脱敏)"
    echo "  a) 设备凭据 (多设备 UUID / 单独吊销)"
    echo "  r) 重置凭据 (换 UUID/密钥, 需重新导入)"
    echo "  b) 备份配置 (迁移到新 VPS 用)"
    echo "  t) 一键优化 VPS (BBR / 内核参数 / swap / 时间同步)"
    echo "  z) 设置时区 (按机器所在地区设)"
    echo -e "  y) 更新脚本 ${D}(当前 v${SCRIPT_VERSION}; 一直敲 proxy 会一直跑旧代码)${N}"
    echo "  f) 清理并全新安装 (换新凭据, 端口冲突时用)"
    echo "  c) 清除所有配置 (端口被占用时用这个)"
    echo "  u) 卸载 (等同清除; proxy 命令保留)"
    echo "  0) 退出"
    echo
    local c=""
    read_tty "${B}请选择: ${N}" c "0"
    case "$c" in
      1) deploy_preset "reality,hy2" ;;
      2) wizard ;;
      3) cmd_info ;;
      4) cmd_sub ;;
      5) cmd_status ;;
      6) cmd_restart ;;
      7) cmd_logs xray ;;
      8) cmd_logs hy2 ;;
      l|L) cmd_logs sb ;;
      9) cmd_audit ;;
      n|N) cmd_name ;;
      x|X) cmd_dest ;;
      v|V) cmd_verify ;;
      d|D) cmd_diag ;;
      a|A) cmd_user list ;;
      r|R) cmd_reset ;;
      b|B) cmd_backup ;;
      t|T) cmd_optimize all ;;
      z|Z) cmd_timezone ;;
      y|Y) cmd_update ;;
      # 和 wizard / deploy_preset 一样, 部署前先对齐版本。export 是因为
      # maybe_self_update 在有新版时会 exec 换进程, 不导出去 CLEAN 就丢了。
      f|F) CLEAN=1; export CLEAN; maybe_self_update install; cmd_install ;;
      c|C) cmd_clean ;;
      u|U) cmd_clean ;;
      0|q|Q) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

usage(){
  cat <<USAGE
Proxy Node Installer v${SCRIPT_VERSION} (${BUILD_DATE})

用法:
  bash setup-proxy.sh [命令]

命令:
  (无参数)         弹出部署向导(选协议/优化/清理); 已安装则打开管理菜单
  wizard           直接打开部署向导
  install          安装/重新部署(幂等, 保留凭据)
  install --clean  清理旧实例后全新安装(换新凭据, 端口冲突时用)
  fresh            等同 install --clean
  optimize [项]    一键优化 VPS: all(默认) / bbr / swap / time / log
  timezone [时区]  设置时区: 无参数=菜单, auto=按出口IP自动, 或直接给 Asia/Tokyo
  info             查看节点信息、链接、二维码
  dest [list]      查看当前伪装目标站是什么网站; list 列出池子里全部候选
                   不带参数=看当前站+候选池并可当场换站
                   dest set <域名|random> 直接换站(重签证书/重写订阅, 客户端要重导)
  sub              重新生成订阅文件
  rule [子命令]    国内直连名单: list(默认) / check / add <域名> / rm <域名> / update
                   add/rm 改 /etc/proxy-node/user-direct.txt; update 从官方源更新
                   远程规则(官方优先+镜像交叉核对, 失败不动现有名单)
  name [名字]      改节点备注名(只影响客户端显示, 不改服务端配置)
  status           服务状态与监听端口
  verify [--fix]   安全自检: 二进制指纹 / 配置合法性 / 凭据与订阅目录权限 / 订阅 DNS
  restart          重启已启用协议对应的服务
  logs [单元]      实时日志: xray(默认) / hy2 / sb
  audit [--dnsbl]  线路体检(出口 IP / PTR / 时间 / 客户端清单)
  dnstest [--client]  DNS 泄露自检: 三端订阅 DNS 配置 / DoH 端点实测 / 出口同源
                   --client 只打印客户端侧自检清单(手机可看, 不带颜色)
                   客户端侧(浏览器实际用了哪个 DNS)服务端测不到, 末尾给自查清单
  selftest         逐协议真连一次(用订阅同一份配置), 装完发现不通看这里
  speed            速度体检: BBR / 拥塞控制 / 默认节点 / 该开哪项(只读)
  diag [文件]      生成脱敏诊断报告(系统/服务/端口/网络/时间/日志), 用不了时贴这个
  egress [地址]    上游出口代理(住宅 IP): 不带参数=查看, off=关闭
                   例: proxy egress socks5://用户:密码@1.2.3.4:1080
  user [子命令]    多设备凭据: list(默认) / add <名字> / link <名字> / rm <名字>
  reset            重置凭据(会作废现有客户端)
  backup [文件]    打包状态/凭据/证书, 用于迁移
  restore <文件>   从备份恢复(换 VPS 时用, 会自动重新探测 IP)
  clean [--all]    清除所有配置与服务(端口被占用时用这个)
  uninstall        等同 clean
  update [命令]    更新脚本自身: 无参数=只更新, update install=更新后立刻重新部署
  upgrade [版本]   升级 Xray 内核; 无参数=最新版; --rollback 回滚上一版
  version          显示脚本版本

首次安装可用的环境变量:
  PROTOCOLS=reality,hy2           协议组合, 逗号分隔
                                  可选: reality hy2 ss2022 anytls tuic
  VLESS_PORT=443  HY2_PORT=443    主协议端口
  SS2022_PORT=8445  ANYTLS_PORT=8444  TUIC_PORT=8443
                                  扩展协议端口(sing-box 承载)
  REALITY_DEST=www.bing.com      指定伪装站(留空=自动挑选)
  REALITY_DEST=random            重新随机挑一个(已装好的机器换 SNI 用这个)
  ENABLE_OBFS=1                  开启 hy2 salamander 混淆
  HY2_HOP=20000-30000            hy2 UDP 端口跳跃
  HY2_INSECURE=1                 关闭证书固定, 退回 insecure(不推荐)
  HY2_BW_UP=50 HY2_BW_DOWN=300   Hysteria2 Brutal 带宽(Mbps); 留空=默认 BBR
                                  只写进客户端订阅, 填错比不填更慢, 见 README
  DEFAULT_NODE=hy2               客户端默认节点改走 HY2(UDP 提速); 默认 reality(TCP)
                                   切回: DEFAULT_NODE=reality proxy sub
  SUB_PORT=38080                 订阅 HTTP 端口(留空=随机 30000-39999)
  NODE_NAME=xxx                  节点备注名
  SUB_HTTP=1                     起订阅 HTTP 服务
  SUB_BIND=0.0.0.0               订阅服务监听地址(默认 127.0.0.1)
  EGRESS_URL=socks5://u:p@h:1080 上游出口代理(住宅 IP), 安装时一并生效
                                  等同装完再执行 proxy egress; 需要 reality 或
                                  sing-box 承载, 纯 hy2 组合不支持(会明确告知)
  XRAY_VERSION=26.3.27            固定 Xray 版本(留空=追官方最新版, 用官方 .dgst 校验)
  HY2_VERSION=2.13.0             固定 hysteria 版本(留空=追官方最新 2.x, 用官方 hashes.txt 校验)
  SB_VERSION=1.14.4              固定 sing-box 版本(留空=追官方最新, 用 release digest 校验)
  ALLOW_UNVERIFIED_BIN=1         跳过二进制完整性校验(不推荐, 仅自定义版本时用)
  CLEAN=1                        安装前先彻底清理旧实例
  ASSUME_YES=1                   全程不询问
  PN_NO_SELFUPDATE=1             部署前不做自动更新(断网环境 / 要复现旧版行为时用)

关于自动更新:
  install / fresh / 无参数向导 在动手之前会查一次远端版本, 发现更新就下载、校验、
  原子替换自己, 然后 exec 新版继续部署。下载失败或校验不过会退回当前版本继续,
  不会卡住部署。装完还会清掉 /root /tmp /usr/local/bin 下残留的旧脚本副本。

示例:
  bash setup-proxy.sh
  bash setup-proxy.sh install --clean         端口被占用时一条命令重来
  PROTOCOLS=reality,hy2,ss2022 bash setup-proxy.sh install
                                              加装 Shadowsocks-2022
  PROTOCOLS=reality,hy2,anytls,tuic bash setup-proxy.sh install
  bash setup-proxy.sh clean --all             连管理命令一起删干净
  VLESS_PORT=8443 HY2_PORT=8443 bash setup-proxy.sh install
  ENABLE_OBFS=1 HY2_HOP=20000-30000 bash setup-proxy.sh install
USAGE
}

# ---------------- 入口 ----------------
main(){
  # 部署类入口先把自己对齐到最新版, 再进真正的流程。
  #
  # 必须放在 case 之前, 不能塞进 cmd_install: 向导和菜单是先在 shell 变量里
  # 攒选择(PROTOCOLS / CLEAN / 各端口), 攒完才调 cmd_install。在那里 exec 换
  # 进程, 这些变量不会跟过去 —— 用户明明选了全协议, 更新完却按默认组合装。
  case "${1:-}" in
    install|fresh|wizard|setup)
      maybe_self_update "$@" ;;
    "")
      # 已装过的机器会进菜单, 那种不该为了查版本卡在网络上;
      # 未装过的一定会进向导, 这里提前更新, 免得向导填完才发现跑的是旧版。
      [ -f "$STATE_FILE" ] || maybe_self_update ;;
  esac

  # 只有会改系统状态的命令才需要互斥。查询类(info / dest / status / audit)不加锁:
  # 它们不该因为别人在装而失败。
  # sub / name / user / egress 看着只是"改个字段", 实际是 load_state -> 全量
  # save_state: 把读进来的旧凭据连同新字段一起写回去。与 install / update
  # 并发时会把刚生成的新 UUID / SUB_TOKEN 覆盖成旧值, 磁盘配置是新凭据、
  # state 是旧凭据 —— 客户端全部握手失败。必须一起进锁。
  case "${1:-}" in
    install|fresh|upgrade|reset|clean|uninstall|purge|update|selfupdate|restore|optimize|opt|\
    sub|name|user|egress)
      acquire_lock ;;
  esac

  case "${1:-}" in
    install)
      shift || true
      local a
      for a in "$@"; do
        case "$a" in --clean|--fresh|-c) CLEAN=1 ;; esac
      done
      cmd_install
      ;;
    fresh)          CLEAN=1; cmd_install ;;
    info)           cmd_info ;;
    dest)           cmd_dest "${2:-}" "${3:-}" ;;
    name|rename)    cmd_name "${2:-}" ;;
    sub)            cmd_sub ;;
    rule)           shift; cmd_rule "$@" ;;
    status)         cmd_status ;;
    verify|check)   cmd_verify "${2:-}" ;;
    restart)        cmd_restart ;;
    logs)           cmd_logs "${2:-xray}" ;;
    audit)          cmd_audit "${2:-}" ;;
    dnstest|dns)    shift || true; cmd_dnstest "$@" ;;
    egress)         cmd_egress "${2:-}" ;;
    selftest|test)  cmd_selftest ;;
    speed|perf)     cmd_speed ;;
    diag|diagnose)  cmd_diag "${2:-}" ;;
    user)           cmd_user "${2:-list}" "${3:-}" ;;
    reset)          cmd_reset ;;
    backup)         cmd_backup "${2:-}" ;;
    restore)        cmd_restore "${2:-}" ;;
    clean|uninstall|purge) shift; cmd_clean "$@" ;;
    optimize|opt)   cmd_optimize "${2:-all}" ;;
    timezone|tz)    cmd_timezone "${2:-}" ;;
    wizard|setup)   wizard ;;
    upgrade)        cmd_upgrade "${2:-}" ;;
    update|selfupdate) shift; cmd_update "$@" ;;
    # 内部命令, 不进 usage: 由 cmd_update 用新脚本进程调用, 重写内嵌产物。
    # 不能在本进程里调那些函数 —— 内存里还是旧版代码。
    __refresh_units)
      # 内部命令由 cmd_update 以 root 子进程调用。这里不调 acquire_lock:
      # 父进程已经持锁, 子进程重新 exec 9>> 会关掉继承来的 fd9 再抢同一把锁,
      # 结果自己把自己判成"有别的进程在装"。但用户直接敲这个隐藏命令时
      # 至少要挡住非 root —— 否则会以普通用户身份重写 systemd 单元。
      need_root
      load_state >/dev/null 2>&1 || { echo "state.env 不可读, 无法刷新单元" >&2; exit 1; }
      FORCE_UNIT_REFRESH=1
      install_healthcheck
      [ "${SUB_HTTP:-0}" = "1" ] && maybe_sub_http
      proto_on reality && ensure_xray_service
      proto_on hy2 && ensure_hy2_service
      sb_enabled && ensure_singbox_service
      systemctl daemon-reload >/dev/null 2>&1 || true
      # 单元改了就要重启对应进程, 否则运行中的服务仍按旧 unit 的参数跑,
      # 直到机器重启或用户手动 proxy restart —— 刷新等于没刷。
      proto_on reality && systemctl restart xray >/dev/null 2>&1 || true
      ;;
    version|-V|--version)
      # 对外只报版本号 + 构建日期; 版本严格递增。
      echo "proxy-node v${SCRIPT_VERSION} (${BUILD_DATE})"
      local _vp=""
      _vp=$(running_script_path 2>/dev/null || true)
      # 标签必须是 sha256: 这里取的是 file_sha256(sha256sum), 以前写 "md5 :",
      # 用户拿 `md5sum setup-proxy.sh` 去对比永远对不上, 白白怀疑脚本被换过。
      # 另外不能写成 `[ -n "$_vp" ] && echo ...`: 管道运行(curl | bash -s version)
      # 时 _vp 为空, 整条 && 返回 1, 于是 main 的退出码变成 1 —— 明明打出了版本,
      # 调用方却判成失败。用 if 兜住, 保证 version 永远 exit 0。
      if [ -n "$_vp" ]; then
        echo "脚本  : ${_vp}"
        echo "sha256: $(file_sha256 "$_vp" 2>/dev/null | cut -c1-12)"
      else
        echo "脚本  : <管道运行, 未落盘>"
      fi
      ;;
    help|-h|--help) usage ;;
    "")
      if load_state 2>/dev/null; then
        menu
      elif [ "$_RAW_PROTOCOLS" != "__unset__" ]; then
        # 显式指定了 PROTOCOLS -> 自动化场景, 直接按指定协议装
        cmd_install
      elif { : 2>/dev/null >/dev/tty; }; then
        # 有终端: 出部署向导, 先选协议再装
        wizard
      else
        # 无终端(CI/管道调用): 用默认协议装, 不阻塞
        cmd_install
      fi
      ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
