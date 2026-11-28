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
# 修订 22: 全项目逐行审查(收尾) —— 三处"看起来回滚了/看起来在探测"的假动作。
#   (1) users.txt 读写不对称。读取侧(build_clients_json / sb_users_json /
#   user list / diag)早就用 `read -r u n _ || [ -n "$u" ]` 兜住了"末行无换行",
#   写入侧却没有: `proxy user add` 直接 printf >> 追加, 会粘在最后一行后面,
#   两台设备的凭据合成一行 —— 老设备失效, 新设备显示成一段乱码, 两边都不报错。
#   触发条件是手改过 users.txt 或从备份包恢复来的文件(那份不保证带换行)。
#   (2) reset 回滚漏还原证书。重置会清空 DEST 再重新挑伪装站, CN 一变就重签
#   证书; 而回滚只还原了 state.env 与服务配置。结果磁盘上是新证书、回滚回来的
#   state.env 里是旧指纹, 客户端固定的正是旧指纹 —— 握手全挂, 提示却说"已自动
#   回滚"。这与修订 13 修的 restore 是同一个形态(那边已有 _RESTORE_CERT_BACKUP)。
#   (3) 健康检查起临时 xray 走真实隧道探活, 原来是 sleep 3 后立刻 curl。慢机器上
#   xray 还没监听, curl 拿到 000, 连吃两次就判"隧道连续不可用"并重启一次用户的
#   连接 —— 探测手段自己没准备好, 却去重启被探测的服务。用户看到的是每半小时
#   掉一次线, 日志里写着"隧道探测失败(HTTP 000)"。改成等端口可连接。
#   另: cmd_verify 里 `read -r a a2` 的 a2 没声明 local, 会泄漏成全局。
# 修订 23: diag 脱敏补齐证书指纹。诊断报告是要外发的, 而脱敏清单只登记了
#   UUID / 各协议密码 / SUB_TOKEN / EGRESS_URL, 漏了 CERT_HEX / CERT_SPKI_B64 /
#   SB_PIN / HY2_PIN 四个指纹。指纹不是私钥, 但它们是"客户端拿来固定服务端身份"
#   的值 —— 连同 UUID 一起外发, 等于把整套连接凭据补齐了。
#   新增闸门: 按 CRED_KEYS 这个数据源自动比对, 每个凭据键都必须出现一条
#   `diag_sec "${KEY:-}"`, 外加 UUID / PRIV / PUB / SID / EGRESS_URL 这几个不在
#   CRED_KEYS 里但同样敏感的键。以后往 CRED_KEYS 加字段而忘了登记脱敏会当场报红
#   (变异测试验证过: 撤掉四个指纹登记, 闸门准确报出这四个名字)。
# 修订 24: 把静态检查从"参考项"变成硬闸门 —— 这一条修的是"为什么每次都能翻出
#   旧问题"这个结构性问题, 不是某个具体 bug。
#   前几轮的审查方式都是"按维度扫模式"(这一轮扫注入, 下一轮扫固定等待), 扫到
#   什么算什么: 落在当前维度之外的代码根本没被看过。而项目里没有任何自动化的
#   静态闸门在持续兜底 —— CI 里的 shellcheck 是 `continue-on-error: true`, 注释
#   写着"参考项, 不计入闸门"。于是每一类缺陷都只能靠人想起来去扫才会暴露, 修完
#   也只是多了一条针对那个实例的断言, 不构成对"这一类"的防线。下一轮换个维度,
#   又是一批"新"的旧问题。
#   做法: 装 shellcheck 0.10.0, 把 -S warning 下的 19 条清零, 然后钉死版本、
#   去掉 continue-on-error, 让一条 warning 就等于回归失败。
#   清零过程中修掉的真实隐患:
#   (1) ver_gt 里 `local -a A=() B=()` —— B 是文件顶部的青色常量(\033[0;36m),
#   在这个函数内被遮成数组。现在没炸只是因为那个函数恰好不打印颜色, 一旦有人
#   复制这段代码过去就会印出空串。改成 va/vb。这类"变量名与全局常量重名"正是
#   复制代码就变真 bug 的形态, 和之前修的 grp(数组/字符串两用) 是同一类。
#   (2) valid_domain 的 `*-|*.-|*-.`: *.- 已被 *- 覆盖、*-. 已被 *. 覆盖, 两条
#   永远匹配不到。不是误报 —— 留着只会让人以为多拦了一种情况。
#   (3) 时区校验的 `*.*|*..*`: 含两个点必然含一个点, 后者永远匹配不到。
#   (4) pick_dest 的 `for line in ${grp[@]:3}` 少了引号(SC2068 error), 元素含空格
#   时会被拆开; 顺带把 cands+=($REALITY_DESTS) 的 word splitting 意图写清楚。
#   (5) 两处 shellcheck 指令自己写错了: `# shellcheck disable=SC2086  (说明文字)`
#   会把括号里那段当成下一个 key=value, 报 SC1125 并**整条忽略** —— 等于没屏蔽。
#   以 `# shellcheck` 开头的普通注释同样会被当指令解析(SC1073/SC1072)。
#   新增三条闸门(都用改造前的版本验证过确实报红):
#     a) 静态检查指令语法: 扫 setup.sh 与 test/run.sh, 任何不是
#        `# shellcheck disable=SCxxxx` / `shell=` / `source=` 的形态都判失败。
#        这条闸门写完当场抓到了我自己在同一轮里又踩的两次。
#     b) 数组变量不许与颜色常量重名: 从 local -a / X=() / read -ra 三种声明里
#        抽名字, 与 R/G/Y/B/M/D/N 比对。扫的是去掉注释后的代码 —— 第一版扫全文,
#        结果"别写 local -a B=()"这句说明自己把闸门打红了。
#     c) shellcheck 零告警: 本地没装则 SKIP(CI 里 SKIP = 失败), CI 装了钉死版本
#        就必须 0 条。
#   CI 侧: 用 GitHub release 的 v0.10.0 二进制而不是 apt 的 shellcheck ——
#   runner 镜像换一版就换一套规则, 同一份代码今天绿明天红; 装完还断言
#   `shellcheck --version` 与钉死的版本一致, 漂移了直接失败。
# 修订 25: 健康检查的探针进程会泄漏。healthcheck 由 systemd 定时器拉起, 每次起
#   一个临时 xray(127.0.0.1:10896) 走真实隧道探活, 用完 kill 掉。但只有"正常走完"
#   这条路会 kill —— 被 systemd 超时杀掉、或脚本中途 exit 时, 临时 xray 会一直留着
#   并占着 10896。后果是下一轮: 端口等待循环立刻通过(连上的是残留进程), curl 走的
#   也是那个残留进程, 而 `kill "$hp"` 只杀新起的那个 —— 残留的永远留着, 越积越多,
#   而且探活结论来自一个"不知道配置还是不是当前配置"的旧进程。
#   修法: 起新探针前按配置路径精确清一次(`pkill -f '^/usr/local/bin/xray -c
#   /run/_hc.json'`), 只匹配探针自己的配置文件, 不会碰正式服务(/etc/xray/config.json)。
#   这样无论上一轮怎么死的, 任何时刻最多只有一个探针进程。
#   新增闸门: 断言这行清理存在(变异测试验证过: 删掉即报红)。
# 修订 26: 一键安装命令从 344 字符压到 220 字符(减 36%), 删掉的是冗余不是保险。
#   原来那一串里有两条断言其实是空的:
#   (1) `[ -f "$PN_TMP" ]` —— curl -f 失败就返回非零, && 链早就断了; 而且 -o
#   必然创建文件, 这个判断永远为真。
#   (2) `[ ! -L "$PN_TMP" ]` —— mktemp 用 O_EXCL 创建的是**新**文件, 名字随机;
#   /tmp 有 sticky 位, 同机用户既删不掉也换不掉 root 刚建的文件。所以"预置符号
#   链接"这个攻击在 mktemp 这一步就已经不成立了, 再判一次只是让人以为多了一层。
#   另外: 变量名 PN_TMP -> f; `--max-time 120` -> `-m 120`; `mv -f` + `chmod 755`
#   合成一条 `install -m755`(脚本本身早就用 install 装二进制, 依赖成立)。
#   注意 install 是复制不是移动, 所以补了 `rm "$f"` —— 少了它每次安装都在 /tmp
#   留一个 200KB 的脚本副本。
#   保留的部分一条都不能删: mktemp 随机名(防预置)、--connect-timeout 10(防无
#   输出挂死)、-o 到临时文件(防把能用的脚本顶成半截)、bash -n(防执行半截)、
#   落盘到 /root/setup-proxy.sh 再执行(脚本用 readlink -f "$0" 找自己, 跑 /tmp
#   下的文件会把 proxy 软链指到 /tmp, 紧接着被 cleanup_stale_scripts 清掉)。
#   新增闸门: 一键命令长度必须在 100~230 字符之间(用真展开算, 不是数源码字符),
#   外加"先 bash -n 再落盘 / 落点正确 / 会清临时文件"三条结构断言。给长度设上限
#   的理由是:"保险"这个词很容易变成"再加一条也不亏", 而这个命令是用户看到的第
#   一行东西, 每加一段都在劝退第一次用的人。
# 修订 28: REALITY 目标站池大改 —— 修掉"套 CF 的站拦不住"这个真漏洞。
#   (1) 漏洞本体: 原来判断"套了 Cloudflare"只看证书 issuer 里有没有
#   "cloudflare" 字样。但 CF 现在的 Universal SSL 边缘证书由 Google Trust
#   Services 签发 —— 实测 www.cloudflare.com 的 issuer 就是
#   "O=Google Trust Services, CN=WE1", 证书里根本没有 "Cloudflare"。结果是
#   套 CF 的站一个都拦不住: 实测池子里 suse / redis / w3 / nodejs 四个全是 CF,
#   全被当成合格候选。
#   为什么必须拦: CF 的 IP 段被大量代理和 VPN 占用, 是全网最可疑的一批地址。
#   拿 CF 站当 SNI, 等于主动把连接混进最容易被整体标记的那一堆里 —— 这比"站够
#   不够大"重要得多。
#   修法: 加第二个判据 —— 响应头里有 `server: cloudflare` 或 `cf-ray`。这两个头
#   是 CF 边缘加的, 源站改不掉。两个判据命中任一即排除。
#   (2) 探测合并: 原来"查 CF"和"查 TLS 版本"是两个函数, 各跑一次 openssl
#   s_client —— 同一个站的同一个握手跑两遍。合并成 dest_probe 一次拿全
#   (版本|ALPN|issuer), 超时同时从 8s 收到 5s(TLS 握手 5 秒没完成, 这个站当回落
#   目标也没意义了)。
#   (3) 分散度: pick_dest 里"每档只取最快 3 个随机"改成随档内数量浮动
#   (档内数/3, 下限 3 上限 8)。原来写死 3 —— 池子里二十多个合格的 TLS1.3 站,
#   却只从最快的 3 个里随机, 等于白扩: 全网几十万台机器还是集中在那 3 个域名上,
#   统计"哪些机房 IP 在跟这三个站握手"照样能整段捞出来。
#   (4) 池子规模定在 28 个, 不再往上堆。判断标准是"每个都要有真实流量掩护",
#   不是"越多越分散": 分散度由"每档取 N"决定, 不由池子大小决定。28 个 -> 档位 1
#   约 22 个 -> 取前 7 -> 7 种可能, 和池子 48 个的效果几乎一样, 但安装时少探
#   20 个站。砍掉的是流量掩护弱的(标准组织 / 开发者小众站 / 地区性品牌)和套 CF 的。
#   (5) 黑名单注释改正: 原来写"apple/microsoft 是 CDN 共用证书链", 实测不成立
#   —— 两家都是 TLS1.3、自家 CA 签发、SAN 只有 2~7 个域名。它们真正的问题是
#   "所有 REALITY 教程都写这两个", 全网几十万节点压在同一个 SNI 上, 这个 SNI
#   本身就成了指纹。理由写准确, 免得下次有人照着注释去验证, 验不过就把这条删了。
#   新增闸门(5 条, 全部做过变异测试): CF 检测走独立函数 / 看响应头不只查证书 /
#   认 cf-ray / 三条桩行为测试(CF 头命中、只有 cf-ray 也命中、普通头放过、
#   issuer 命中、GTS 但无 CF 头时放过)。桩测试的意义: 只查"字符串在不在"证明不了
#   逻辑对 —— 这次的漏洞正是"代码在, 但判据不覆盖真实情况"。
# 修订 29: 伪装站池按行业重挑, 全部实测过。
#   之前的池子有个没人提过的问题: 28 个站全是科技/硬件公司。这台机器长期只跟
#   科技站握手, 就是一个很干净的行业特征 —— 单一特征总比多样特征更容易被聚类。
#   "站够不够大"、"是不是 CDN"、"证书 SAN 多不多"这些都在讨论, 唯独没人问
#   "这 28 个站像不像同一个人会访问的"。
#   现在按 硬件(5) / 工业(3) / 汽车(2) / 软件(7) / 数据库(3) / 学术(2) /
#   消费电子(2) / 发行版(4) 铺开, 总数仍是 28 —— 这个数字是倒推的: pick_dest
#   每档取"档内数/3"个随机(上限 8), 要凑满 8 种可能, 档位 1 就得有 24 个候选,
#   所以池子不能少于 26 左右。再往上加收益很小(分散度由"每档取 N"决定, 不由
#   池子大小决定), 反而让安装时多探一堆站。
#   逐个实测(TLS 版本 / ALPN / 响应头 / 证书 SAN), 剔掉的:
#     套 CF 的 —— suse / redis / w3 / nodejs / gitlab / broadcom / ox.ac.uk / acm.org
#     TLS 只到 1.2 —— mit.edu / caterpillar(且 caterpillar 无 h2)
#     探测不稳定 —— mongodb / mariadb / honeywell / medtronic
#     证书 SAN 过大 —— oracle(83) / sony(79) / dell(26) / zeiss(58) /
#                     schneider-electric(100) / bmw(85)。这条不是"不安全", 而是
#                     一张证书挂几十上百个域名, 说明它站在共享基础设施上, 行为
#                     不如自有服务器可预测
#   补进来的都是实测 TLS1.3 + h2 + 非 CF + SAN ≤ 5 的: micron / ti / bosch /
#   abb / tesla / toyota / jetbrains / eclipse / docker / ethz.ch / cam.ac.uk。
#   两个非 .com 域名(ethz.ch / cam.ac.uk)是故意的: 全是 .com 本身就是个特征。
#   新增闸门 4 条: 池子覆盖汽车 / 工业 / 学术 / 有非 .com 域名。这四条守的不是
#   "数量", 是"像不像同一个人会访问的"。
# 修订 30: 上一版(修订 29)的判断反了 —— 主判据应该是流量排名, 不是行业多样。
#   修订 29 为了"行业铺开"和"证书 SAN 小", 把流量大的站换成了流量小的:
#     micron(12595) / bosch(10263) / abb(4009) 进了池子,
#     adobe(59) / oracle(217) / cisco(240) / dell(361) 被剔掉。
#   方向完全反了。流量规模决定"你的握手能不能淹没在噪音里", 这一条比行业多样和
#   SAN 大小都重要; 而 SAN 大根本不是安全风险 —— REALITY 是实时转发握手, 证书
#   特征不影响探测结果, "共享基础设施行为不可预测"只是间接推断, 不该当硬判据用。
#   现在 27 个站全部在全球流量排名(Tranco)2100 名以内, 中位数约 400:
#     adobe 59 / mozilla 92 / samsung 122 / apache 140 / ubuntu 158 / oracle 217 /
#     cisco 240 / hp 285 / debian 325 / autodesk 339 / nvidia 352 / dell 361 /
#     intel 453 / mysql 539 / asus 715 / python 742 / lenovo 794 / jetbrains 933 /
#     tesla 1105 / amd 1114 / postgresql 1161 / siemens 1166 / kernel 1272 /
#     fedora 1399 / cam.ac.uk 1526 / elastic 1984 / sony 2045
#   顺带回答"为什么不直接用 bing / amazon 这种顶级大站":
#     bing.com 只支持 TLS 1.2(实测), 进档位 2, 抗主动探测弱一档;
#     amazon.com 在国内不可达, 发 SNI 的那一刻就被拦了, 握手到不了 VPS。
#   排名 100 以内的站要么被墙(google / amazon / facebook / netflix / dropbox),
#   要么套 CF(microsoft / apple / zoom), 要么只到 TLS 1.2(bing)。能用的最大站
#   就是 adobe 这一档 —— 这是现实约束, 不是选站偷懒。
#   又剔掉两个不稳定的: ibm(同一台机器两次实测一次通一次不通)、docker(先通后不通)。
#   行业多样仍然保留, 但降为次要约束: 汽车(tesla) / 工业(siemens) / 学术(cam.ac.uk)
#   各留一个, 且它们的排名都在 2100 以内, 不是拿流量换来的。
# 修订 31: 修订 30 里关于 amazon 的说法是错的, 已改正; 另给 SNI 加站点说明。
#   错在哪: 修订 30 写"amazon.com 在国内不可达, 发 SNI 的那一刻就被拦了"。实测:
#     www.amazon.com 直连返回 503 —— 503 是应用层错误, TCP 与 TLS 都正常建立;
#     协商 TLS1.3 + h2, 证书签发者是自家 CA(Amazon RSA 2048 M04), 不套 CF。
#   四条硬判据全过, 它是池子里排名最高(28)的可用站, 已加入, 池子 27 -> 28。
#   同一段里"microsoft / apple 套 CF"也是错的: 实测两家 cf-ray 都是 0, 自家 CA,
#   SAN 分别 7 个和 2 个 —— 技术上完全合格。剔掉它们的真实理由是"教程用烂了":
#   几乎所有 REALITY 教程都写这两个, 全网几十万节点压在同一个 SNI 上, 它本身
#   就成了指纹。理由写准, 免得下次有人照着"套 CF"去验证, 验不过就把黑名单删了。
#   顺带确认: bing 只到 TLS 1.2 是真的(三次实测都是 TLSv1.2), 这条不变。
#   第二个改动: 池子里一半域名(cam.ac.uk / elastic.co / fedora / jetbrains...)
#   普通用户不认识, 而 SNI 是必须一字不差抄进客户端的一行, 抄错只会得到
#   "连接超时" —— 客户端不会告诉他是 SNI 错了。现在:
#     - 新增 dest_note(): 每个池子域名配一句"这是什么站";
#     - 终端 SNI 行下面补 "(剑桥大学官网; 这一行必须与客户端一字不差)";
#     - /root/proxy-info.txt 头部单独一行"伪装目标: 域名 (说明)" + 抄错的表现;
#     - test/run.sh 逐个检查池子成员都有 dest_note, 漏一个判红。
#   这次没动选站判据, 只改错的地方, 外加"让用户能自己核对"这一件事。
# 修订 32: 伪装站池回退到最初那 20 个(19 个), 并给用户一个能自己核对的入口。
#   为什么回退: 用户要求先用最初那批 —— 他认得那些站。这个诉求是合理的, SNI 是要
#   一字不差抄进客户端的东西, 认不出来的域名会让人怀疑自己被坑了。安全性本身不
#   取决于用户是否听过, 但"能核对"有独立价值。
#   20 个里只剔 suse, 两个实测理由:
#     - 套 CF: 响应头 Server: cloudflare + CF-RAY(实测三次)。用户自己定过"千万
#       不能套 CF"这条规则, CF 的 IP 段被大量代理占用, 是最容易被整体标记的一类;
#     - 握手不稳: 有一轮三次探测全失败(复测 3/3 又正常)。时通时不通的站不该进池子。
#   bing 按用户要求放回去了: 只协商到 TLS1.2(实测三次), dest_rank 判档位 2, 而档位
#   1 有 18 个候选 —— 实际永远轮不到它, 留着不影响安全, 也让争论到此为止。
#   同时把 nginx(104) 和 ibm(282) 加回来: 这两个是最初那 20 个里的, 后来一次被
#   "行业重挑"换掉、一次在探测里撞上偶发失败被当成不合格。各测 5 次都是 5/5,
#   TLS1.3 + h2 + 不套 CF 全过, 排名比池子一半的站都高。
#   教训: 单次探测失败不足以判定一个站不合格, 国内网络并发探测会大量超时 ——
#   剔站之前至少串行复测 3 次。
#   新增(和池子无关, 但解决同一类困惑):
#     - dest_note(): 每个池子域名配一句"这是什么站", 加站必须补, 测试逐个检查;
#     - proxy dest / proxy dest list: 看当前用的是哪个站、池子里还有哪些可选;
#     - proxy info 与 /root/proxy-info.txt 里 SNI 旁边标出站点说明 + "抄错的表现";
#     - 用户自定义 REALITY_DEST 时查不到说明就不写括号, 但"必须一字不差"照常提示。
# 修订 33: 池子定稿 18 个 —— 剔掉 bing, 不加 amazon。
#   用户说"不一定要 bing 和 amazon, 你要留那些好的, 这两个不好用的话就别加了"。
#   按实测判定:
#     bing   只到 TLS1.2(三次实测), 进档位 2, 而档位 1 有 18 个候选 —— 永远轮不到
#            它。留一个永远选不到的站, 只会让"池子里全是 TLS1.3"变成假话, 还得在
#            每个文档里加一句例外。剔掉。
#     amazon 四条硬判据全过(TLS1.3 + h2 三次、自家 CA、不套 CF、国内直连可建立),
#            但加它不增加任何分散度: N = 档内数量/3 且上限 8, 18 个时 N=6, 加一个
#            还是 6。既然用户不坚持, 就不为凑数加。
#   顺带查清一个容易被误判的事实: 池子里 13 个站是 **Akamai 边缘**(nvidia / ibm /
#   tesla / adobe / oracle / dell / hp / intel / mozilla / python / kernel / apache /
#   mysql), amazon 是 AWS CloudFront 边缘 —— "CDN 边缘终止 TLS"在这个池子里是常态,
#   不是缺陷。真正要避开的只有 Cloudflare 一家, 因为它的 IP 段被代理滥用的程度是
#   另一个量级。dest_behind_cf 只认 server: cloudflare / cf-ray, 不误伤 Akamai 和
#   CloudFront, 这是有意的 —— 别"顺手"把判据扩大成"凡是 CDN 都拦", 那会一次
#   误伤 13 个站。
#   proxy dest 列表末尾的总结相应改回"全部 TLS1.3 + h2"(池子里没有例外了)。
# 修订 34: 全项目审查(第 5 轮): 修 3 处"静态检查看不见"的问题。
#   方法是先做变异测试, 证明现有闸门没有假绿 —— 把 CF 响应头判据、一键命令清理
#   临时文件、每档随机上限、healthcheck 探针残留各破坏一次, 四条全部被对应断言
#   抓住。所以这次不再扫语法, 只查测试设计上覆盖不到的三类: 运行时、界面、并发。
#   1) 开机自启从来没被验证过。
#      `systemctl enable X >/dev/null 2>&1` 的返回值在 5 处被直接丢弃, 而
#      proxy verify 只查 is-active(进程现在活着), 不查 is-enabled(开机起不起)。
#      systemd 拒绝 enable 时(/etc 只读、单元被 mask、systemd 降级), 装完自检
#      全绿, 重启后节点静默消失 —— 这条路径上没有任何一处会报错。
#      改: 新增 enable_unit(), enable 完立刻复查 is-enabled, 失败就明说该敲什么
#      命令; verify 增加"未自启"判定并按失败计; 加闸门禁止再出现裸 enable。
#   2) 菜单里 SNI 是裸域名。
#      上一版只把站点说明加到了 proxy info 和 proxy dest, 而菜单是用户每次打开
#      都会看到的界面 —— 认不出 www.kernel.org 是什么站, 正是"看着不安全"的
#      来源。改: 菜单 SNI 后面带站点说明; 新增 x) 入口接到 proxy dest。
#   3) 没有并发锁。
#      一次安装要下三个二进制, 慢的时候几分钟; 用户以为卡住就再开一个窗口重跑。
#      两个进程各写一份 state.env(里面是 UUID 和私钥)、各改 systemd 单元、各往
#      iptables 加规则, 最后留下哪一份取决于谁后退出。改: acquire_lock() 用
#      flock(进程退出时由内核释放, 不会留僵尸锁), 只加在 install / upgrade /
#      reset / clean 这类会改系统的命令上, 查询类不加锁。
#   测试: 新增 13 条断言(819 -> 832)。锁的两条用假 flock 桩验证, 不依赖本机装
#   没装 flock; CI 里再用真 flock 验一次"被别人占住时立刻失败"。
#
# 修订 35: 国内直连名单集中到单一数据源 + 用户自定义 + 安全远程更新。
#   1) 三端(小火箭/Clash/sing-box)各写一份国内域名清单, 已经漂移过 —— 改一端漏
#      另外两端, 表现为"国内站时好时坏"。改: 域名只在 CN_DIRECT_SUFFIXES 存一份,
#      由 render_cn_sr_*/render_cn_clash/render_cn_sb_* 各自渲染; 校验器也从数据源
#      算"第一条规则长什么样", 不再写死 taobao.com。
#   2) 清单扩充并校准: 48 -> 123 个域名(补银行/物流/运营商/招聘/汽车/教育医疗等),
#      关键词 48 -> 65(只收独创品牌词; 58/sto/wps/dxy 这类数字或通用缩写不进关键词)。
#      收录标准写进注释: 只收 100% 境内、DNS 落国内的, 绝不收境外域名。
#   3) 用户自定义: /etc/proxy-node/user-direct.txt, proxy rule add/rm/list/check。
#      非法行(通配/下划线/路径)静默跳过, 不让一行垃圾进配置。
#   4) 远程更新: proxy rule update 从仓库 cn-direct.txt 拉取。官方源优先; 不可达
#      时退镜像且要求两个镜像哈希一致; 拉下来还要过格式强校验(大小/行数上限、
#      自证头、每条都是合法域名), 错误页或截断文件装不进来; 失败时现有名单不变。
#      与脚本自更新同一套安全模型, 但默认不自动跑, 只由显式命令触发。
#   5) sing-box 客户端配置此前没有国内直连域名规则(国内站会绕代理), 本次补上
#      domain_suffix/domain_keyword -> direct, 排在 STUN 拦截之后、final 之前。
#   测试: 新增 test/cn_direct_behavior.sh(21 条, 覆盖三端同步/用户远程合并/非法行
#   过滤/去重/cn-direct.txt 与内置零漂移) + 17 条静态断言。回归里发现原 sub_yaml_ok
#   测试是假绿(harness 没抽数据源, grep -F "" 恒真), 一并修正, 顺带修掉 Git Bash
#   把 printf "proxies:\n" 写成 "proxies:/n" 的 MSYS 路径转换坑。
#
# 修订 36: clash.yaml 缺 MLKEM 开关 —— mihomo 系客户端"配置全对但恒 0 流量"。
#   现象: FlClash / mihomo 导入 clash.yaml 后一切正常(206 条规则、两个节点都在、
#   无任何加载错误), 但延迟测试失败、上传下载恒 0 B; 同一节点换 v2rayN(xray 内核)
#   立刻能通 —— 极易被误判成"服务端坏了"或"订阅文件写错了"。
#   根因: Xray 25.9.11 起 REALITY 支持 X25519MLKEM768 混合密钥交换, 新版服务端优先
#   按 MLKEM 推导认证数据; mihomo 默认按经典 X25519 算, 而 chrome 指纹的
#   ClientHello 里带 MLKEM key share —— 两边算出的认证数据对不上, 客户端日志是
#   "REALITY authentication failed"。注意 TLS 握手本身是成功的(会正常拿到伪装站的
#   真实证书), 所以"能完成握手"完全不能证明 REALITY 认证通过。
#   实测(mihomo 1.19.34 + Xray 26.11.9, 同一份 UUID/公钥/shortId/SNI):
#     不加开关 -> is using X25519MLKEM768: false / Authentication: false
#     加开关   -> is using X25519MLKEM768: true  / Authentication: true (HTTP 204)
#   改: write_clash_yaml 的 reality-opts 补 support-x25519mlkem768: true。
#   不能无条件写: 老服务端不支持 MLKEM 时会退回 X25519 而客户端仍按 MLKEM 算,
#   同样失败。新增 clash_mlkem_ok() 按服务端 Xray 版本(>= 25.9.11)判断, 未知或
#   "追最新"按支持处理 —— 脚本内置兜底版本 26.3.27 已满足, 只有用户显式 pin 了
#   更老版本才不写。
#   影响面: 只有 mihomo 系(Clash Verge / FlClash / Mihomo Party)会踩; xray 内核
#   原生支持 MLKEM(实测通过); sing-box 实测同样失败, 且客户端侧没有开关可绕,
#   见修订 37。
#   测试: clash_yaml_behavior.sh 加 3 条(新版写开关 / pin 老版本不写 / 其余字段
#   照常), 41 -> 44 条。
#
# 修订 37: sing-box 内核连不上新版服务端的 REALITY —— 生成的订阅"合法但全断"。
#   现象: 用 singbox.json / v2rayn-routed.json 导入 sing-box 内核, REALITY 节点
#   一律 reality verification failed; 同一节点用 mihomo(clash.yaml)或 xray 内核
#   (v2rayn.txt)都正常。JSON 校验、sing-box check 全部通过 —— 格式没问题。
#   根因(上游, 与本项目服务端配置无关): Xray 26.9.8 起 REALITY 服务端要求
#   ClientHello 带 X25519MLKEM768 key share 且排在纯 X25519 之前, 否则判为
#   "非授权 ClientHello" 并静默 fallback 到伪装站; sing-box 用的 uTLS chrome
#   模板不发该 key share。issue SagerNet/sing-box#4520 至今 open, 1.14.4 实测
#   仍失败。客户端侧没有开关可绕, 实测排除: 换指纹(chrome/firefox/safari/ios/
#   edge)全失败; tls.curve_preferences=["X25519"] 无效(uTLS 不读该字段);
#   关 uTLS 直接被拒("uTLS is required by reality client")。另在本地起
#   Xray 26.11.9 服务端(全新密钥对)复现, 排除"本脚本服务端配置写坏"。
#   改: 新增 xray_ver_ge()(通用版本比较)与 sb_reality_ok()(服务端 >= 26.9.8
#   即不兼容); write_sb_client 在这种情况下把默认出口切到 HY2 —— REALITY 节点
#   照写(等上游修好可直接用), 但不能再当默认, 否则导入即"节点在、一字节不通"。
#   只开了 reality 时无从可切, 订阅生成阶段 warn 提示改用 mihomo/xray 客户端;
#   proxy dnstest --client 的清单也会按同样条件追加一段说明。
#   顺带: clash_mlkem_ok 改用 xray_ver_ge(25.9.11), 行为不变但少一份重复解析。
#   测试: 新增 test/sb_client_behavior.sh(30 条: 新旧服务端默认出口/只开 reality/
#   DEFAULT_NODE=hy2/五协议/版本边界 10 组/compat 一致/JSON 结构), 全量回归
#   939 -> 974 条。
#
# 修订 38: 复盘"铁律" —— 三条关于 REALITY/MLKEM 的断言是错的, 已按实测改正。
#   起因: 用户追问"版本策略和之前那些铁律是不是也可能错"。
#   1) "Xray 25.9.11 起支持 X25519MLKEM768" —— 错。REALITY 仓库 f07c896f71
#      (2025-05-12) + Xray v25.5.16 release note 都写明支持从 25.5.16 开始。
#      clash_mlkem_ok 的分界改为 25.5.16。实测(mihomo 1.19.34 + 本地起服务端):
#        25.4.30  + 写开关 -> auth=false (写了必挂, 所以下限不能更低)
#        26.3.27  + 写开关 -> 204 / MLKEM=true (能连, 且走抗量子)
#        26.11.9  + 不写   -> auth=false; + 写 -> 204 / MLKEM=true
#      旧阈值 25.9.11 会把 25.5.16~25.9.10 的服务端漏写(能连, 但没走抗量子)。
#   2) "v26.9.8 起强制 MLKEM 没有依据 / 该 tag 被删除"(修订 8 的判断) —— 错。
#      REALITY commit 8cdf7bf(2026-09-08) 明确拒绝不带 X25519MLKEM768 的
#      ClientHello, 含在 Xray 26.9.9 及之后版本里(26.9.8 那个 tag 现在 404, 行为
#      仍在); 我们用 26.11.9 服务端复现过。修订 8 当时查的是 tag 列表而不是代码
#      行为, 结论下反了 —— 教训: 版本断言要拿"跑起来的行为"验证, 不是拿 changelog
#      或 tag 存在性推断。
#   3) "自动写 MLKEM 开关会让老 mihomo 解析失败"(旧笔记) —— 错。mihomo 的 proxy
#      解码器是 structure.NewDecoder 非严格模式, 未知字段直接忽略: 实测 1.18.10
#      加载带开关的配置能正常启动, 只是认证失败(它本身不支持 MLKEM)。该字段自
#      1.19.10 起存在(1.19.0 没有)。
#   4) "Hysteria2 的仓库地址是 apernet/hysteria" —— 已过时。该仓库已改名/转移到
#      HyNetworks/hysteria(仓库 ID 257434373 一致, 同一个仓库; 旧地址目前仍 301)。
#      三处 URL(latest API / hashes.txt base / 下载)全部改成新址, 不再依赖重定向;
#      当前最新版是 app/v2.14.0(2026-11-15), 脚本会正常追到它。
#   顺带: 改掉"脚本装的下限是 26.3.27, 恒走 true 分支"这类过时注释(默认 latest,
#   只有显式 pin 老版本才可能不写); 升级提示里"别拿 26.9.8 吓人"的说法一并纠正。
#   README 补 mihomo >= 1.19.10、SB_VERSION 锁版本说明与"降级到 26.9.8 之前"的准确
#   说法(实测 26.6.27 可用)。
#   测试: clash_yaml_behavior.sh 加 6 条版本分界(44 -> 50), 全量回归 974 -> 980。
# 修订 39: sing-box 也改成默认追最新版 —— 修订 12 里"sing-box 仍锁版本"的两条理由,
#   一条已经不成立, 另一条有比"锁版本"更准的挡法。
#   1) "官方不发校验文件, 所以没法动态校验" —— 不成立了。官方确实不发
#      hashes.txt / .dgst(1.14.4 的 168 个资产里一个都没有), 但 GitHub Release
#      API 给每个资产都带了 digest(sha256:…), 由 GitHub 服务端对上传物现算。
#      核对结果: 1.14.4 的 linux-amd64 / linux-arm64 两个 digest 与脚本内置值
#      **逐字节一致**; 1.13.0 / 1.12.0 / 1.11.15 也都能取到 —— 说明它是可用的
#      官方来源, 任意新版本都有哈希可校验, 不必再用 ALLOW_UNVERIFIED_BIN 裸奔。
#      → 新增 sb_api_sha / sb_expected_sha(官方 digest 优先 / 内置值兜底 /
#        冲突拒绝), 三道闸门与 Xray、HY2 完全一致。内置值从"唯一来源"降级成
#        "离线兜底 + 防篡改基准": 官方值取到了就拿来比, 不一致直接拒装。
#   2) "小版本会删改配置字段, 追最新等于拿用户节点冒险" —— 仍然成立, 但按版本号
#      卡根本挡不住: 1.11 -> 1.12 就删了 legacy inbound 和 geoip, 那是同一个大版本
#      内的事。真正能挡的是实测 —— 换内核前用**新二进制** check 一遍现有
#      config.json, 不通过就放弃升级, 旧内核继续跑, 节点不断。所以这次不加版本
#      白名单, 加这道闸门, 并把上一版二进制留在 /usr/local/bin/sing-box.prev 供回滚。
#      闸门只认"配置解析失败"; 退出码 126/127 是执行不了(/tmp 挂 noexec 的加固机
#      常见), 必须放行 —— 否则那些机器会永远卡在老版本上, 还以为是上游的问题。
#   SB_VERSION 默认从 1.14.4 改成 latest(哨兵), SB_FALLBACK_VERSION=1.14.4 兜底;
#   API 不通时沿用本机在跑的版本, 绝不降级 —— 与 Xray / HY2 同一套 resolve 逻辑
#   (sb_resolve_behavior.sh 的 A~I 九个分支逐一卡住)。print_info 里那句"锁版本,
#   不自动追最新"改成"默认追最新, API 不可达时退 v1.14.4", 否则用户看到别人用新版
#   会误判脚本坏了。
#   实现踩坑(值得记): sb_api_sha 第一版用 tr -d '\r\n' 去掉换行后按 "},{" 切分,
#   但 GitHub 的原始响应是缩进过的, 只删换行会留下 "}      ,      {", 一刀都切
#   不开 -> 静默返回空 -> 悄悄退回内置哈希。表面上"装上了、也校验了", 实际上动态
#   校验从未生效, 而且没有任何报错。改成 tr -d '[:space:]'。
#   测试: 新增 sb_hash_behavior.sh(22 条) + sb_resolve_behavior.sh(9 条), 其中
#   "缩进过的多行 JSON"与"arm64 不误取 -glibc 变体"两条就是照这个坑写的回归 ——
#   拿压成一行的 JSON 测, 这个 bug 会被完美掩盖。
# 修订 40: 补国内静态资源/CDN 域名 —— "页面能开, 图片一直转圈"的根因。
#   起因: 用户拿别人的小火箭配置(机场订阅, 45KB/819 行)对比, 问"我们是不是漏了很多"。
#   拆开看, 那 45KB 里 88% 是"机场节点(17.7KB/92 个) + 规则表(21.7KB/674 行)",
#   另有 3.3KB 是一行 MITM 的 ca-p12 证书 —— 都不是"考虑更全", 是体量来源不同。
#   规则表 674 行里 246 条是 PROXY 显式列举, 在 FINAL,PROXY 下本可省略; 它们之所以
#   必须存在, 是因为那份配置的 DNS 全用国内解析(119.29.29.29, 无 #proxy=、无
#   force-remote-dns), 只能靠"先把境外域名钉成 PROXY"抢在 GEOIP,CN,DIRECT 前面,
#   否则本地解析出的 IP 可能被判成 CN。我们的架构是 DNS 走境外 DoH(#proxy=) +
#   FINAL 带 force-remote-dns, 域名根本不本地解析, 所以不需要那 246 行。
#   但那 674 行里有一类**我们真的漏了**: 国内站点的静态资源/CDN 域名。
#   实测对比: 抽 56 个常见国内 CDN/子站域名(alicdn/bdstatic/gtimg/hdslb/zhimg/
#   sinaimg/pstatp/126.net/wangsu…), 我们的 124 条后缀 + 65 个关键词 **一个都没覆盖**。
#   后果不是"打不开", 而是更隐蔽: 页面能开, 图片/JS 一直转圈, 且全走代理烧流量 ——
#   因为我们的 GEOIP,CN 带 no-resolve, 域名请求只认白名单, 主域名进了名单、
#   资源域名没进就掉到 FINAL,PROXY。
#   修法: CN_DIRECT_SUFFIXES 补 58 条(124 -> 182), 新增第16组「静态资源/CDN」
#   (alicdn/aliyuncs/bdstatic/bstatic/bdatu/yunjiasu-cdn/gtimg/qpic/qcloudimg/
#   myqcloud/tencent-cloud/hdslb/bilivideo/acgvideo/biliapi/zhimg/xhscdn/sinaimg/
#   360buyimg/pstatp/snssdk/byteimg/douyinpic/gifshow/qhimg/qhres/mi-img/meituan.net/
#   dxycdn/ykimg/cmbimg/cctvpic/126.net/127.net/163yun/wangsu/chinanetcenter),
#   另在各分类补 ithome/sspai/qdaily/zaker/lofter/qidian/douyu/huya/maoyan/qiyi/
#   alidns/dns.pub/doh.pub/eastmoney/dfcfw/cailianpress/tianyancha/meitu/
#   servicewechat/snwx/aaplimg/hicloud。cn-direct.txt 同步, 零漂移。
#   刻意**没**照抄的部分(各有理由, 不是漏):
#     - 对方 DIRECT 里的 PT 站(chdbits/hdbits/ourbits…)、学术库(ieee/jstor/
#       sciencedirect…)、成人站、paypal/booking/nvidia/oracle 等境外站 —— 那是他
#       用家宽 IP 做种 / 校园 IP 认证的个人场景, 照抄等于把境外域名的 DNS 导到国内。
#     - akadns.net(Akamai)、ccgslb.net、keepcdn.com 等来源不明的 —— 收录标准是
#       "100% 确定境内", 认不出来就不收。
#     - 两条 URL 重写(g.cn / google.cn -> google.com 302): https 改写必须先开 MITM
#       并在 hostname 里列该域, 而那份配置 [MITM] enable=false、hostname 里也没有
#       g.cn, 实际只在明文 http 下才可能命中; 且 g.cn 经代理出口时 Google 自己就会
#       302 到 google.com。为两条规则在手机上装 CA 证书、全局解密, 与防泄露目标相反。
#     - 微软系(microsoft/office365/windowsupdate): 加进直连有被干扰风险, 收益不明确。
#   测试: cn_direct_behavior.sh 加 8 条(21 -> 29), 其中 6 条钉死"资源域名在名单里",
#   防的是以后清理名单时把这些不起眼的 CDN 域名当垃圾删掉。全量 1030 -> 1038。

# 修订 41: 全项目逐行复查(231 个函数 + 17 个测试脚本) —— 修 16 处缺陷, 并做一次
#   结构性清理。用户要求"再看一遍有没有问题、去掉无用注释、架构有没有升级"。
#   高危(会造成数据丢失或节点停摆):
#     1) 菜单里 CLEAN 泄漏: 换过一次协议后 CLEAN=1 一直留在同进程, 回菜单再点
#        "部署"会**无确认**清空 users.txt 与全部 UUID, 所有客户端静默失效。
#        现在清理闸门消费掉这个开关后立即复位。
#     2) 显式传空端口(VLESS_PORT=)绕过两处 [ -n ] 校验, 写出 "port": , 的非法
#        JSON。按注释本意回退默认值(SUB_PORT 空仍表示随机)。
#     3) Xray / Hysteria2 的 install 二进制没有检查返回值, 而此前已经 stop 服务:
#        磁盘满/只读时节点停摆, 屏幕却报"已安装", 并把旧二进制哈希写进 state。
#        改为失败即中止; 另对 latest 解析出的版本号加 x.y.z 白名单(会拼进 URL)。
#     4) 主 UUID 变更时 users.txt 原地截断重写, tail 失败被 || true 吞掉 ->
#        其余设备凭据静默消失。改临时文件 + mv, 失败不动原文件。
#     5) 自更新回滚用 cp -a 覆盖正在运行的脚本(先 truncate), 与更新路径的
#        "mv 换 inode" 自相矛盾。回滚也改成临时文件 + mv, 且不毁掉 .prev。
#   中危:
#     6) sing-box / Xray / Hysteria2 配置改为"临时文件 + 校验 + mv": 校验失败时
#        不再把可用的旧配置覆盖成半截/非法文件(否则下次重启直接起不来)。
#     7) 自更新后"用新版本刷新 unit"实际调的是内存里的旧函数(与提示相反)。
#        改为 exec 新脚本的隐藏子命令 __refresh_units, 真正用新版代码重写。
#     8) 关闭 hy2 后 hy2-hop 服务与 NAT REDIRECT 不清理, 端口区间永久对公网敞开。
#     9) 健康检查无条件记"已重启", 重启失败也这么写, 排障方向被带偏; 改为如实记。
#    10) verify 把 healthcheck timer "未运行"标红却不计入 bad, 末尾仍报"自检通过"。
#    11) selftest 全部 SKIP 时返回 0("一项没测"= 通过); 改为返回 2。
#    12) proxy egress 在 EGRESS_URL 无法解析时 set -u 崩溃(unbound scheme)。
#    13) 本地隧道无 trap + setsid 可能 fork: Ctrl-C 后留下孤儿进程长期占 10897。
#        加 INT/TERM trap, 按唯一配置路径找回真实 pid, 进程组号等于自身时拒发负信号。
#    14) 备份包 tar 先建后 chmod, 自定义路径下有"私钥全世界可读"的窗口; restore
#        只校验成员名不校验类型(设备/FIFO 会被 root 真 mknod)。加 umask 077、
#        包内 state.env 完整性校验、成员类型白名单、--no-same-owner。
#    15) 升级 Xray 内核后不重新生成订阅, clash.yaml 的 MLKEM 开关仍按旧版本写。
#    16) 小火箭 #proxy= 用了百分号编码的节点名, 与导入后显示名不一致(中文名必然
#        对不上), DNS 指向不存在的节点会卡死。改用原名字(空格与链接一致转 -)。
#   架构清理:
#     - 三份逐字复制的 systemd 加固段抽成 unit_hardening(), 三份单元逐字节一致
#       (已用 diff 核对); 顺带把嵌套在 ensure_xray_service 里的 enable_unit 提到
#       顶层 —— 它此前依赖"先调用 ensure_xray_service"这个隐式顺序。
#     - 注释瘦身约 100 行: 删掉重复三遍的 MLKEM 说明、伪装站池的演化史、一键命令
#       的逐段复述, 保留全部"为什么"和测试锚点短语。
#     - 订阅目录权限改为服务确认启动后才放开; v2rayn-routed.json 纳入生成后校验;
#       sub.env 写入/权限失败即停; 提示里的 `bash $(basename "$0")` 在管道运行时
#       会变成 `bash bash install`, 改用 self_hint 回落 /root/setup-proxy.sh。
#   回归: 1038 PASS / 0 FAIL(基线不变), 三份脚本 md5 一致, bash -n 全过。
#
# 修订 42: 补上修订 41 原子写重构里漏掉的一处赋值 —— 回归抓到的真实崩溃。
#     1) write_singbox_config 只声明了 cfg_tmp, 却没给它 mktemp 出来的临时路径。
#        `} > "$cfg_tmp"` 于是重定向到空路径, 当场 die "写入 sing-box 配置失败"。
#        后果不是"配置写坏了"这么轻: ss2022 / anytls / tuic 任意一个协议重配
#        都会中止部署主流程。已补 mktemp 创建; Xray / Hysteria2 / sing-box 三处
#        现在逐个核对过"建临时文件 -> 写 -> 校验 -> mv"的配对, 无遗漏。
#     2) 三处声明统一补 cfg_tmp="": `local a=1 b` 里的 b 是"未定义"而不是空串,
#        set -u 下第一次取值就崩 —— 这个坑正是回归 harness 暴露出来的, 记在这里
#        免得以后有人"顺手简化"掉。
#     3) 版本 1.0 -> 1.0.1。这不是形式主义: proxy update 只比 SCRIPT_VERSION,
#        停在 1.0 的话已部署的机器会判定"无新版", 上面这些修复永远下发不下去。
#        顺手把三条写死 "1.0" 的文档闸门改成从 $VER 现算 —— 它们要防的是
#        "发版忘了同步 README/docs", 写死反而让每次发版都得回来改测试。
#   回归: 1038 PASS / 0 FAIL(基线不变), 三份脚本 md5 一致, bash -n 全过,
#   shellcheck v0.10.0 -S warning 零告警(与 CI 钉死的版本一致)。
#
# 修订 43: 第二轮全项目通读(5 路分段审计 1 万行 + 测试套件), 再修 11 处。
#   高危:
#     1) ensure_singbox 的 install 没查返回码 —— Xray / Hysteria2 两处都查了,
#        唯独这里漏了。磁盘满时装不上, 服务却已经 stop, 还 ok "已安装"并把
#        旧哈希写回 state。改为失败即从 .prev 恢复旧版并拉起服务再 die。
#     2) 同函数的 .prev 备份是 cp -f 就地覆盖, 中途失败就把唯一回滚点截成
#        半截文件。Xray / Hysteria2 的 upgrade 路径也各有同类:
#        - cmd_upgrade --rollback 用 cp -f O_TRUNC 目标, 磁盘满时先截掉
#          正在用的二进制再失败, die 后服务还停在停止状态;
#        - install_script_file 的 .prev 同样就地 cp, 写坏就失去自更新回滚入口。
#        三处全部改成同目录临时文件 + mv 原子替换, 失败先恢复服务再报错。
#   中危:
#     3) SID / PRIV / PUB 直插 REALITY JSON, 却不在 CRED_KEYS 里 —— 从
#        state.env 或备份恢复的值绕过了 safe_cred_scalars, 带引号/逗号即可
#        拼出额外 JSON 字段。纳入统一白名单。
#     4) set_timezone 只检查 -f /usr/share/zoneinfo/$tz, "Asia/../../etc/hostname"
#        会被文件系统解析到任意真实文件, 回退分支把 /etc/localtime 指过去。
#        手动输入补上字符白名单(自动探测那边本来就有)。
#     5) cmd_timezone auto 吞掉 set_timezone 返回码, 设置失败仍报成功。
#     6) cmd_rule rm 删用户名单里唯一一条时, grep 无匹配返回 1 使 && mv 不执行,
#        却照样打印"已移除"并留下 .tmp。改为先比对删除结果再 mv。
#     7) reality_probe 固定用 10899, 被同机进程占用后所有候选站都判失败,
#        pick_dest 掉进兜底分支还误报"出站 443 受限"。改随机端口 + 查占用。
#   低危:
#     8) maybe_sub_http 的三条 chmod 全吞错误: 权限没放开时 nobody 读不到
#        订阅文件, 所有请求 404, 却仍报"订阅服务已启动"。改为失败即 die。
#     9) 内部命令 __refresh_units 补 need_root(不加 acquire_lock: 父进程已
#        持锁, 子进程重开 fd9 会把自己判成"有别人在装")。
#   测试:
#    10) selftest_proto_behavior.sh 用 grep -c '通' 计数, "不通"同样命中 ——
#        reality 挂掉也能假绿成 2。改成先剔除"不通"再数, 并补 reality 不通用例。
#    11) 未采纳的一条: harness 的 min 恒为 1。它不是产品缺陷, 且要给每个
#        harness 精确登记断言数很容易做成假红; 现有的 min=1 已抓到过上一轮
#        cfg_tmp 那种"整个 harness 没跑起来"的崩溃, 收益不足以抵风险。
#   回归: 1040 PASS / 0 FAIL(1038 基线 + 2 条新断言), 三份脚本 md5 一致,
#   shellcheck v0.10.0 -S warning 零告警, bash -n 全过。

# 修订 44: 第三轮复查(改用"改动回归审查 + 并发/边界角度"), 修 5 处。
#   其中两处是修订 42/43 自己引入的回归 —— 这正说明"再读一遍"不够,
#   得换角度专盯"改动本身":
#     1) 修订 43 的时区白名单写成了 `^[A-Za-z_]+(/...)+` (斜杠后至少一段),
#        把 CET / EST / MST 这类单段合法时区全拒了。改成斜杠后继段可选。
#     2) 修订 42 把 SID/PRIV/PUB 纳入 CRED_KEYS 后, 非法值会被清空重生成;
#        ensure_creds 只补缺项, 换 PUB 连带换 PRIV —— 所有客户端静默失效,
#        脚本还照报"凭据已就绪"。改为遇到 REALITY 三键非法就中止并说明
#        需人工核对/确认后重新导入, 不制造隐性故障。
#   存量:
#     3) main 的互斥锁白名单漏了 sub/name/user/egress。它们看似只改一个字段,
#        实为 load_state -> 全量 save_state; 与 install/update 并发会把刚生成的
#        UUID / SUB_TOKEN 覆盖回旧值 —— 磁盘配置是新凭据、state 是旧凭据。
#     4) 换站失败回滚后有意保留 ${STATE_DIR}.before-dest 供人工恢复, 但 clean/
#        uninstall 不删它, 于是"已清除全部内容"之后机器上仍留着完整私钥/证书
#        副本, residue_report 也看不到。clean 清单补上 before-dest(.svc)。
#   测试:
#     5) 同步更新锁白名单断言(原来写死旧串会假红), 补 clean 清换站备份、
#        clean 清换站备份、REALITY 凭据非法中止两条静态断言。
#   扫描印证: 三种独立扫描器交叉核对 233 个函数里的 125 个 local 混合声明
#   候选, 排除 IFS-read / read_tty / for 批量赋值后剩 4 个, 逐个核对全是误报
#   —— local unbound 这一类在当前代码里没有真雷。

# 修订 45: 引入变异测试(mutation testing) —— 验证"测试本身"的有效性。
#   背景: 三轮修复里我自己引入过 2 处回归, 说明光有 1042 条断言不够 ——
#   得证明这些断言真的能抓到 bug, 而不是互相印证的假绿。
#   新增 test/mutation.sh: 把项目复制到临时目录, 在副本里注入 6 个已知缺陷
#   (删返回码检查 / 反转回滚条件 / 去掉时区白名单 / 凭据非法不中止 /
#    sub 命令脱离互斥锁 / clean 漏删私钥备份), 每个跑完整回归, 必须判 FAIL。
#   验证结果: 6 个变异全部被抓到(KILLED 6/6), 回归套件战斗力得到实证。
#   脚本只读原项目, 所有注入都在临时副本, 交付脚本零改动。
#   定位: 约 20 分钟/轮(6 份回归并行), 不放 PR 闸门, 作为发版前专项体检。
#   关于"抽原语": 评估后决定不动产品代码 —— 三处原子写的差异部分(DNS 回退、
#   六轮降级)远大于可抽的共性, 且这些函数被测试 harness 按顶格 } 单独抽取,
#   加原语调用就得同步改 harness, 正是前几轮引入 bug 的模式。变异测试已证明
#   现有断言有效, 此时重构是净风险。

# 修订 46: 重建单一根提交, 版本定为 1.0。
#   清掉旧历史/旧 tag/旧 release, 把修订 41~45 的全部修复做成唯一的 1.0 发布。
#   因为仓库从零重建、没有需要兼容的旧版, SCRIPT_VERSION 从 1.0.1 回到 1.0,
#   与 v1.0 tag 严格对齐(CI 有 tag 版本一致性硬闸门)。README / docs badge 同步。

# 修订 47(未发布): 真实 VPS 全新安装暴露的致命 bug + 5 路分段审计的 12 处修复。
#   致命: ensure_users_file 的 `&&` 空值短路让全新安装 100% 中止 —— 用户新 VPS
#   卡在"挑选伪装目标站"后 die "无法写入 users.txt"。根因是 `_rest` 为空时
#   `[ -n "$_rest" ] && printf` 让写块返回 1, 被 `|| { return 1; }` 误判为写失败。
#   测试此前只覆盖 CREDS_UUID_CHANGED=0, 恰好漏了首次安装这条最该测的路径。
#   审计另修 12 处: ensure_users_file 写/权限与显式返回 0、pick_dest 回滚原子写、
#   firewalld reload 与规则记录失败不再吞、SB 二进制哈希非空校验、SB 证书指纹
#   失败改 die(对齐 HY2)、订阅校验补 client-guide.md / v2rayn-safe.txt、
#   proxy-info.txt chmod 不再静默、Xray upgrade .prev 原子备份、增删设备写配置
#   失败计入 bad、cmd_user add / cmd_rule rm 写入失败中止、安装/恢复/重置检查
#   gen_sub_files 返回码、deadfns 扫描加"至少识别 100 个函数"正向对照防假绿。
#   三份脚本 md5 一致, bash -n 全过; 回归第 1-10 节全绿。SCRIPT_VERSION 保持
#   1.0: 清掉旧 tag / 旧 Release 后, 把全部修复做成新的单一根提交重新发布 v1.0。
#
# 修订 48: 重发 v1.0 后真实 VPS 重装仍失败 —— 配置临时文件扩展名陷阱。
#   现象: 全新安装过 users.txt 那关后卡在 Xray 配置校验, 且先误报"内置 DNS 配置
#   不被当前 Xray 版本接受, 回退为系统解析", 回退后第二次校验仍失败。校验错误
#   没写日志(sed 只打到 stderr), 靠读 Xray 26.11.9 源码才定位。
#   根因: mktemp "${XRAY_CFG}.XXXXXX" 生成 config.json.aBcDeF —— 最后一个点是
#   `.aBcDeF`, 不是 `.json`。Xray 26.11.9 的 core.LoadConfig("auto") 对未知扩展名
#   直接返回 "Failed to get format of ..."; 旧版默认按 JSON 解析, 所以以前没暴露。
#   同批修 sing-box(check 也按扩展名判断)与 Hysteria2(统一保留 .yaml 后缀)。
#   修法: mktemp "$(dirname "$XRAY_CFG")/.config.XXXXXX.json", 临时文件保留原扩展名。
#   测试: run.sh 加 3 条断言(新旧版本对照验证过: 新版命中 1, 旧版命中 0)。
#   SCRIPT_VERSION 仍保持 1.0, 与 v1.0 tag 对齐。
#
# 修订 49(未发布): 第四轮审计 —— 专补"外部工具行为变化"这个前三轮盲区。
#   前三轮盯退出码/原子写/配置路径, 却漏了 Xray 26.11 扩展名陷阱 —— "代码
#   逻辑正确"不等于"外部工具接受"。本轮换角度: 工具链 / 内嵌服务 / 文档 /
#   测试有效性, 用 5 路只读审查 + 逐条回源码(必要时读上游 Go 源码)复核,
#   确认 11 类问题并全修:
#     1) hysteria version 首行是空 logo(上游 appLogo 以 \n 开头), 安装提示 /
#        status / bin_ver 三处 head -1 恒取空串 —— 改从 "Version:" 行取。
#        用模拟上游输出实测 bin_ver 返回 2.14.0。
#     2) cmd_speed 的 tc qdisc 字段错位: "qdisc fq_codel 0: root" 里 $2 是
#        队列名、$4 才是 root, 旧写法 $2=="root" 恒假 —— 永远打印 sysctl
#        默认值, 正是注释要避免的假绿灯。
#     3) 订阅目录 755/644 把 links.txt 里的全部 UUID/密码开放给同机任意用户
#        (token 形同虚设) —— 改成属主交给 nobody、权限保持 700/600, verify
#        判据同步(不再把 755 判为正常), token 轮换时收紧旧目录。
#     4) EGRESS_URL 非法时原样回显 socks5://用户:密码@..., 密码进终端和日志;
#        diag 本来就脱敏, 这里对齐。
#     5) hysteria-server.service 缺 FORCE_UNIT_REFRESH, 老机器 proxy update
#        后单元永远刷不新 —— 抽出 ensure_hy2_service 与 xray/sb 对齐;
#        __refresh_units 补 hy2 并重启进程(否则刷新等于没刷)。
#     6) 订阅服务 HTTPServer 默认 AF_INET, SUB_BIND=:: 时 gaierror 退出但
#        state 仍记 SUB_HTTP=1 —— 内嵌 server.py 按 ":" 选 AF_INET6。
#     7) README egress 生效范围漏了 ss2022; CHANGELOG 修订 44 整段重复。
#     8) 订阅超时测试只判 truthy 且用 timeout=1 子类覆盖产品值 —— 改成
#        断言合理区间(1..120), 避免把 timeout=3600 判绿。
#   测试: 新增 15 条结构断言, 逐条用旧版本反证(新版命中 / 旧版不命中);
#   shellcheck v0.10.0 -S warning 零告警, 三份脚本 md5 一致。
#   SCRIPT_VERSION 仍保持 1.0, 未提交未推送。
#
# 修订 50: 真实 VPS 反馈"重跑安装后 Reality 慢, HY2 正常"。
#   先排除 DNS: dig @1.1.1.1 / 8.8.8.8 / 223.5.5.5 分别 4ms / 0ms / 52ms,
#   内置 DNS 不是瓶颈; BBR+fq 也已生效。定位到 optimize_system 写进
#   /etc/sysctl.d/99-proxy-optimize.conf 的 net.ipv4.tcp_notsent_lowat=16384:
#   Xray 是 Go 程序, 靠 epoll 的可写事件驱动写入, 16KB 阈值让每条 TCP
#   连接最多只有 16KB 未发数据, 高延迟跨境链路上吞吐被压到 1Mbps 量级。
#   只影响 Reality/TCP, 不影响 UDP 的 Hysteria2 —— 与用户现象完全吻合。
#   修法: 从 sysctl 配置块中删除该行, 并在配置写入后**显式**执行
#   `sysctl -w net.ipv4.tcp_notsent_lowat=4294967295` 恢复内核默认 ——
#   sysctl -p 不会重置已从文件里删掉的键, 不显式恢复就要重启才生效。
#   特别注意不能设 0: 内核里 tcp_notsent_lowat() 对 0 会退化成阈值 0,
#   POLLOUT 永不触发, Go/epoll 程序(Xray)会直接停发数据, 比 16384 更致命。
#   回归加两条闸门: "不再写入该参数" + "显式恢复 UINT_MAX"。
#   三份脚本 sha256 一致, bash -n 通过, 回归静态段 400 PASS / 0 FAIL。
#   与修订 47~49 一起以单一根提交重新发布 v1.0。
#
# 修订 51(第六轮全量审计): 六路并行审查(安全 / 端到端 / 客户端 / 上游对比 /
#   CI 测试 / 边界异常), 逐条源码复核后修 13 项真实可触发缺陷:
#     1) 只开 REALITY 且 Xray >= 26.9.8 时, sing-box 客户端配置默认出口不可用
#        却不告警, 指南还谎报"已切到 HY2" —— 新增 SB_REALITY_ONLY 标记,
#        无 HY2 可切时明确告警并改写指南(指向 clash.yaml / xray 内核)。
#     2) v2rayn-safe.txt 条件生成却无条件推荐 —— 指南按实际启用协议提示。
#     3) healthcheck 脚本/unit/timer 三处写入无检查, 磁盘满仍报"部署完成"。
#     4) xray / hy2 / sing-box 三份 systemd unit 写入无检查, 假成功。
#     5) limits.d / journald.conf.d 写入无检查, 仍打印"句柄数 65535 / 日志 100M"。
#     6) 订阅 server.py / proxy-sub.service 写入无检查, 横幅报成功但订阅 404。
#     7) 纯 hy2 路径 ensure_users_file 失败被忽略, 多设备凭据静默丢失。
#     8) restore 忽略防火墙失败仍报"恢复完成"。
#     9) upgrade --rollback 只回退二进制与 state, 不重生成订阅 —— 回滚不彻底。
#    10) __refresh_units 遇损坏 state 静默 exit 0, proxy update 假报刷新成功。
#    11) user rm 内核重载失败仍报"旧链接立即失效" —— 改为回滚原凭据文件再 die。
#    12) --clean 清空凭据列表漏了 EGRESS_URL(含住宅代理密码), 被写回新 state。
#    13) verify 里 hysteria 版本仍取空首行, 显示空白 —— 改从 Version: 行取。
#   排除项(复核后非缺陷): GHSA-5wf9-h793-w73c 只影响客户端用 pinnedPeerCertSha256
#   固定 CA 的场景, 本项目不使用该配置; 自更新已有 PN_NO_SELFUPDATE 开关且
#   下载后有多重自证校验, 属"curl|bash"通用设计权衡; Apple 域名直连走国内 DNS
#   是为推送/速度的主动选择; HY2 单共享密码、流量统计/fail2ban、官方内置端口跳跃
#   属产品功能差距, 不擅自扩大改动面引入新风险。
#   三份脚本 sha256 一致, bash -n 通过, 回归静态段 419 PASS / 0 FAIL。
#
# 修订 52: 用户实测"开着 VPN 抖音没网"——国内直连域名的 DNS 分流漏配。
#   根因: 路由规则把抖音及 CDN 域名(douyin.com / snssdk.com / byteimg.com /
#   pstatp.com / douyinpic.com / gifshow.com)设为 DIRECT, 但 DNS 规则没同步:
#     - Clash 的 nameserver-policy 只有 geosite:cn, 这些 CDN 域名不在其中,
#       落到默认 nameserver(境外 DoH 经 PROXY), DNS 经代理出境外;
#     - sing-box 的 dns.final=remote, 除 .lan/.local/.arpa 外全部用境外 DoH。
#   结果域名走直连、DNS 却用境外解析, 拿到境外 CDN 节点 -> 抖音打不开。
#   修法: 新增 render_cn_dns_clash / render_cn_dns_sb_suffix / _keyword,
#   把同一份 CN_DIRECT 白名单注入两端 DNS 分流(Clash 的 +. 通配键指向国内
#   DoH; sing-box 的 dns.rules domain_suffix/keyword 指向 local UDP DNS)。
#   TikTok 等非白名单域名不受影响, 仍走境外 DNS(避免送中)。
#   小火箭端本就用 direct-dns-server 处理直连域名, 无需改动。
#   测试: run.sh +5 条源码断言; clash_yaml_behavior.sh 加产物断言(抖音进
#   国内 DoH、TikTok 不在), sb_client_behavior.sh 加 4 条产物断言。
#   回归 482 PASS / 0 FAIL; 行为测试 clash 54/0、sing-box 34/0。
#
# 修订 53(小火箭 DNS 架构纠错): 用户实测"小火箭连 VPN 后抖音打不开", 质疑修订
#   52"小火箭无需改动"的结论。查 Shadowrocket 官方 wiki 与 lazy_group.conf 原文
#   证实该结论错误, 三处配置方向与官方相反:
#     1) dns-server(DNS 覆写)按官方语义【只服务直连域名】, 官方默认国内 DNS;
#        我们却设成 cloudflare 境外 DoH 经代理(#proxy=节点名), 让抖音/淘宝等
#        直连域名解析到境外 CDN 节点 -> "开 VPN 抖音打不开"。改为国内 DoH
#        (doh.pub/alidns + 223.5.5.5/119.29.29.29), 不经代理。
#     2) hijack-dns 官方值是 8.8.8.8:53,8.8.4.4:53(只劫持写死境外 DNS 的 App);
#        我们设 :53 劫持全部 DNS, 把国内 App 发往运营商/国内 DNS 的正常查询也
#        接管。改回官方值。
#     3) dns-fallback-system 官方不存在(死配置); 改用官方 fallback-dns-server,
#        回退也钉在国内 DNS。
#   境外域名(TikTok 等)仍走 FINAL,PROXY,force-remote-dns 服务端解析, 不受影响,
#   dnsleaktest 仍显示境外解析器 —— 防泄露主力未动, 只纠正直连域名这一条腿。
#   连带删除 #proxy= 节点名回退逻辑(_dns_pick/dnn): DNS 不再依赖节点名, 消除
#   "节点名写错 DNS 卡死"整类故障。
#   三份脚本 sha256 一致; 行为测试 shadowrocket_conf_behavior.sh 59 PASS / 0 FAIL。
#
# 修订 54(第七轮全量审计): 用户追问"国内走国内DNS/国外走国外DNS 做到完美了吗、
#   整个项目还有问题吗"。三路只读审计(三端DNS完整性 / 风控检测面 / 代码正确性)
#   逐条源码复核, 修 3 项真实缺陷:
#     1) Clash 的 DNS 分流漏掉"关键词品牌"的主域名: cainiao/haier/lenovo 只收在
#        CN_DIRECT_KEYWORDS(关键词兜底)里, 主域名没进后缀清单。而 mihomo 的
#        nameserver-policy 键只支持 +./*. 通配与 geosite, 不支持关键词子串 ——
#        这些域名在 Clash 里走 DIRECT 路由却用境外 DoH(路由/DNS 分裂)。
#        修法: 把 cainiao.com/haier.com/lenovo.com 补进 CN_DIRECT_SUFFIXES 与
#        cn-direct.txt(三端路由与 DNS 同时覆盖)。vipshop 的主域名 vip.com 本就在
#        电商段, 不重复。教训: 变量内部不能写 # 注释, 遍历按空格分词会把注释当域名。
#     2) hy2-hop.service 写入无失败检查: 前面已停旧 unit + 清 iptables 规则, 写失败
#        若不 die, 仍 enable 一个空 unit 并报"可能缺 iptables nat 支持", 排障方向错。
#        改为 if ! cat ... || { hop_cleanup_rules; die; }。
#     3) proxy user add 重载失败不回滚(与 rm 不对称): 写入成功但内核没认新用户时
#        仍报"已添加"并发分享链接 -> 用户导入必连不上。改为先备份, 重载失败恢复
#        原凭据文件再 die, 绝不发连不上的链接。
#   复核后排除的误报: egress 的 save_state 无 || die 不是问题(save_state 内部失败
#   即 die); upgrade --rollback 读版本与升级分支同款逻辑, "格式变化"属假设场景;
#   Apple 三端直连不一致是主动选择(推送/速度), 影响面小。
#   三份脚本 sha256 一致; cn_direct_behavior 34/0; shadowrocket 59/0。
```
