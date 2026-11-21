# 变更记录

旧版本历史记录(当前对外版本 v1.0,以单一 commit 发布)。

```text
# 修订 7: 自更新改为"官方源优先、镜像仅兜底", 修掉镜像缓存滞后导致的误拒更新。
# 修订 8: 纠正以"26.9.8 强制 MLKEM"为依据的错误说法(该 tag 从未存在; MLKEM 是自动
#   协商+回退); 修 print_links 打印失效 UUID、Brutal 非法值误报、restore 缺 DEST 崩溃、
#   user add 短名撞 UUID 前缀、verify 全局残留; 测试 harness 加"零断言"假绿闸门。
# 修订 9: REALITY 抗封增强 —— 指纹 REALITY_FP 可配置(默认仍 chrome)、伪装站池扩到
#   20 个含冷门技术站、pick_dest/simple 共用一份池子; client-guide/README 补
#   "Reality 单独连不上 HY2 能用"的分步排障。默认端口仍 443(官方示例+过防火墙需要)。
# 修订 10: Xray 默认追官方最新版(不再锁 26.3.27), 用官方 release 的 .dgst 动态取
#   SHA-256 校验, 解开"新版本没内置哈希就被校验闸门拒装"的死结; API 不通沿用本机
#   版本不降级。纠正"v2rayN 不识别 pinSHA256"过时说法(新版已支持), 带 pin 主链接
#   直接给新版用、另留 -oldv2rayN 兜底; 订阅提示说清纯节点列表不带 DNS 是格式限制。
# 修订 11: 修"返回值被日志污染" —— xray_expected_sha / effective_default_node 的
#   stdout 就是返回值, 但内部用 ok/warn 往 stdout 打了提示, 提示文字会拼进哈希串和
#   节点名。后果: 官方 GitHub 被墙、只有镜像能用时(国内 VPS 最常见)Xray 必然"校验
#   未通过"装不上; DEFAULT_NODE 填错时 clash.yaml 默认节点被静默改掉。提示改走 stderr。
#   另修 proxy version 的 md5 标签(实际是 sha256)与管道运行时的退出码(恒为 1)。
# 修订 12: Hysteria2 也改成默认追官方最新版(限 2.x), 用官方 hashes.txt 动态取
#   SHA-256 校验, 与 Xray 同一套闸门(官方优先 / 双镜像交叉 / 内置兜底 / 冲突拒绝)。
#   解开"官方一发新版、脚本没内置哈希就装不上"的同一个死结; 跨 3.x 不自动跟,
#   避免配置格式变更把在跑的节点弄挂。sing-box 仍锁版本 —— 官方不发校验文件,
#   且 1.x 小版本会删改配置字段, 追最新等于拿用户节点冒险。
# 修订 13: 全项目逐行审查 —— 共修 11 处真实缺陷。最严重的是测试假绿:
#   xray_hash_behavior.sh 的 mock 把官方 URL 写成 github.com/* (实际是
#   https://github.com/...), 镜像兜底分支从未执行, 三条断言全是假绿, 修订 11
#   的返回值污染在 Xray 侧完全没被测到。已改精确前缀并加"分支确实执行"断言,
#   还做了变异测试(注入 bug 必须报红)。其余: dest_rank 的 warn 污染 stdout 让
#   pick_dest_simple 选站退化; restore 覆盖证书后失败回滚不还原证书(旧 PIN 配
#   新证书 -> 客户端握手全挂); upgrade --rollback 不检查 cp 返回值造成"假回滚";
#   verify --fix 把文件缺失/不可读也清零成"自检通过"; REALITY_FP 在订阅/info
#   里硬编码 chrome 使换指纹排障无效; clean 漏删含私钥的 .before-reset.svc;
#   另修 3 处同类 pipefail/head 残留。
# 修订 14: 新增 shadowrocket.conf(iOS 小火箭开箱即用配置), 修 DNS 泄露。
#   小火箭以前只能拿 base64.txt 纯节点(不带 DNS), 图形界面"DNS 覆写"留空就用
#   国内运营商 DNS, 泄露检测一查一个准。新配置两条腿: FINAL,PROXY,force-remote-dns
#   让境外域名不在本地解析(主力, 不依赖节点名) + dns-server 走境外 DoH 经隧道
#   (#proxy=节点名由脚本自动生成并 URI 编码, 不用手抄)。另修正旧文档里
#   hijack-dns = true 的错误写法(官方值是 :53 这类地址:端口, 布尔值不生效)。
# 修订 15: 吸收 Shadowrocket 官方懒人配置(lazy.conf 2026-10-15)两项防泄漏:
#   stun-response-ip/v6 让 TUN 里的 STUN 查询返回假 IP(堵 WebRTC 栏泄漏真实 IP);
#   udp-policy-not-supported-behaviour=REJECT 让 UDP 命中不支持转发的策略时拒绝
#   而非直连。两项都在官方配置里有明确注释, 且本脚本节点都支持 UDP 不会误伤。
#   同时明确"不能学"的部分: 官方 dns-server 用国内 DoH、fallback=system、
#   always-ip-address=true 全是给普通用户保可用性/防污染的, 与本项目"DNS 所在地
#   要和出口 IP 一致"的目标相反(回系统 DNS 就泄露), 坚决不用。
# 修订 16: 修小火箭配置国内域名分流缺陷。GEOIP,CN,DIRECT,no-resolve 里的
#   no-resolve 按官方 README 会让"域名请求"跳过 IP 类规则, 国内域名因此漏到
#   FINAL,PROXY,force-remote-dns, 表现为国内网站绕代理。补一组内置
#   DOMAIN-SUFFIX 国内域名直连规则(官方文档明确支持, 放 FINAL 之前), 不依赖
#   外部 RULE-SET(国内拉不到 raw.githubusercontent.com), 也不用未文档化的
#   GEOSITE。校验器加"国内规则必须在 FINAL 之前"的顺序检查, 防规则被写废。
# 修订 17: 三端 writer 结构对齐 + 上游出口(egress)链路加固。
#   (1) clash.yaml 从 gen_sub_files 里抽成独立 write_clash_yaml(), 与小火箭、
#   sing-box 对称。以前靠外层局部变量传 Brutal 带宽和默认节点, 单独调用跑不
#   起来, 于是三端里只有它没有行为测试; 现在有 test/clash_yaml_behavior.sh
#   (41 条断言, 覆盖 fake-ip/DNS 分流/STUN/各协议字段/缩进不变量)。
#   (2) egress: 设完出口后走真实 REALITY 隧道复测实际出口 IP, 与上游比对 ——
#   原来只直连上游代理测一次, 代理通不等于流量真的走了它(egress 没在
#   outbounds 首位 / routing 绕过 / 旧进程还在跑 都看不出来)。
#   (3) egress: 出口探测补第二个端点。部分住宅代理按域名黑名单拦掉
#   api.ipify.org, 只测一个端点会把"代理是好的"误判成"不可用"。
#   (4) egress: 端口做 1..65535 校验(99999 会让服务直接起不来), 前导 0 也拒。
#   (5) egress: 服务就绪从固定 sleep 1 改成轮询(wait_active), 慢机器不再误判
#   失败并回滚一个本来能用的配置。
#   (6) egress: 明确告知 Hysteria2 由独立进程承载、不吃 outbounds, 两个协议都
#   开时它的流量仍从本机 IP 直出 —— 以前只字未提, 用户以为两条线都换了出口。
#   (7) egress: 修"关闭出口关不掉"。守卫原来无条件拦"只开 hy2", 于是先开
#   reality 配过出口、后来改成只开 hy2 的机器执行 proxy egress off 会被判成
#   关闭失败并回滚。改为只在"要启用出口"时拦。
#   (8) audit 把"上游出口可用"改成"上游代理可达", 并注明真实出口看隧道实测,
#   不再让"代理能连上"冒充"出口已生效"。
#   (9) 修 CI 一直红。步骤里写了 `out=$(bash setup.sh version | head -1)`,
#   而 run: 默认 bash -e -o pipefail: head 读够一行就关管道, 还在写 stdout 的
#   setup.sh 收到 SIGPIPE(exit 141), 整条管道判失败、-e 直接中止。CI 从建库起
#   就卡在第二个步骤, 后面的回归套件从来没跑过 —— 闸门坏了比没有闸门更糟。
#   改成先全量取回再用参数展开截首行; 另把 6 处 `sed ... | head -1` 的管道去掉
#   (这些字段在各自文件里只出现一次, 不需要截断, 留着同样是 SIGPIPE 隐患)。
#   回归套件新增第 11 节"CI 工作流自检", 直接禁止 CI 里再出现 head 管道。
# 修订 18: 新增 `proxy dnstest` —— 客户端 DNS 泄露里服务端能验证的那部分。
#   先把边界说清: 浏览器最终用了哪个 DNS 是客户端本机的事, 服务端看不见, 所以
#   不假装"测到了客户端", 只做三件真能验的:
#   (1) 三端订阅产物的 DNS 配置是否齐全。读的是**真实生成的文件**, 不是查源码
#   里有没有那个字符串。clash 的 nameserver 逐条检查 —— 只查"存在 #PROXY"会漏
#   掉"两条里丢了一条", 剩下那条照样本地解析, 检查却报通过。
#   (2) 订阅里配的 DoH 端点经隧道能否真解析。判据必须 Status:0 且有 Answer,
#   只判"有响应"会把 403/限流页当成功(本项目以前就拿限流页当过出口 IP)。
#   隧道起不来时明确标"未验证"而不是"失败": 在国内 VPS 上直连测境外 DoH 必然
#   失败, 那是噪音不是信号, 报红只会让人以为配置坏了。
#   (3) 经隧道取出口 IP 与直连对比, 确认解析与出口同源。
#   顺带把临时隧道从 egress_ip_via_proxy 里抽成 tunnel_start/tunnel_stop, 出口
#   实测与 DNS 实测共用同一份, 不再复制第二份; 配置 JSON 拆成 tunnel_config_json
#   (里面有裸 "}", 留在生命周期函数里会让按行抽函数的测试工具提前截断)。
#   新增 test/dnstest_behavior.sh(26 条): 用真 writer 生成三端产物再审计,
#   变异 4 组全部被抓(含"两条 nameserver 只丢一条"这种半截回归)。
# 修订 19: `proxy dnstest --client` —— 把客户端侧那半截也交到用户手上。
#   服务端能验的只有"配置齐全、端点可用", 最后跑 dnsleaktest 的那一步永远在客户端。
#   以前这段说明散在 client-guide 和 dnstest 结尾, 用户得在手机上一边翻文档一边点。
#   现在一条命令输出一份纯文本清单: 三端各自的订阅地址(带 token)、该导入哪个文件、
#   每端要开的开关、三个检测站、判定标准、失败对照表。
#   三个细节是有意的: (1) 不带颜色 —— 内容会从终端复制到手机, ANSI 转义会跟着
#   粘过去变成乱码; (2) 订阅地址跟随 SUB_BIND —— 监听在 127.0.0.1 时给公网 IP 的
#   链接, 手机点开必然连不上, 用户会以为服务坏了; (3) 明确写"别用 base64.txt /
#   v2rayn.txt 纯链接" —— 纯节点列表不带任何 DNS 配置, 导入后等于用运营商 DNS,
#   这正是最常见的"我明明配了还是泄露"的原因。
#   分发处同时修掉一个静默失效: 原来 `dnstest|dns) cmd_dnstest ;;` 不传参, 加了
#   --client 也会被吞掉 —— 用户敲了跟没敲一样, 还不报错。
# 修订 20: 全项目逐行审查(安全 + 正确性) —— 最严重的一处让默认组合根本装不完。
#   (1) CERT_HEX 全脚本从未赋值。compute_cert_pins 只算了 SPKI 一项, 却把
#   CERT_HEX 写进成功条件 —— 于是该函数恒返回失败, ensure_hy2 每次都 die 在
#   "证书指纹计算失败", 默认组合 reality,hy2 走不到最后。这是随 v1.0 重写误删的:
#   旧注释写"DER 那份从来没被读过……去掉"时, 把赋值和读取一起删了, 但
#   HY2_PIN="${CERT_HEX:-}" 仍在读。两个指纹算法不同不能混用: 整证书 DER 的
#   SHA-256(hex)给 hysteria2 的 pinSHA256 / mihomo 的 fingerprint; 公钥 SPKI 的
#   SHA-256(base64)给 sing-box 的 certificate_public_key_sha256。
#   (2) 订阅服务的 token 比较对非 ASCII 的 str 抛 TypeError: hmac.compare_digest
#   只吃 bytes。请求路径里塞一个 %C3%A9 就能把一次 404 变成未捕获异常。
#   (3) write_singbox_config 缺 ensure_users_file: 少了它 sb_users_json 退回
#   TUIC_UUID/ANYTLS_PASS 那套老字段, 而 gen_links 用 users.txt 首行 —— 两边算出
#   的凭据不同, 客户端必然连不上, 报错还指向"密码错误"这种误导方向。
#   (4) effective_default_node 没启用 REALITY 时照报 reality, 但那个出站根本不在
#   订阅里; 三份 writer 各自兜底换了协议, 只有 `proxy sub` 的输出还印 reality。
#   (5) STUN_SB_PORTS 是手写常量, 等于把 STUN_WEBRTC_PORTS 抄了第二遍 —— 上面加
#   端口、这里忘了改, sing-box 就少拦一个, WebRTC 照样漏真实 IP。改成现算, 且
#   产物与改造前逐字节一致(分隔符必须 ", " 而不是 ",")。
#   (6) parse_egress 返回 '|' 分隔的五段记录, 用户名/密码带竖线会把字段拆错位;
#   valid_ipv4 / valid_bind 放行前导零(010 有的实现按八进制=8, 有的拒收)。
#   (7) 补齐 5 处漏声明的 local(全局污染)、save_state 把 INSTALLED_AT 落到变量、
#   4 处 die 前清理临时目录、删掉两个从未被调用的死函数。
#   新增两条系统性闸门, 都用旧版本验证过确实能抓到对应缺陷:
#   "凭据键都有真实赋值来源"(KEY="" 清空不算赋值) 与 "没有从未被调用的死函数"
#   (定义行自身会匹配到自己的名字, 计数要扣掉一次, 否则断言永远为真)。
# 修订 21: 全项目逐行审查(健壮性) —— 固定等待是一类系统性缺陷, 不是个别笔误。
#   `sleep 2` 之后立刻 systemctl is-active, 在慢机器上服务还没绑定端口就被判
#   "启动失败"。15 处的代价各不相同, 每一处都不是"多等两秒"这么简单:
#   安装主路径整台机器装到一半 die(配置完全正常); 升级路径把能用的新版本判成
#   失败并回滚一次本来成功的升级; hy2 的三级降级链每误判一级就真降一级配置,
#   白丢 IPv4-only 出站与 sniff 两层防护 —— 一次计时竞态换一次安全降级;
#   sing-box 白白把 "::" 换成 0.0.0.0, 双栈机器丢掉 IPv6。
#   全部换成已有的 wait_active(轮询最多 6 秒, 成功即返回): 正常情况 0.3 秒就
#   返回, 比原来的 2 秒更快; 慢机器则一直等到真的起来。剩下三处不是 systemd
#   服务的(selftest 里临时起的 sing-box 客户端)改成等 SOCKS 端口可连接 ——
#   端口没起来时 curl 立刻拿到 000, 结论却印成"不通", 把"还没起来"误报成
#   "协议坏了", 方向完全相反。
#   新增闸门: 扫全文, 任何 `sleep N` 之后两行内出现 is-active 即判回归。用改造
#   前的版本验证过, 准确命中 15 处。
#   订阅服务加 timeout = 30: BaseHTTPRequestHandler 的 timeout 默认是 None, 而
#   服务用的是 ThreadingHTTPServer(一个连接一个线程)。只连不发字节的客户端会
#   让线程永远挂在 readline 上, 几百个就能吃光这个公网进程的内存。行为测试用
#   1 秒子类实测半开连接真的在 1.0s 内被关闭 —— 只断言"属性被设了"证明不了
#   标准库会照它关连接。
#   删掉 SB_HEX: 算了、写进 state.env、列进 CRED_KEYS, 全脚本却没有任何一处读。
#   sing-box 的 TLS 出站只有 certificate_public_key_sha256 一个固定字段, 吃的是
#   SPKI base64(SB_PIN)。新增闸门: STATE_KEYS / save_state 写入 / 实际读取三方
#   闭合, 用旧版本验证过能准确报出 SB_HEX。
#   一键安装命令三处(脚本 ONELINER / README / docs)补 --connect-timeout 10
#   --max-time 120: 这是用户在新机器上敲的第一条命令, 目标被阻断时无超时的 curl
#   会长时间停在"连接中"不给任何输出, 用户只看到光标闪烁。三处一起守, 防止下次
#   只改一处。
```
