# REVIEW-7 — socks-relay.py 与 gacc 中继集成代码评审

- 对象：`bin/socks-relay.py`（156 行，新增）；`bin/gacc` 中 `relay_port_of` / `ensure_relay` / `kill_relay` / `render_proxy_block` 凭据分支 / `--stop`。
- 方法：纯静态评审 + 本地闭环实测（127.0.0.1 上的假上游/echo 目标），未触外网。`py_compile` 通过；`shellcheck -S warning bin/gacc` 零告警。
- 注意：评审过程中 `bin/gacc` 被外部更新过一次（11:07，`kill_relay` 新增 ps/awk 兜底），本报告以当前磁盘版本为准。

实测记录（全部 127.0.0.1 闭环）：
- T1 基本握手+转发：**OK**。
- T2 客户端半关闭后读响应：**FAIL**，响应丢失（recv 得 `b''`）。
- T3 非法 ATYP：直接关闭、无错误回复（不挂死，但无 0x08）。
- T4 客户端只 offer 0x02：中继仍回 `05 00`（RFC 应为 `05 FF`）。
- T5 端口被占：中继 exit 1、**不写 pidfile**（pidfile 在 bind 成功后写，设计正确）——但 gacc 侧完全无感知（见 C1）。
- T6/D1 实测：`ps -eo args` 可见 `--pass p@ss w"空间` 明文（空格/引号/@/CJK 均能正确作为单个 argv 传入，问题是**可见性**不是解析）。
- 八进制实测：`relay_port_of 08` → `bash: 21000 + 08: value too great for base`，exit 1。

---

## 1. 安全

- **A1（中，建议必修加固）**：`socks-relay.py:125-132` 对 `--listen` 不做任何校验，`rpartition(":")` 后 host 为空才回退 127.0.0.1。若传入 `0.0.0.0:21001`，就变成一个**对全网开放的无认证代理，且自动携带上游凭据**——等价于把付费代理免费送网段。当前 `gacc:211` 硬编码 `--listen "127.0.0.1:$port"`，所以只是纵深防御缺口，但脚本应在启动时校验 listen 地址是 loopback，否则直接退出。
- **A2（低-中，需文档化）**：即使只听 127.0.0.1，本机**任何用户、任何进程**都能连 `21000+NN` 白嫖这个带凭据的上游——中继本地侧无认证是设计使然（Firefox 不支持 SOCKS 认证），但固定可知端口号让滥用零成本。多用户机器上这是实打实的风险。缓解有限（随机端口+写进 0700 目录下的 relay.port，而不是可预测的 21000+NN），至少要写进 README。
- 好的一面：`gacc:16` `umask 077`；`write_proxy`（`gacc:173-176`）拒绝凭据/主机含空白字符；`mask_spec` 打码；`render_proxy_block:256-259` 对 `\` `"` 的转义正确（虽然凭据分支后 `creds=""`，`auth_blk` 已成死代码，无害）。

## 2. 协议正确性

- **B1（中，实测确认）半关闭截断响应**：`socks-relay.py:21-35` 的 `pipe()` 在任一方向读到 EOF 时 `writer.close()` **整关整条连接**。客户端 `shutdown(SHUT_WR)`（发完请求半关闭等响应）的场景下，c→u 管道 EOF 会把上游 socket 双向关掉，u→c 方向尚在传输的响应被丢弃——实测 T2 复现。建议改用 `writer.write_eof()`（对端支持时）并等两个方向都结束再关。
- **B2（低，实测）**：`socks-relay.py:81` 无条件回 `05 00`，即使客户端的方法列表里没有 0x00（RFC 1928 要求回 `05 FF` 并关闭）。Firefox 恒 offer 0x00，实际无害。
- **B3（低，实测）**：`socks-relay.py:97-99` 遇到未知 ATYP 直接 close，不回 `rep=0x08` 的错误响应。客户端靠 EOF 感知（不会挂死，T3 实测），但排错信息少。
- **B4（低）**：`socks-relay.py:39` `asyncio.open_connection` 无超时。上游是黑洞（丢包不 RST）时协程挂到 OS TCP 超时（约 2 分钟），期间客户端已超时离开，任务滞留。建议 `await asyncio.wait_for(..., 10~15s)`。
- **B5（低）**：`socks-relay.py:58-59` 上行 CONNECT 恒用 ATYP=0x03（域名）。客户端给 IPv4/IPv6 字面量（`:91`/`:96` 已正确解析）时被转成字符串按域名发给上游，依赖上游 getaddrinfo 容忍数字字面量——主流实现没事，但规范做法是保留原 ATYP。
- 无挂死路径：客户端连上不发数据只占一个协程（本地，量小）；握手各步异常都有 `:117-121` 兜底关闭。上游失败路径（`:104-109` 回 `rep=0x05` 后关闭）、cmd≠CONNECT（`:85-89` 回 `0x07`）、上行三种 ATYP 回复解析（`:64-70`）都齐全正确。

## 3. 生命周期

- **C1（高，必修）`ensure_relay` 失败也返回 0**：`gacc:213-218` 探测循环 5 秒跑完后**无论端口通不通**都写 `relay.port` 并 `return 0`。实测 T5：端口被占时中继进程 exit 1、不写 pidfile，而 gacc 照常认为成功。探测用的 `/dev/tcp` 还只验证"有东西在听"，端口被无关服务占用时同样误判成功。修法：循环结束后确认 pidfile 存在且进程存活、端口确实由中继监听，否则 `return 1`。
- **C2（高，必修）改代理不重启中继**：`gacc:206-207` 只看 pidfile 活没活，不比较当前 spec。旧中继带着**旧上游/旧凭据**在跑时，`--set-proxy` 或 `--proxy` 改了配置，`ensure_relay` 直接复用旧中继——而 `render_proxy_block` 按新 spec 把浏览器指向中继，认证目标却是旧的。更糟的是 `gacc:553` 提示"下次启动生效"，但下次启动走 `:539` 同一个 `ensure_relay`，依然复用旧中继，**永远不生效**（除非 `--stop`）。修法：把 spec（或其哈希）写进 `relay.spec`，不一致就先 `kill_relay` 再启动。
- **C3（中）pid 复用 / 验活不验身份**：`gacc:206` `kill -0 $(cat pidfile)` 只证明"有个进程"。中继崩溃后 pid 被复用 → 误判存活、返回 0、浏览器指向死端口；重启机器后 `runtime/` 里的陈旧 pidfile 撞上回收 pid 的概率更高。反向地，`kill_relay:227` 直接 `kill` pidfile 里的 pid，可能杀掉无辜进程。新增的 awk 兜底（`gacc:229-232`，按 `python3` + `socks-relay` + 端口字面值匹配）方向正确；pidfile 分支应同样先验 `/proc/$pid/cmdline` 含 `socks-relay.py` 再 kill/信任。
- **C4（中）端口冲突**：`21000+NN` 固定端口撞上本机其它服务时，因 C1 静默失败。账号间不互撞（NN 唯一），但 `gacc:484` 只校验 `^[0-9]+$`，ACC=99999 → 端口超 65535，无上限校验。
- **C5（中，实测）八进制 bug**：`relay_port_of`（`gacc:191`）`$(( 21000 + $1 ))` 把前导零当八进制，**账户 8 和 9**（写成 08/09 或直接给 8 不会触发——但 `:203` 等处 `printf '%02d'` 语境及用户手输 `gacc 08` 都会触发）直接 arithmetic error。`ensure_relay` 在 `|| true` 上下文里被吃掉继续跑（port 为空、python 起不来、白等 5 秒），随后 `render_proxy_block:252` 在非 `||` 上下文再炸一次，set -e 让脚本莫名退出。修法：`$(( 21000 + 10#$1 ))`。
- **C6（低）浏览器崩溃 → 中继常驻**：设计上靠下次启动经 pidfile 复用（合理），但若用户不再启动也不 `--stop`，中继永久泄漏。可接受，文档化即可。
- **C7（低）`--stop` 语义**：`gacc:506` 先 `kill_relay` 再杀浏览器，顺序对；pidfile 丢失时有 `:229-232` 兜底（好）。但 kill 后不等退出即返回，端口短暂残留无碍（SO_REUSEADDR）。

## 4. 凭据处理

- **D1（高，必修，实测确认）密码在 argv 明文裸奔**：`gacc:210-212` 把 `--user "$u" --pass "$pw"` 放命令行，`/proc/<pid>/cmdline` 默认全机可读，实测 `ps` 输出里密码（含空格、`"`、`@`、CJK）完整可见——这是本评审**最严重的实质安全问题**（A1 只是假设场景，D1 是当前默认行为就在泄漏）。修法：改用环境变量（如 `RELAY_USER`/`RELAY_PASS`，python 侧 `os.environ` 读取）或 stdin 传入；argv 里一个字符都别放。
- **D2（低）字符集**：空格/换行在 `gacc:173-176` 已被拒（走不到中继）；引号、`@`、非 ASCII 经 bash 引号传参 + python `encode()`（`socks-relay.py:47-49`）实测正确。`@` 的解析（`gacc:200` `%@*`/`##*@` 取最后一个 @）与 write_proxy 侧一致。user/pass 超过 255 字节时 `bytes([len(u)])`（`socks-relay.py:49`）抛 ValueError，走上游失败路径，不崩溃但无提示。
- `socks-relay.py:136` 的日志与 `relay.log` 不含凭据，好。

## 5. 依赖与失败模式

- **E1（高，必修，与 C1 同根）无 python3 时静默降级成"代理坏了"**：`gacc:209` 正确检测到缺 python3 并 `return 1`，但 `:539`/`:548` 都是 `ensure_relay "$ACC" || true` 吞掉失败，浏览器照常启动；`render_proxy_block:251-252` 在 relay.port 缺失时**兜底算出 21000+NN 写进 user.js**——Firefox 指向一个永远不存在的端口。带凭据代理下，`ensure_relay` 失败必须中止启动（或至少渲染回 direct 并大字警告），不能 `|| true` + 兜底端口。
- **E2（中，必修）scheme 错配**：`ensure_relay:199` 只看 spec 里有没有 `@`，不看 scheme。`http://user:pass@host:port` 或 socks4 带凭据时：中继对上游说的是 **SOCKS5 握手**（`socks-relay.py:41`），对 HTTP 代理全灭；`render_proxy_block:249-254` 又不管什么 scheme 都把 host/port 换成中继，HTTP 分支会把 `network.proxy.http` 指到一个 SOCKS5 端口。修法：`ensure_relay`/凭据分支限定 `scheme == socks5`，其它 scheme 带凭据直接 die 提示不支持。
- **E3（低）doctor 测的不是真实路径**：`gacc:436-439` 用 curl 直连带凭据上游（curl 支持 SOCKS5 认证），中继挂了 doctor 照样报"连通性 OK"。建议 doctor 增加对 127.0.0.1:relay.port 的探测。

## 6. 结论

**需修，暂不可投用。** 必修（按优先级）：

1. **D1** 凭据改走环境变量/stdin，移出 argv（`gacc:210-212` + `socks-relay.py:145-146`）。
2. **C1+E1** `ensure_relay` 失败必须返回非 0 并让带凭据场景中止启动；删掉 `render_proxy_block:251-252` 的死端口兜底（`gacc:213-218, 251-252, 539, 548`）。
3. **C2** spec 变化要重启中继（存 spec 哈希比对，`gacc:206-207`）。
4. **E2** 中继路径限定 `scheme == socks5`（`gacc:199, 249`）。
5. **C5** `10#$1` 修八进制（`gacc:191`）。
6. **A1** `socks-relay.py` 启动时拒绝非 loopback 监听地址（`socks-relay.py:125-132`）。

建议（非阻塞）：C3 pidfile 验身份后再 kill、B1 半关闭改 `write_eof`、B4 上游连接加超时、E3 doctor 测中继、C4 账号号上限校验、A2/C6 写文档。
