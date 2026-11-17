# REVIEW-6（kimi）：assign-proxies.sh + gacc 代理函数

纯静态评审。

## 1. 粘性分配：有漏洞

| 问题 | 依据 |
|---|---|
| 写 proxy.conf 与渲染非原子：`--proxy` 在参数解析阶段已落盘，`--render` 随后才执行；渲染失败时 proxy.conf 已是新值，下次重跑被"已绑定"跳过，user.js 与 proxy.conf 永久失配且被粘性掩盖 | gacc:413→145-171, 462-468；assign:124 |
| `--check` 测的是 spec_for 重算的 round-robin 端口，不是 proxy.conf 实绑端口——被跳过的账户测错代理 | assign:166-167 vs 123-125 |
| 端口只查数字，0 / >65535 不限界 | assign:76-81 |
| 粘性+按号取模不查已有绑定，新旧账户可撞同一端口共享出口 | assign:103 |

## 2. 凭据解析与明文风险

| 输入 | 行为 | 依据 |
|---|---|---|
| 密码含 `:` | 安全（取首个冒号后全部） | gacc:187-188 |
| 含 `@` | assign 直接禁止；gacc 按最后一个 @ 切，本可容忍 | assign:69-70；gacc:155 |
| 含 `%`/空格 | proxy.conf 同时被当 URL（curl --proxy）和按冒号拆分（user.js）两种语义使用，未 percent-encode → curl 端错乱、Firefox 端收原文，两端不一致 | assign:170；gacc:310,360,372 vs 183-188 |
| 含 `"` / `\` | 未转义插入 user.js 的 JS 字符串 → 语法破坏甚至任意 pref 注入 | gacc:187-188 |
| 非 ASCII | SOCKS5 凭据是字节流，两端编码未约定 | gacc:187-188 |

明文风险：proxy.conf 600（gacc:170）、user.js 有 600 兜底（gacc:260-262），但 **prefs.js 由 Firefox 按 umask 重写（通常 644），密码对同机其他用户可读**；且 `gacc list` 与状态输出把 proxy.conf 含密码全文打到终端/scrollback（gacc:272-280, 482, 562）。评价：中高危。

## 3. `--check` 3 次采样：不可靠

- 每连接随机轮换、池 k 个出口时，3 次全同概率 = k^(−2)（k=2 → 25% 漏判）。95% 置信检出切换概率 p 需 n ≥ 1+ln0.05/ln(1−p)：p=0.5 → 6 次，p=0.3 → 10 次。
- 更致命：3 次背靠背无间隔（assign:169-176），按时间轮换（如每 60s 换节点）必漏判。
- 更稳的方式：① 加 sleep 间隔采 8-10 次；② 直接查代理客户端分组策略（url-test/load-balance/round-robin）代替黑盒采样；③ 并发多连接对比出口。

## 4. `--render`：是，只渲染不启动

gacc:462-468 在启动逻辑（474 行之后）之前 exit；prepare_profile 只写文件（gacc:231-264）。但"纯渲染"≠零写：`--proxy` 已落盘 proxy.conf（gacc:413），prepare_profile 还会探测 unshare（gacc:240）并在沙箱恢复时 sed -i 改 prefs.js（gacc:244-248）。

## 5. 错误处理：不完整

| 缺口 | 依据 |
|---|---|
| `--accounts a-b` 不校验数字，非数字进 `(( ))` 报错难读，且 bash 算术间接求值有注入面 | assign:88-90 |
| 重复端口不去重，静默接受 | assign:80-83 |
| 有 user 缺 pass → 静默写 `user:@host` 空密码；只有 pass 无 user → 密码被静默丢弃 | assign:105-107 |
| gacc 失败仅 warn 继续，结尾仍打印"完成"且 exit 0，失败原因被 >/dev/null 吞掉 | assign:157-159, 199-202 |
| 相反 `--sync-tz` 循环在 pipefail 下 gacc 一失败就 set -e 中止，跳过其余账户且无总结——两种失败策略自相矛盾 | assign:26, 192；gacc:470 |
| `port=${spec##*:}` 在密码含 `:` 时显示错端口 | assign:131 |

## 6. 结论

**保留**：粘性分配与"渲染不启动"的设计正确，修掉凭据转义、失败传播、采样判定三处即可投用。
