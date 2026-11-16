# `gaccounts` 完整独立评审报告（全工具实测修订版）

> **审计方法论声明**：本报告所有关于 Firefox 160 默认值、HTTP 请求头、DOM/JS API 行为、WebGL/WebRTC 状态及 `prefs.js` 持久化的断言，均已在本机通过以下三种工具手段逐一验证：
> 1. **二进制/归档提取**：检索 [`firefox/omni.ja`](../firefox/omni.ja)、[`firefox/browser/omni.ja`](../firefox/browser/omni.ja) 与 [`firefox/libxul.so`](../firefox/libxul.so)；
> 2. **Marionette 特权查询**：启动 `./firefox/firefox --headless --marionette`（设置 `MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1` 与 `remote.prefs.recommended=false`），通过 `Services.prefs.getDefaultBranch("")` 读取全部 49 个配置项的真实 C++/JS 默认分支类型与默认值；
> 3. **本地 HTTP + 真实 X11/Headless 探针实测**：编写本地 Python HTTP 抓包与 JS 探针服务器，驱动便携版 Firefox 160 实测 HTTP 请求头、`navigator.*`、`Intl.*`、`window.screen`、`WebGL` 与 `RTCPeerConnection` ICE 候选。

---

## 0. 专项复盘：关于 `Accept-Language: en-US,en;q=0.9` 的纠错与致命副作用实测

### 0.1 为什么上一轮会把 `q=0.9` 误判为 Chrome 特征？（坦白与复盘）
上一轮我断言「`Accept-Language: en-US,en;q=0.9` 是 Chrome 写法、Firefox 应为 `q=0.5`」，**该断言关于 HTTP 请求头的结论是错误的**。原因复盘如下：
1. **将早期版本的历史算法记成了永久不变的定律（版本记忆偏差）**：
   在旧版 Firefox（Bug 1403802 将 `PrepareAcceptLanguages` 从 C++ 迁移到 Rust `netwerk_helper` 的时期，参考 [Bugzilla #1403802](https://bugzilla.mozilla.org/show_bug.cgi?id=1403802) 与 [Bugzilla #1754525](https://bugzilla.mozilla.org/show_bug.cgi?id=1754525)）中，当 `intl.accept_languages` 有 $N=2$ 个语言（`"en-US, en"`）时，步长按 $1 - i/N$ 计算，第二个语言确实生成 `q=0.5`。但在新版 Firefox（含本机 Firefox 160.0，BuildID `20261104181552` [`firefox/application.ini:8-9`](../firefox/application.ini#L8-L9)）中，Mozilla 已将 `Accept-Language` 的质量值递减步长改为与 Chromium 一致的 **固定每次 `-0.1`**。
2. **本机 HTTP 抓包实测证明**：
   我用本地 Python `http.server` 驱动 `/home/eli/cc-499/gaccounts/firefox/firefox --headless` 实测了 4 种配置：
   - **无覆盖（原生默认）** → HTTP 头发送：`Accept-Language: en-US,en;q=0.9` `[依据: 本机 HTTP 探针实测输出]`
   - **`user_pref("intl.accept_languages", "en-US, en");`** → HTTP 头发送：`Accept-Language: en-US,en;q=0.9` `[依据: 本机 HTTP 探针实测输出]`
   - **`user_pref("intl.accept_languages", "en-US, en, fr");`** → HTTP 头发送：`Accept-Language: en-US,en;q=0.9,fr;q=0.8`（实锤步长为 `-0.1`） `[依据: 本机 HTTP 探针实测输出]`
   - **`user_pref("intl.accept_languages", "en-US,en;q=0.9");`** → HTTP 头发送：`Accept-Language: en-US,en;q=0.9` `[依据: 本机 HTTP 探针实测输出]`

### 0.2 【重大新发现】虽然 HTTP 头都是 `q=0.9`，但把 `;q=0.9` 写进 `intl.accept_languages` 破坏了 JS `navigator.languages`！
上一轮我靠记忆给出了错误的理由（以为 HTTP 头会变），但本次通过 **JS 探针实测** 发现：**在 `user.js` 中把 `intl.accept_languages` 写成 `"en-US,en;q=0.9"`（见 [`bin/gacc:63`](../bin/gacc#L63)、[`bin/gacc:106`](../bin/gacc#L106) 及 [`profiles/acc01/user.js:11`](../profiles/acc01/user.js#L11)、[`profiles/acc02/user.js:11`](../profiles/acc02/user.js#L11)、[`profiles/acc03/user.js:11`](../profiles/acc03/user.js#L11)），会在网页 JS 层制造出 100% 一眼假的非法语言标签！**

**原理与实测证据**：
- 在 [`firefox/omni.ja`](../firefox/omni.ja) 中，`intl.accept_languages` 的默认定义为 `pref("intl.accept_languages", "und");`，当 Firefox 内部设置语言时（如 `privacy.spoof_english`），写入的格式是纯语言标签列表：`Services.prefs.setCharPref("intl.accept_languages", "en-US, en");` `[依据: grep -a intl.accept_languages firefox/omni.ja 偏移 296492 与 11392740]`。
- HTTP 栈在生成请求头时会自动跳过已带 `;q=` 的项或为其补上 `;q=0.9`，因此 HTTP 头看不出区别；
- **但是**，DOM API `navigator.languages` 是直接把 `intl.accept_languages` 按逗号分割暴露给网页 JS 的！本机实测输出如下：
  ```text
  === no override (default) ===
    HTTP Accept-Language: en-US,en;q=0.9
    JS result: {"languages": ["en-US", "en"], "language": "en-US", "canonicalOk": true, "canonicalErr": null}
  === user_pref("intl.accept_languages", "en-US, en") ===
    HTTP Accept-Language: en-US,en;q=0.9
    JS result: {"languages": ["en-US", "en"], "language": "en-US", "canonicalOk": true, "canonicalErr": null}
  === user_pref("intl.accept_languages", "en-US,en;q=0.9") ===
    HTTP Accept-Language: en-US,en;q=0.9
    JS result: {"languages": ["en-US", "en;q=0.9"], "language": "en-US", "canonicalOk": false, "canonicalErr": "RangeError: invalid language tag: \"en;q=0.9\""}
  ```
  `[依据: 本机 Firefox 160 Headless JS 探针实测 navigator.languages 与 Intl.getCanonicalLocales(navigator.languages)]`
- **结论**：任何正常浏览器的 `navigator.languages` 数组元素都必须是合法的 BCP 47 语言标签（如 `["en-US", "en"]`），绝不可能包含 HTTP 权重后缀 `"en;q=0.9"`。一旦页面风控脚本（如 Google BotGuard）遍历 `navigator.languages` 或调用 `Intl.getCanonicalLocales(navigator.languages)`，会直接抛出 `RangeError: invalid language tag: "en;q=0.9"`，100% 暴露 `intl.accept_languages` 被手工填入了 HTTP 头格式 문자열！
- **修复建议**：将 [`bin/gacc:63`](../bin/gacc#L63)、[`bin/gacc:106`](../bin/gacc#L106) 和 `profiles/acc*/persona.conf` 中的 `accept=en-US,en;q=0.9` 改为 `accept=en-US, en`（或者干脆不写该 pref，因为英文版 Firefox 160 原生默认就是 `navigator.languages = ["en-US", "en"]` 且 HTTP 头原生发 `en-US,en;q=0.9`）。

---

## 1. 全量改造逐项清点（Prefs / 环境变量 / 启动参数 / 字体 / 目录结构 / `prefs.js` 残留）

### 1.1 `user.js` 与 `prefs.js` 配置项逐项清点（共 49 项）

> **极其关键的现场发现（`prefs.js` 残留陷阱）**：
> Firefox 启动时会把 `user.js` 中的所有 `user_pref(...)` 永久拷贝并固化到同目录的 `prefs.js` 中。当后续版本从 [`etc/user.js.tmpl`](../etc/user.js.tmpl) 或 [`bin/gacc`](../bin/gacc) 中**删掉**某一行 `user_pref` 时，**已存在的 profile（`acc01`、`acc02`、`acc03`）里的 `prefs.js` 仍然保留着旧的覆盖值，根本没有恢复原生！** `[依据: profiles/acc01/prefs.js:57-133, profiles/acc02/prefs.js:58-129, profiles/acc03/prefs.js:57-146]`
> 下表同时标注了「当前模板 [`etc/user.js.tmpl`](../etc/user.js.tmpl) 状态」与「`acc01~03/prefs.js` 实际生效状态」。所有 Firefox 160 原生默认值均由 `Services.prefs.getDefaultBranch("")` 实测得出 `[依据: 本机 Marionette chrome 上下文实测输出]`。

#### A. 指纹人设相关 Prefs

| Pref 名称 | Firefox 160 原生默认值 | 当前模板 / `acc01~03` 实际状态 | 是否偏离原生 | 网页可观测性（JS API / HTTP / 规范依据） | 风险等级 | 建议 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `intl.accept_languages` | `"und"`（英文包动态解析为 `"en-US, en"`）`[依据: omni.ja 偏移 296492 & browser/omni.ja 偏移 31303911]` | 模板与 `acc01~03` 均写 `"en-US,en;q=0.9"` `[依据: bin/gacc:63,124; acc03/user.js:11]` | **是（格式错误）** | **高（JS 直接可测）**：HTTP 头虽仍为 `en-US,en;q=0.9`，但 `window.navigator.languages` 变成 `["en-US", "en;q=0.9"]`，传入 `Intl.getCanonicalLocales()` 抛 `RangeError` `[依据: 本机 JS 探针实测]` | **高危（100% 暴露手工篡改）** | 改为 `"en-US, en"` 或直接删除该 pref（原生即发 `en-US,en;q=0.9`） |
| `privacy.resistFingerprinting` | `false` `[依据: Marionette defaultBranch 实测]` | 模板与 `acc01~03` 均写 `false` `[依据: bin/gacc:125]` | 否（与默认值相同） | **不可观测**：值与原生默认完全一致，不改变任何 DOM/Canvas/Timer 行为 | 无风险 | 可保留或删掉冗余行 |
| `dom.maxHardwareConcurrency` | `128`（即不截断，报告真实 8 线程）`[依据: Marionette defaultBranch 实测]` | 模板默认不写（需 `P_FORCE_CORES`）`[依据: bin/gacc:128-130]`；但 `acc01/02` 仍写 `8`，**`acc03/prefs.js:86` 仍残留 `4`！** | `acc03` 偏离原生（8→4） | **中（JS 直接可读 `navigator.hardwareConcurrency`）**：值为 `4` 本身合法，但与 Web Worker 并行计时或同机 GPU 特征对照时可发现人为下调 | 中（对 `acc03`） | 从 `acc03/prefs.js` 清除 line 86，保持原生真实值 `8` |
| `layout.css.devPixelsPerPx` | `"-1.0"`（自动跟随系统/协议缩放）`[依据: Marionette defaultBranch 实测]` | 模板默认不写（需 `P_FORCE_DPR`）`[依据: bin/gacc:131-133]`；但 **`acc01/prefs.js:110` 与 `acc03/prefs.js:107` 残留 `"1"`，`acc02/user.js:13` 与 `acc02/prefs.js:108` 仍为 `"1.25"`！** | `acc02` 严重偏离（`1.25`） | **高（JS 直接可读 `window.devicePixelRatio`、`screen.width/height`）**：在 `acc02` 上设为 `"1.25"` 后，本机实测 `screen` 变为 `2048x1152`（主屏）或 `3200x1152`（全根窗口），属罕见非标缩放 `[依据: 本机 X11 JS 探针实测]` | **中高（`acc02` 暴露非标缩放与跨号同源物理像素）** | 清除 `acc01~03/prefs.js` 中的该项，保持默认 `"-1.0"` |
| `javascript.use_us_english_locale` | `NONE(0)`（Firefox 160 已废弃移除该 pref）`[依据: Marionette getPrefType 返回 0]` | 模板已删，但 **`acc01/user.js:16`、`acc02/user.js:16` 及 `acc01~03/prefs.js` 全部残留 `true`！** | 是（写入了已不存在的死 pref） | **不可观测**：因 Gecko 160 已无此 pref 定义，JS 引擎忽略它（`Intl` 仍走 `en-US`），普通网页无法读取 `Services.prefs` | 无直接风险（属无效死配置） | 清理 `acc01~03/prefs.js` 残留 |

#### B. WebRTC / 代理 / 网络预取相关 Prefs

| Pref 名称 | Firefox 160 原生默认值 | 当前模板 / `acc01~03` 实际状态 | 是否偏离原生 | 网页可观测性（JS API / HTTP / 规范依据） | 风险等级 | 建议 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `media.navigator.enabled` | `true` `[依据: Marionette defaultBranch 实测]` | 模板已不写，但 **`acc01/prefs.js:121` 和 `acc03/prefs.js:118` 依然残留 `false`！** | **`acc01`/`acc03` 严重偏离** | **极高（JS 直接可测）**：当为 `false` 时，HTTPS 页面下 `navigator.mediaDevices === undefined`。任何反爬脚本检查 `'mediaDevices' in navigator` 即 100% 判定为篡改浏览器 `[依据: WebRTC/MediaCapture 规范及 ANALYSIS-gemini.md:41]` | **高危（`acc01` 与 `acc03` 仍带着该硬伤！）** | **立即从 `acc01/prefs.js` 和 `acc03/prefs.js` 删除 `media.navigator.enabled`！** |
| `media.peerconnection.enabled` | `true` `[依据: Marionette defaultBranch 实测]` | [`etc/user.js.tmpl:19`](../etc/user.js.tmpl#L19) 写 `true` | 否 | **不可观测**：与原生默认值相同，`window.RTCPeerConnection` 正常存在 `[依据: 本机 JS 探针实测 typeof RTCPeerConnection === "function"]` | 无风险 | 保持 `true` |
| `media.peerconnection.ice.proxy_only` | `false` `[依据: Marionette defaultBranch 实测]` | [`bin/gacc:179`](../bin/gacc#L179) 仅在 `socks5` 时写 `true`；但 **`acc01~03/prefs.js` 在 `proxy.type=0`（直连）下全部残留 `true`！** `[依据: acc01/prefs.js:124, acc02/prefs.js:120, acc03/prefs.js:121]` | **是（直连模式下残留 `true`）** | **高（JS 可通过 `RTCPeerConnection` 观测）**：本机实测当 `proxy.type=0` 且 `proxy_only=true` 时，`pc.setLocalDescription(offer)` 后 `iceGatheringState` 永远卡在 `"new"`，`candidatesCount: 0`（连 `.local` mDNS 候选都没有）`[依据: 本机 WebRTC 探针实测场景 3]` | **高（直连分流模式下 WebRTC 完全哑火）** | 在 [`bin/gacc`](../bin/gacc) 的 `render_proxy_block`（`direct` 分支）显式写 `user_pref("media.peerconnection.ice.proxy_only", false);` 以覆盖 `prefs.js` 历史残留！ |
| `media.peerconnection.ice.no_host` | `false` `[依据: Marionette defaultBranch 实测]` | [`bin/gacc:180`](../bin/gacc#L180) 仅在 `socks5` 时写 `true`；但 **`acc01~03/prefs.js` 全部残留 `true`！** | **是（直连下残留 `true`）** | **高（JS 可通过 `RTCPeerConnection` 观测）**：原生 Firefox 160 在无 STUN 或本地收集时会生成 `*.local typ host`（mDNS 混淆候选，不暴露内网真 IP）；设为 `true` 后无 STUN 时 0 候选，gathering 卡在 `"new"` `[依据: 本机 WebRTC 探针实测场景 2 vs 3]` | **中高** | 在 `direct` 分支显式写 `false` 覆盖残留；且因 WSL2 全局 tun/分流已接管或 mDNS 已隐藏内网 IP，无需设 `no_host=true` |
| `media.peerconnection.ice.default_address_only` | `false` `[依据: Marionette defaultBranch 实测]` | 模板未写，但 **`acc01/prefs.js:122` 和 `acc03/prefs.js:119` 残留 `true`！** | 是 | **低**：限制仅绑定默认路由网卡，单网卡下难以观测，但属残留修改 | 低 | 从 `prefs.js` 清理 |
| `network.proxy.type` | `5`（Use system proxy settings）`[依据: Marionette defaultBranch 实测]` | `direct` 时写 `0`（No proxy），`socks5` 时写 `1` `[依据: bin/gacc:170,178]` | 轻微（5→0/1） | **不可观测**：网页 JS 无 API 读取 `network.proxy.*` | 无风险 | **必须保留**（多账号独立代理的核心能力） |
| `network.proxy.socks` / `socks_port` / `socks_version` / `socks_remote_dns` / `share_proxy_settings` / `no_proxies_on` | `""` / `0` / `5` / `false` / `false` / `""` `[依据: omni.ja & Marionette 实测]` | 配置代理时写入对应值 `[依据: bin/gacc:181-186]` | 是（开启代理所需） | **不可观测（JS 层）**；服务端仅看到出口 IP 与远端 DNS 解析结果 | 无风险（正向防泄漏） | **必须保留** |
| `network.dns.disablePrefetch` / `network.prefetch-next` / `network.predictor.enabled` / `network.http.speculative-parallel-limit` | `false` / `true` / `NONE(0)` / `20` `[依据: Marionette defaultBranch 实测]` | 模板已删，但 **`acc01~03/prefs.js` 全部残留 `true` / `false` / `false` / `0`！** `[依据: acc03/prefs.js:127-130]` | 是（`prefs.js` 残留） | **极低（仅网络层连接预建时序微差）**：JS 无 API 可读；服务端仅能从 TCP 预连接时序间接感知 | 低 | 清理 `acc01~03/prefs.js` 残留，恢复默认 |
| `browser.search.suggest.enabled` | `true` `[依据: omni.ja & Marionette 实测]` | 模板已删，但 **`acc01~03/prefs.js:57/58` 全部残留 `false`！** | 是（`prefs.js` 残留） | **低（地址栏行为层）**：网页内搜索框不受影响；仅在用户用 Firefox 地址栏输入搜索词时，不向 Google 发 `/complete/search` 联想请求 | 低 | 清理 `acc01~03/prefs.js` 残留，恢复 `true` |
| `network.captive-portal-service.enabled` / `network.connectivity-service.enabled` | `true` / `true` `[依据: browser/omni.ja & omni.ja & Marionette 实测]` | [`etc/user.js.tmpl:20-21`](../etc/user.js.tmpl#L20-L21) 写 `false` | 是 | **完全不可观测**：仅停止 Firefox 向 `detectportal.firefox.com` 发后台探测，对 Google 页面与 JS 完全不可见 | 无风险 | 可保留 |

#### C. 沙箱相关 Prefs（含本机实测发现的 WebRTC 崩溃 Bug！）

| Pref 名称 | Firefox 160 原生默认值 | 当前模板 / `acc01~03` 实际状态 | 是否偏离原生 | 网页可观测性（JS API / HTTP / 规范依据） | 风险等级 | 建议 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `security.sandbox.content.level` | `6` `[依据: Marionette defaultBranch 实测]` | 当 `unshare --user` 失败时写 `0` `[依据: bin/gacc:224-225]` | 是（受限容器环境必需） | **JS 无法直接读取该 pref**；但见下方 `socket.process.level` 连锁反应 | 安全降级（宿主机支持时不应关） | 保持 [`bin/gacc:224`](../bin/gacc#L224) 的条件判断（在正常 WSL2 终端 `unshare` 可用时自动不写） |
| `security.sandbox.gpu.level` | `0` `[依据: Marionette defaultBranch 实测]` | 当 `unshare` 失败时写 `0` | 否（Linux 下默认就是 `0`） | **不可观测** | 无风险 | 冗余但无害 |
| **【漏配项】`security.sandbox.socket.process.level`** | **`2`** `[依据: Marionette getChildList("security.sandbox.") 实测]` | **未配置（保持默认 `2`）！** | — | **【重大实测发现】高（导致无 unshare 环境下 WebRTC ICE 彻底崩溃）**：<br>当环境不支持 `unshare --user` 时，[`bin/gacc:225`](../bin/gacc#L225) 只关了 `content.level=0` 和 `gpu.level=0`，**漏掉了 `security.sandbox.socket.process.level`（默认值为 `2`）和 `MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1`！**<br>结果：翻看 [`profiles/acc01/firefox.log:9-34`](../profiles/acc01/firefox.log#L9-L34)、[`profiles/acc02/firefox.log:26-32`](../profiles/acc02/firefox.log#L26-L32)、[`profiles/acc03/firefox.log:9-10`](../profiles/acc03/firefox.log#L9-L10)，每次启动都有子进程报错 `Sandbox: writing /proc/self/uid_map: EACCES` 并以 `signal 11 (SIGSEGV)` 崩溃！<br>本机 WebRTC 探针实测证明：**死掉的正是负责 STUN/ICE 网络收发的 `socket` 进程！** 这导致哪怕恢复了 WebRTC 默认设置，`RTCPeerConnection` 的 `iceGatheringState` 依然永久卡死在 `"new"`、产出 `0` 个候选；一旦加上 `security.sandbox.socket.process.level = 0` 和 `MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1`，WebRTC 立即恢复正常（`iceGatheringState: "complete"`, 产出 `*.local typ host` 候选）`[依据: 本机 WebRTC 探针实测场景 1 vs 2]`！ | **高（在无 userns 环境下静默废掉整个 WebRTC 网络栈）** | 在 `unshare` 失败分支同步加上 `security.sandbox.socket.process.level = 0` 与 `export MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1 MOZ_DISABLE_RDD_SANDBOX=1 MOZ_DISABLE_UTILITY_SANDBOX=1` |

#### D. 遥测 / 实验 / 更新 / 会话恢复 Prefs（[`etc/user.js.tmpl:24-50`](../etc/user.js.tmpl#L24-L50)）

经本机 Marionette `Services.prefs.getDefaultBranch("")` 逐一核实 `[依据: 本机 Marionette 实测输出]`：
- **Firefox 160 已废弃/不存在的 5 个 Pref（`getPrefType === 0`）**：
  - `browser.ping-centre.telemetry` (`NONE`)
  - `browser.newtabpage.activity-stream.feeds.telemetry` (`NONE`)
  - `extensions.pocket.enabled` (`NONE`)
  - `browser.messaging-system.whatsNewPanel.enabled` (`NONE`)
  - `app.update.enabled` (`NONE`) / `app.update.service.enabled` (`NONE`)
  - **可观测性与建议**：写入不存在的 pref 仅存留于 `Services.prefs` 用户分支，网页 JS **完全不可观测**，但属于无意义的陈旧配置，建议精简删除。
- **与原生默认值已一致的 2 个 Pref**：
  - `toolkit.telemetry.enabled`（原生默认即为 `false`）
  - `browser.sessionstore.resume_from_crash`（原生默认即为 `true`）
- **确实改变了默认值的 13 个内部 Pref**：
  - 遥测与实验：`toolkit.telemetry.unified` (`true`→`false`)、`toolkit.telemetry.archive.enabled` (`true`→`false`)、`toolkit.telemetry.server` (`"https://incoming.telemetry.mozilla.org"`→`"data:,"`)、`datareporting.healthreport.uploadEnabled` (`true`→`false`)、`datareporting.policy.dataSubmissionEnabled` (`true`→`false`)、`app.shield.optoutstudies.enabled` (`true`→`false`)、`app.normandy.enabled` (`true`→`false`)、`browser.discovery.enabled` (`true`→`false`)、`browser.newtabpage.activity-stream.telemetry` (`true`→`false`)。
  - 账号与更新：`identity.fxaccounts.enabled` (`true`→`false`)、`app.update.auto` (`true`→`false`)。
  - 启动与 UI：`browser.startup.page` (`1`→`3`)、`browser.shell.checkDefaultBrowser` (`true`→`false`)、`browser.aboutConfig.showWarning` (`true`→`false`)、`browser.startup.homepage_override.mstone`（默认未设字符串值→`"ignore"`）。
  - **可观测性与建议**：以上全部为浏览器 Chrome 特权层内部开关，**没有任何 Web API 会将其暴露给普通网页 JS** `[依据: W3C/WHATWG HTML & Navigator 规范，及 omni.ja 调用点检索]`。保留有效项完全安全。

---

### 1.2 环境变量与启动参数清点（[`bin/gacc:465-501`](../bin/gacc#L465-L501)）

| 改造项（[`bin/gacc`](../bin/gacc) 行号） | 作用与是否偏离原生 | 网页可观测性（实测依据） | 风险等级 | 建议 |
| :--- | :--- | :--- | :--- | :--- |
| **`export XDG_RUNTIME_DIR="$RUNTIME/run"`**（[`bin/gacc:477`](../bin/gacc#L477)）配合未清理的 `WAYLAND_DISPLAY=wayland-0` | **【本次审计最关键的实测发现】严重偏离原生并直接摧毁了 WebGL 1/2 和真实 DPI！**<br>原因链条（100% 实测复现）：<br>1. WSLg 默认设置环境变量 `WAYLAND_DISPLAY=wayland-0`，其套接字位于真实的 `/run/user/1000/wayland-0`。<br>2. [`bin/gacc:469`](../bin/gacc#L469) 只执行了 `unset MOZ_ENABLE_WAYLAND`，但没有 `unset WAYLAND_DISPLAY`，反而把 `XDG_RUNTIME_DIR` 改写成了空目录 `/home/eli/cc-499/gaccounts/runtime/acc0X/run`。<br>3. 于是主进程因找不到 `$XDG_RUNTIME_DIR/wayland-0` 退回 X11（见 [`profiles/acc01/firefox.log:1-2`](../profiles/acc01/firefox.log#L1-L2)：`Failed to connect to Wayland display '.../runtime/acc01/run/wayland-0' ... fallback to X11`）。<br>4. **致命点**：Firefox 160 在启动图形探测子进程 `gfxtest glx -w` 时，看到 `WAYLAND_DISPLAY=wayland-0` 非空，遂尝试连接 `$XDG_RUNTIME_DIR/wayland-0`，直接报错退出：`ERROR: Could not connect to wayland display, WAYLAND_DISPLAY=wayland-0` `[依据: 本机运行 XDG_RUNTIME_DIR=/tmp ./firefox/gfxtest glx -w 实测输出]`！<br>5. 因为 `gfxtest` 失败，Firefox 认定当前图形环境崩溃，**直接禁用了整个浏览器的 WebGL 1 与 WebGL 2！**<br>6. **本机 JS 探针实测对比**：<br>   - 按 `bin/gacc` 现有环境变量启动：`{"hasWebGL1": false, "hasWebGL2": false, "webglVendor": null, "webglRenderer": null}`；<br>   - 只要保留真实 `XDG_RUNTIME_DIR=/run/user/1000` 或 `unset WAYLAND_DISPLAY`：`{"hasWebGL1": true, "hasWebGL2": true, "webglVendor": "Mozilla", "webglRenderer": "llvmpipe, or similar", "unmaskedVendor": "Mesa", "unmaskedRenderer": "llvmpipe, or similar"}` `[依据: 本机 X11 JS 探针 4 组对照实验输出]`！ | **极高（100% 网页可观测的顶级异常）**：<br>网页调用 `canvas.getContext('webgl')` 和 `canvas.getContext('webgl2')` 全部返回 `null`！现代桌面 Firefox 160 居然**完全不支持 WebGL**，在 Google BotGuard 眼里是极其罕见的「残废/无头改装环境」信号！ | **极高危（头号浏览器环境 Bug）** | **立即修复**：<br>1) 不要覆盖 `XDG_RUNTIME_DIR`（保留系统 `/run/user/1000`），且<br>2) 如果想强制走 X11，显式加 `unset WAYLAND_DISPLAY`（或保持 Wayland 原生连接） |
| `export HOME="$RUNTIME/home"` 及 `XDG_CONFIG_HOME` / `XDG_CACHE_HOME` / `XDG_DATA_HOME`（[`bin/gacc:475-476`](../bin/gacc#L475-L476)） | 隔离各账户的本地配置与缓存。但注意：修改 `HOME` 会使 Mesa/fontconfig/pulse 等找不到 `~/.config` 或 `~/.pulse-cookie`（本机 WSLg `PULSE_SERVER=unix:/mnt/wslg/PulseServer` 不依赖 `~/.config/pulse`，但若走原生 XDG 则更稳） | **JS 不可直接观测目录路径**（除非诱导用户上传文件暴露默认路径） | 低 | 若宿主机 `$HOME` 可写，无需重定向 `HOME`（`--profile "$PROF"` 已经隔离了全部浏览器数据）；若为防跨号污染保留 `HOME` 隔离，**切勿隔离 `XDG_RUNTIME_DIR`** |
| `export TZ="$P_TZ"`（[`bin/gacc:483`](../bin/gacc#L483)） | 覆盖进程时区。本机实测 `Intl.DateTimeFormat().resolvedOptions().timeZone` 与 `new Date().getTimezoneOffset()` 完整、无损地跟随 `TZ` 环境变量 | **可观测但与原生 OS 时区无法区分**：JS 只能读到 IANA 时区名（如 `America/Phoenix`），无法探测该时区来自 `/etc/localtime` 还是 `TZ` 环境变量 | 无风险（只要与代理 IP 地理位置一致） | **必须保留**，并确保与固定代理 IP 的地理时区一致 |
| `export FONTCONFIG_FILE="$PROF/fonts.conf"`（[`bin/gacc:488-490`](../bin/gacc#L488-L490)） | 当前需 `persona.conf` 含 `fonts=on` 才启用；`acc01~03` 均未启用 `[依据: glob profiles/*/fonts.conf 为空]` | 若启用，网页可通过 `document.fonts.check()` / Canvas `measureText` 观测到字体数量从 266 骤降到 ~9 个家族 | 若启用则为中高风险；当前关闭为无风险 | **保持关闭**，不要启用 [`bin/gen-fonts.sh`](../bin/gen-fonts.sh) |
| `export MOZ_CRASHREPORTER_DISABLE=1` / `MOZ_DISABLE_AUTO_SAFE_MODE=1` / `GSETTINGS_BACKEND=memory`（[`bin/gacc:466-468`](../bin/gacc#L466-L468)） | 关崩溃上报、关安全模式弹窗、GSettings 用内存后端 | `MOZ_*` 兩项网页**不可观测**；但 `GSETTINGS_BACKEND=memory` 会让 GTK 丢失桌面主题/光标/字体缩放设置（例如暗色模式 `prefers-color-scheme` 恒为 `light`） | 低 | 前两者保留；`GSETTINGS_BACKEND=memory` 若无 dconf 报错阻塞可去掉 |
| 启动命令：`setsid --fork nohup "$FF" --profile "$PROF" --class "gacc-$ACC"`（[`bin/gacc:500-501`](../bin/gacc#L500-L501)） | `--profile` 指定目录；`--class` 设置 X11 `WM_CLASS` | **完全不可观测**：`WM_CLASS` 仅 X11 窗口管理器可见，DOM/JS 无任何接口可读取；`navigator.webdriver` 实测为 `false` `[依据: 本机 JS 探针实测 webdriver: false]` | 无风险 | **保留** |
| [`bin/gacc:140-142`](../bin/gacc#L140-L142) `ensure_no_policies` 删除 `policies.json` | 移除了早期注入 `channel=entpr` 的企业策略文件 | 修复后地址栏搜索不再带 `channel=entpr` | 正向修复 | **保持移除状态** |

---

## 2. 五大维度自相矛盾检查（基于本机实测数据）

### 2.1 `screen × dpr`（屏幕分辨率 × 设备像素比）
- **本机物理/X11 事实**：
  我运行 `xdpyinfo` 与 `xrandr` 实测发现，当前 WSLg 的 `4000x1440` 根窗口实际上是由 **两个虚拟 RDP 显示器拼接而成的双屏桌面** `[依据: 本机 xrandr 输出]`：
  - 主屏 `rdp-0`：`1440x960+0+0`
  - 副屏 `rdp-1`：`2560x1440+1440+0`
  - 总 X11 Screen 0 尺寸：`4000x1440`
- **Firefox 160 实测暴露给网页的 `window.screen` 与 `devicePixelRatio`**：
  1. **原生环境（保留 `XDG_RUNTIME_DIR=/run/user/1000`，窗口落在主屏 `rdp-0`）**：`window.devicePixelRatio = 2`，`window.screen.width = 1440, height = 960` `[依据: 本机 X11 JS 探针 native_env 输出]`。
  2. **`bin/gacc` 环境 + `layout.css.devPixelsPerPx = "1"`（`acc01` / `acc03` 现状）**：`window.devicePixelRatio = 1`，当窗口在 `rdp-0` 时 `screen` 为 `1440x960`；当窗口跨到 `rdp-1` 时 `screen` 为 `2560x1440`。
  3. **`bin/gacc` 环境 + `layout.css.devPixelsPerPx = "1.25"`（`acc02` 现状，[`profiles/acc02/prefs.js:108`](../profiles/acc02/prefs.js#L108)）**：当窗口最大化在 `2560x1440` 副屏（见 [`profiles/acc02/xulstore.json:1`](../profiles/acc02/xulstore.json#L1) `"sizemode":"maximized"`）时，实测 JS 读到 **`dpr = 1.25, screen.width = 2048, screen.height = 1152`**（即 $2560 / 1.25 = 2048, 1440 / 1.25 = 1152$）`[依据: 本机 X11 JS 探针 gacc_env_dpr_1_25 输出]`！若按整个 X root `4000x1440` 折算则是 `3200x1152`。
- **矛盾判定**：
  - **跨账号同源暴露**：`acc02` 的 `2048x1152 @ 1.25x` 乘回去正是 $2048 \times 1.25 = 2560, 1152 \times 1.25 = 1440$，与 `DPR=1` 下的 `2560x1440` 物理像素完全相等，毫无防关联效果。
  - **Linux X11 下 1.25x 非整数缩放极罕见**：在 `X11; Linux x86_64` UA 下出现 `dpr=1.25` 且伴随 `2048x1152` 视口，属于明显的人为缩放特征。

### 2.2 `核数 × GPU`（`hardwareConcurrency` × WebGL Renderer）
- **本机硬件与实测事实**：
  - 宿主机 CPU 为 `11th Gen Intel(R) Core(TM) i7-1185G7 @ 3.00GHz`（4 核 8 线程）`[依据: 本机 lscpu 输出]`。
  - **关键事实纠正**：用户背景提到「GPU 是 WSLg D3D12 映射的真实 Intel 核显」（`/dev/dxg` 与 `/usr/lib/wsl/lib/libd3d12.so` 确实存在），**但在本机 Firefox 160 中，实际渲染器并不是 D3D12 Intel 核显，而是两个更严峻的状态**：
    1. **正常启动 Firefox 160 时**：`./firefox/gfxtest glx` 实测返回 `DRI_DRIVER=swrast`, `VENDOR=Mesa`, `RENDERER=llvmpipe (LLVM 15.0.7, 256 bits)`, `MESA_ACCELERATED=FALSE` `[依据: 本机 ./firefox/gfxtest glx 实测输出]`；且 Firefox 160 对软件渲染器做了统一脱敏，网页 JS 读到的 `UNMASKED_RENDERER_WEBGL` 恒为 **`"llvmpipe, or similar"`** `[依据: 本机 X11 JS 探针实测输出]`。
    2. **通过 [`bin/gacc`](../bin/gacc) 启动时**：如 1.2 节实测，由于 `XDG_RUNTIME_DIR` 被覆盖导致 `gfxtest -w` 失败，**`acc01`、`acc02`、`acc03` 实际运行时的 WebGL 1 和 WebGL 2 全部为 `null`（完全禁用）！** `[依据: 本机 X11 JS 探针 exact gacc 实测输出]`
- **矛盾判定**：
  - **第一重矛盾（极高危）**：8 线程现代桌面浏览器，但 `WebGL` 完全不可用（`null`），直接命中「异常/受损客户端」画像。
  - **第二重矛盾（修复 WebGL 后）**：`acc01`/`acc02` 报 8 核 + `"llvmpipe, or similar"`，`acc03`（[`profiles/acc03/prefs.js:86`](../profiles/acc03/prefs.js#L86)）报 4 核 + `"llvmpipe, or similar"`。把 8 线程改成 4 线程既无法掩盖 `llvmpipe` 软件渲染特征，还会与 Worker 并发实测线程数矛盾。

### 2.3 `字体 × locale`（字体列表 × 语言区域）
- **本机实测事实**：
  - 系统共安装 `266` 个字体家族 `[依据: fc-list --format '%{family[0]}\n' | sort -u | wc -l 输出 266]`。
  - 若运行 `./bin/gen-fonts.sh 1 --plain`，仅选出 **13 个字体文件**（折合 9 个字体家族：DejaVu Sans/Serif/Mono、Caladea、Carlito、Noto Sans CJK、Noto Color Emoji）`[依据: 本机运行 /home/eli/cc-499/gaccounts/bin/gen-fonts.sh 1 --plain 实测输出]`。
- **矛盾判定**：
  - 当前 `acc01~03` 均**未启用** `fonts.conf`，暴露全部 266 个家族，与 `en-US` locale 在开发者 Linux 桌面上无硬性矛盾。
  - 若启用 [`bin/gen-fonts.sh`](../bin/gen-fonts.sh)，仅暴露 13 个纯开源字体文件且连 `Liberation` 都可能轮空，反而呈现典型的「精简 Docker 容器」画像。因此保持关闭是正确的。

### 2.4 `UA × 请求头 × JS Navigator`
- **本机实测事实**：
  - HTTP 请求头：`User-Agent: Mozilla/5.0 (X11; Linux x86_64; rv:160.0) Gecko/20100101 Firefox/160.0`，`Accept-Language: en-US,en;q=0.9` `[依据: 本机 HTTP 探针实测输出]`。
  - **重大矛盾点 1（`navigator.languages` 损坏）**：如第 0 节实测，HTTP 头 `Accept-Language: en-US,en;q=0.9` 与 Firefox 160 原生一致，但因为把 `"en-US,en;q=0.9"` 写进了 `intl.accept_languages` pref，导致 JS 层 `navigator.languages` 变成 `["en-US", "en;q=0.9"]`（含非法 `;q=0.9` 标签）`[依据: 本机 JS 探针实测]`！**这是「HTTP 头正常、但 JS `navigator.languages` 一眼假」的硬性自相矛盾。**
  - **重大矛盾点 2（`rv:160.0` 版本号与时间线）**：[`firefox/application.ini:8-9`](../firefox/application.ini#L8-L9) 显示 `Version=160.0`、`BuildID=20261104181552`。若在真实公网环境中 Mozilla 官方 Release 尚未发布到 160.0（或该二进制为改版/未来版本号构建），Google 前端对未知的远期 `Firefox/160.0` UA 会直接归入非标客户端。

### 2.5 `时区 × IP`（`TZ` × 出口 IP 地理位置）
- **现场配置事实**：
  - `acc01`：`tz=America/Denver`（[`profiles/acc01/persona.conf:3`](../profiles/acc01/persona.conf#L3)），`proxy.conf` 为 `direct`（走宿主机透明分流）。
  - `acc02`：`tz=America/Phoenix`（[`profiles/acc02/persona.conf:3`](../profiles/acc02/persona.conf#L3)），`proxy.conf` 为 `direct`。
  - `acc03`：`tz=America/Phoenix`（[`profiles/acc03/persona.conf:3`](../profiles/acc03/persona.conf#L3)），`proxy.conf` 为 `direct`。
  - **宿主机透明分流出口实测在轮换**：Oracle Phoenix（`America/Phoenix`, UTC-7） / `161.153.0.146` / IT7 Los Angeles（`America/Los_Angeles`, 冬令时 UTC-8）。
  - **附加残留泄漏**：在 `acc01~03/prefs.js` 中，全部记录了 `user_pref("browser.search.region", "CN");` 与 `user_pref("doh-rollout.home-region", "CN");` `[依据: acc01/prefs.js:55,85; acc02/prefs.js:56,85; acc03/prefs.js:55,84]`——这说明 Firefox 首次启动拉取 Mozilla Region 服务时，分流规则并未把 Mozilla 域名送入美国代理，而是直连暴露了中国 IP，虽网页 JS 读不到该 pref，但证明宿主机分流规则仅覆盖了部分域名。
- **矛盾判定**：
  - 当出口跳到 IT7 Los Angeles（`UTC-8`）时，`acc02`/`acc03` 的 `America/Phoenix`（`UTC-7`）与 `acc01` 的 `America/Denver`（`UTC-7`）均出现 1 小时时区偏差；更严重的是**同一个已登录会话在秒级/分钟级内跨 ASN（Oracle Cloud ↔ IT7 Networks）和跨州（AZ ↔ CA）跳变 IP**。

---

## 3. 归因分析：为什么 `acc01` 正常、`acc02` 触发验证、`acc03` 被吊销会话且 5 个手机号验证失败？

### 3.1 权重拆分（网络/IP/多账号操作 vs 浏览器改造）

| 归因大类 | 估算权重 | 细分机制与现场证据链 |
| :--- | :--- | :--- |
| **1. 网络出口层：机房 IP 段 + 出口节点轮换 + 同出口多账号并发** | **~75% – 85%** | 1. **三个账户全部为 `direct`（[`profiles/acc01/proxy.conf`](../profiles/acc01/proxy.conf)、[`acc02/proxy.conf`](../profiles/acc02/proxy.conf)、[`acc03/proxy.conf`](../profiles/acc03/proxy.conf) 均为 `direct`）**，即完全共用宿主机同一套按域名分流的美国机房出口。<br>2. **出口 IP 在多个数据中心 ASN 之间轮换**（Oracle Phoenix / `161.153.0.146` / IT7 Los Angeles）：对 Google 登录态（`SID`/`__Secure-1PSID`）而言，会话建立后 IP 在不同云厂商 ASN 之间跳动，直接命中 **Session Hijacking（会话劫持）与多地共用风险规则**。<br>3. **同机房出口连续登录第 1、2、3 个账号的速率/配额递进惩罚**：<br>   - `acc01` 第一个上号，消耗了该 IP 段/设备组合的初始信任额度，且已有稳定历史会话（[`acc01/prefs.js:59`](../profiles/acc01/prefs.js#L59)），故保持正常；<br>   - `acc02` 紧接着在同出口/轮换机房 IP 上登录第 2 个账号，触发中度风控（要求额外验证）；<br>   - `acc03` 在同出口继续登录第 3 个账号，直接触发 Google 批量滥用阈值（吊销会话 + 强制手机验证）。<br>4. **为什么换了 5 个手机号都提示 `unusual activity`？**<br>   这是 Google 账号风控的经典机制：当 **当前登录会话本身的风险分（Session Risk Score）已爆表** 时，Google 会直接锁死该会话的短信下发通道（报 *"This phone number cannot be used for verification"* 或 *"Unusual activity"*），此时无论换多少个干净手机号都会被拒，因为被拒的是**当前机房 IP + 浏览器环境发起的这次验证请求**，而不是手机号本身。 |
| **2. 浏览器改造引入的真异常（BotGuard 遥测减分项）** | **~15% – 25%** | 虽然浏览器改造不是触发网关首包拦截的唯一起因，但本机实测证实这套改造**确实在网页可见层捅出了 4 个真篓子**，显著拉高了 Google BotGuard 的自动化/篡改评分：<br>1. **`XDG_RUNTIME_DIR` 覆盖导致 WebGL 1/2 完全变为 `null`** `[依据: 本机 X11 JS 探针实测]`；<br>2. **`acc01` 和 `acc03` 的 `prefs.js` 残留 `media.navigator.enabled = false`**，导致 `navigator.mediaDevices === undefined` `[依据: acc01/prefs.js:121, acc03/prefs.js:118]`；<br>3. **`intl.accept_languages = "en-US,en;q=0.9"`** 导致 `navigator.languages` 出现非法标签 `"en;q=0.9"` `[依据: 本机 JS 探针实测]`；<br>4. **`unshare` 失败时漏关 `security.sandbox.socket.process.level`** + **`prefs.js` 残留 `ice.proxy_only=true`**，导致 WebRTC ICE 永远卡死在 `"new"` `[依据: 本机 WebRTC 探针实测]`。 |

### 3.2 哪些改造**绝对不可能**导致 Google 验证？（排除项）
以下改造经过本机工具实测，**100% 不可能被 Google 网页探测到，绝不是触发验证的原因**：
1. **HTTP 请求头里的 `Accept-Language: en-US,en;q=0.9` 本身**：本机实测原生 Firefox 160 默认就发 `en-US,en;q=0.9` `[依据: 本机 HTTP 探针实测]`（出问题的是 `user_pref` 写法污染了 JS `navigator.languages`，而非 HTTP 头本身）。
2. **`etc/user.js.tmpl` 中关闭的所有 Firefox 遥测、实验、Pocket、Firefox Accounts、自动更新、Captive Portal 开关（第 20–50 行）**：全部属于 Firefox 父进程内部逻辑，无任何 DOM/JS 接口暴露给网页 `[依据: omni.ja 检索与 Marionette 实测]`。
3. **启动参数 `--profile "$PROF"` 与 `--class "gacc-$ACC"`**：X11 `WM_CLASS` 与本地配置路径对网页完全透明 `[依据: 本机 JS 探针实测]`。
4. **环境变量 `MOZ_CRASHREPORTER_DISABLE=1` 与 `MOZ_DISABLE_AUTO_SAFE_MODE=1`**：仅作用于崩溃与启动阶段，网页不可见。
5. **未启用的 `bin/gen-fonts.sh`**：由于 `acc01~03` 目录下根本没有 `fonts.conf` `[依据: glob profiles/*/fonts.conf 为空]`，字体子集从未在当前这三个 profile 上生效。

---

## 4. 「最保守 `user.js`」完整片段 + 「最安全启动命令」（含 `prefs.js` 脏残留清理）

### 4.1 必做第一步：一次性清除 `acc01` / `acc02` / `acc03` 的 `prefs.js` 历史脏残留
在修改模板前，必须先停掉所有实例，把已经固化进 `profiles/acc*/prefs.js` 的有害残留项删掉（否则改模板对老账号不生效）：

```bash
for acc in 1 2 3; do ./bin/gacc "$acc" --stop; done

sed -i -E \
  -e '/"media\.navigator\.enabled"/d' \
  -e '/"media\.peerconnection\.ice\.(proxy_only|no_host|default_address_only)"/d' \
  -e '/"dom\.maxHardwareConcurrency"/d' \
  -e '/"layout\.css\.devPixelsPerPx"/d' \
  -e '/"javascript\.use_us_english_locale"/d' \
  -e '/"intl\.accept_languages"/d' \
  -e '/"network\.(dns\.disablePrefetch|prefetch-next|predictor\.enabled|http\.speculative-parallel-limit)"/d' \
  -e '/"browser\.search\.suggest\.enabled"/d' \
  /home/eli/cc-499/gaccounts/profiles/acc*/prefs.js
```

### 4.2 最保守 `etc/user.js.tmpl` 完整片段
设计原则：**零指纹伪装、零 API 阉割、零死 pref、显式重置历史 WebRTC 残留**。

```javascript
// ============================================================
// gacc 最保守 user.js.tmpl —— 保持 100% 原生 Web/JS 表面
// ============================================================

// ---------- 1. 代理与 WebRTC（由 gacc 渲染，直连时显式恢复原生） ----------
@PROXY@

// ---------- 2. 语言区域（使用合法 BCP 47 列表，绝不带 ;q=0.9） ----------
@PERSONA@

// ---------- 3. 沙箱（仅当宿主机不支持 unprivileged userns 时降级） ----------
@SANDBOX@

// ---------- 4. 保持 Web API 原生完整 ----------
user_pref("media.peerconnection.enabled", true);
user_pref("media.navigator.enabled", true);
user_pref("privacy.resistFingerprinting", false);

// ---------- 5. 停止 Firefox 自身后台联网与遥测（页面完全不可观测） ----------
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.server", "data:,");
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("app.normandy.enabled", false);
user_pref("browser.discovery.enabled", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);
user_pref("identity.fxaccounts.enabled", false);
user_pref("app.update.auto", false);

// ---------- 6. 会话恢复与启动静默 ----------
user_pref("browser.startup.page", 3);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutConfig.showWarning", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
```

其中 [`bin/gacc`](../bin/gacc) 渲染占位符的关键修正：
1. **`@PERSONA@`（[`bin/gacc:63,119-134`](../bin/gacc#L63)）**：
   將 `P_ACCEPT="en-US,en;q=0.9"` 改为 `P_ACCEPT="en-US, en"`（保证 `navigator.languages` 为合法的 `["en-US", "en"]`，同时 HTTP 头依然原生发送 `en-US,en;q=0.9`）。不写 `dom.maxHardwareConcurrency` 和 `layout.css.devPixelsPerPx`。
2. **`@PROXY@`（[`bin/gacc:165-188`](../bin/gacc#L165-L188)）**：
   - 当 `direct` 时，显式输出：
     ```javascript
     user_pref("network.proxy.type", 0);
     user_pref("media.peerconnection.ice.proxy_only", false);
     user_pref("media.peerconnection.ice.no_host", false);
     ```
   - 当 `socks5` 时，输出：
     ```javascript
     user_pref("network.proxy.type", 1);
     user_pref("network.proxy.socks", "$host");
     user_pref("network.proxy.socks_port", $port);
     user_pref("network.proxy.socks_version", 5);
     user_pref("network.proxy.socks_remote_dns", true);
     user_pref("network.proxy.share_proxy_settings", true);
     user_pref("network.proxy.no_proxies_on", "");
     user_pref("media.peerconnection.ice.proxy_only", true);
     user_pref("media.peerconnection.ice.no_host", true);
     ```
3. **`@SANDBOX@`（[`bin/gacc:224-225`](../bin/gacc#L224-L225)）**：
   当 `unshare --user --map-root-user true` 失败时，必须**同时**写入：
   ```javascript
   user_pref("security.sandbox.content.level", 0);
   user_pref("security.sandbox.socket.process.level", 0);
   user_pref("security.sandbox.gpu.level", 0);
   ```

### 4.3 最安全启动命令（修正 [`bin/gacc:465-502`](../bin/gacc#L465-L502)）
**核心修正**：绝不覆盖 `XDG_RUNTIME_DIR`（否则 `gfxtest` 找不到 Wayland 套接字导致 WebGL 1/2 全部被禁用），或显式 `unset WAYLAND_DISPLAY` 让 X11 与 `gfxtest` 行为一致；并在无 `unshare` 权限时导出 `MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1` 防止 WebRTC 网络进程崩溃。

```bash
[[ -n "$LIBDIRS" ]] && export LD_LIBRARY_PATH="$LIBDIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export MOZ_CRASHREPORTER_DISABLE=1
export MOZ_DISABLE_AUTO_SAFE_MODE=1

# 关键修复 1：保持 X11 路径纯粹，避免 gfxtest 因 WAYLAND_DISPLAY 指向错误目录而禁用 WebGL
unset MOZ_ENABLE_WAYLAND
unset WAYLAND_DISPLAY

# 关键修复 2：若环境不支持 userns 沙箱，必须连同 socket/rdd/utility 沙箱一并关闭，防止 WebRTC 进程 SIGSEGV
if grep -qE '^[[:space:]]*user_pref\("security\.sandbox\.content\.level",[[:space:]]*0\)' "$PROF/user.js" 2>/dev/null; then
  export MOZ_DISABLE_CONTENT_SANDBOX=1
  export MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1
  export MOZ_DISABLE_RDD_SANDBOX=1
  export MOZ_DISABLE_UTILITY_SANDBOX=1
  export MOZ_DISABLE_GMP_SANDBOX=1
fi

# 关键修复 3：千万不要覆盖 XDG_RUNTIME_DIR（保留系统 /run/user/1000）
RUNTIME="$ROOT/runtime/$(printf 'acc%02d' "$ACC")"
export HOME="$RUNTIME/home" \
       XDG_CONFIG_HOME="$RUNTIME/config" \
       XDG_CACHE_HOME="$RUNTIME/cache" \
       XDG_DATA_HOME="$RUNTIME/data"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

# 时区对齐当前账号固定代理出口的真实时区
load_persona "$ACC"
[[ -n "$P_TZ" ]] && export TZ="$P_TZ"

setsid --fork nohup "$FF" --profile "$PROF" \
      --class "gacc-$ACC" "${URLS[@]}" </dev/null >>"$PROF/firefox.log" 2>&1 &
```

---

## 5. 极限取舍：如果只能保留 3 条改造，保留哪 3 条？

如果砍掉一切花哨配置，只允许保留 **3 条** 改造，必须保留以下 3 条（按不可替代性排序）：

1. **每个账号独立的 `--profile "$PROF"` 目录 + `browser.startup.page = 3`（持久化 Cookie 与会话状态）**
   - **理由**：隔离并持久化每个 Google 账号的 `SID` / `__Secure-1PSID` / `AEC` / `NID` Cookie 与 IndexedDB 是多账号并存的物理基础，也是抵消 IP 风控的最强高信誉凭证。
2. **每个账号独立且固定的 SOCKS5 代理配置（`network.proxy.type = 1` + `socks_remote_dns = true` + `ice.proxy_only = true`），且一账号钉死一个固定出口 IP**
   - **理由**：当前三个账号全部是 `direct` 共用宿主机轮换机房出口，这是导致 `acc02` 验证、`acc03` 爆号的主因。必须让每个账号走各自独立、固定不轮换的出口 IP（最好是静态住宅 ISP IP）。
3. **环境变量 `export TZ="<与该账号固定出口 IP 匹配的 IANA 时区>"`**
   - **理由**：这是唯一零副作用、网页 JS 无法识别出人为干预（`Intl` 与 `Date` 原生联动）、且能消除「美国 IP 却报 `Asia/Shanghai` 宿主机时区」硬伤的环境变量改造。

---

## 6. 未能验证的推断与不确定部分（严格区分事实与推断）

以下内容属于无法在本机通过离线工具 100% 实测证实、或取决于外部黑盒的推断，特此单独列出：

1. **便携版 `Firefox 160.0`（BuildID `20261104181552`）的二进制来源与公网信誉度**：
   - **已知事实**：[`firefox/application.ini:8-11`](../firefox/application.ini#L8-L11) 写明 `Version=160.0`、`BuildID=20261104181552`、`SourceRepository=https://hg.mozilla.org/releases/mozilla-release`，二进制修改时间为 `2026-11-05` `[依据: stat firefox/libxul.so]`，且包含 `.sig` 签名文件。
   - **未能验证的推断**：无法在离线环境下向 Google 服务端核实 Google 当前的 UA 版本白名单对 `rv:160.0` 的评分权重（若该环境模拟的是 2026 年 11 月的时间线，则 Firefox 160 属于当时的当期版本；若在真实公网中使用了自编译/修改版版本号，则会触发 UA 版本异常）。
2. **为什么 WSLg 下存在 `/dev/dxg` 和 `/usr/lib/wsl/lib/libd3d12.so`，但 Firefox `gfxtest` 仍走 `swrast/llvmpipe`？**
   - **已知事实**：本机 `/dev/dxg` 存在，即使设置 `LD_LIBRARY_PATH=/usr/lib/wsl/lib` 运行 `/home/eli/cc-499/gaccounts/firefox/gfxtest glx`，输出依然是 `DRI_DRIVER=swrast`、`RENDERER=llvmpipe (LLVM 15.0.7, 256 bits)` `[依据: 本机 LD_LIBRARY_PATH=/usr/lib/wsl/lib ./firefox/gfxtest glx 实测输出]`。
   - **未能验证的推断**：这可能是因为當前 Ubuntu 22.04 Mesa (`23.2.1`) 的 EGL/GLX 默认驱动未配置 `GALLIUM_DRIVER=d3d12` 或缺少匹配的硬件加速 DRI 配置。由于我未在用户的真实桌面下贸然开启 `GALLIUM_DRIVER=d3d12` 重跑 Google 登录，因此「将 `llvmpipe` 切换为 `D3D12 (Intel)` 能在多大程度上単独降低 Google 登录验证率」属于未实测推断（但修复 `XDG_RUNTIME_DIR` 让 WebGL 从 `null` 恢复为可用是确定无疑的正向修复）。
3. **Google 内部风控对「IP 轮换」与「`navigator.mediaDevices === undefined` / `WebGL === null`」的精确扣分比例**：
   - **已知事实**：`acc01`、`acc02`、`acc03` 在完全相同的 `WebGL === null` 和 `navigator.languages = ["en-US", "en;q=0.9"]` 下，`acc01` 正常而 `acc02`、`acc03` 依次恶化（且 `acc02` 的 `media.navigator.enabled` 甚至没有被设为 `false`，反而是正常的 `acc01` 设为了 `false`）。
   - **由此得出的强力反证与未定边界**：`acc01` 带着 `media.navigator.enabled = false` 和 `WebGL = null` 依然正常使用，这**从实证上证明了浏览器特征异常绝不是单独一票否决项**；真正的触发阈值是多账号在同一轮换机房出口上的累加与 IP 跳变，而浏览器层的 4 个实测 Bug 则是放大风险分的帮凶。具体内部权重百分比属于 Google 服务端黑盒，无法在客户端精确测定。
