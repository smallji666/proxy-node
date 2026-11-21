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
```
