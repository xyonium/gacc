# 环境异常审计（argon / kimi / glm 三份交叉）

目标：清点所有手工改动，找出**会让浏览器显得不自然**的项，能还原的还原。
结论先行：清理掉的项**都不能证明**导致了 Google 验证；真正的主导因素仍是出口 IP
（机房段 + 多账号共用 + 实测节点还在轮换）。

## 一、改了什么（已生效）

| 项 | 之前 | 现在 | 依据 |
|---|---|---|---|
| `layout.css.devPixelsPerPx` | 强制 `1.25`（`screen` 报 3200x1152） | 默认不写，跟随真实环境 | kimi：1.25+4000x1440 是罕见组合，改比不改更糟 |
| `dom.maxHardwareConcurrency` | 强制 8 / 4 | 默认不写，用原生值 | kimi：真实 8 线程而强报 4，与 GPU/canvas 表现可能矛盾 |
| 字体子集（19~23 家族） | 默认启用 | 默认关闭，用系统全部 266 家族 | kimi/glm：纯开源小字体集比"最小化容器"还显眼，且无防关联收益 |
| `media.peerconnection.ice.proxy_only` / `no_host` | 无条件写入 | **仅在真配了代理时**写入 | argon：无代理时会让 ICE 候选为空，本身是可观测异常 |
| `network.dns.disablePrefetch` / `prefetch-next` / `predictor` / `speculative-parallel-limit` | 全部关闭 | 恢复原生 | argon：仅微弱时序差异，无收益 |
| `browser.search.suggest.enabled` | `false` | 恢复原生 | argon：缺 `/complete/search` 属行为层差异 |
| `javascript.use_us_english_locale` | `true` | 恢复原生 | 与系统 locale 可能冲突，无收益 |

保留：关遥测 / 关 Mozilla 账号 / 关 Pocket / 锁更新（**页面完全不可见**）、
profile 隔离、`HOME`/`XDG_*` 重定向（为本环境必需，避免 HOME 不可写时挂死）、
`TZ`（`Intl.DateTimeFormat().resolvedOptions().timeZone` 返回 IANA 名，看不出是否被设置）。

## 二、被实测推翻的一条

argon 断言 `Accept-Language: en-US,en;q=0.9` 是 Chrome 写法、Firefox 应是 `q=0.5`。
在本机用本地 HTTP 服务器抓真实请求头，三种 profile 各测一次：

```
无覆盖（原生）      → en-US,en;q=0.9
user_pref "en-US, en" → en-US,en;q=0.9     ← Firefox 会规范化
user_pref "en-US,en;q=0.9" → en-US,en;q=0.9
```

Firefox 160 原生就发 `q=0.9`。**该指控不成立，未做改动。**

## 三、未处理（需要你决定）

1. **acc02 的 DPR**：人设里仍写着 `dpr=1.25`，但新逻辑默认不写该 pref，
   所以下次启动 acc02 的 `devicePixelRatio` 会从 1.25 变回 1。
   想在已登录的账户上保持原样，在 `profiles/acc02/persona.conf` 加一行 `force_dpr=1`。
2. **acc01**：只把 `accept` 改回原值，其余未动（冻结账户）。
3. **内容沙箱**：在不支持 user namespace 的环境里只能关闭。glm 结论：网页检测不到、
   零指纹收益、纯安全损失——所以**能在正常终端跑就不要关**（本工具会自动判断）。
4. **字体子集文件**：`profiles/*/fonts.conf` 仍在磁盘上，但默认不再加载；
   要恢复子集就在 persona.conf 写 `fonts=on` 并重跑 `bin/gen-fonts.sh`。

---

# 第二轮：全量评审（kimi + argon）后的实测修复

这两份评审都要求"用工具验证"，结果挖出四个**上一轮没发现的真实 bug**。以下每条都有本机实测依据。

## 1. `navigator.languages` 被污染（最严重）

把 `"en-US,en;q=0.9"` 写进 `intl.accept_languages`，Firefox 会把 q 值当成语言标签：

```
languages = ["en-US","en;q=0.9"]                  ← 真实浏览器永远不会这样
Intl.getCanonicalLocales(navigator.languages)     → RangeError: invalid language tag: "en;q=0.9"
```

改成 `"en-US, en"`（Firefox 原生写法）后：

```
languages = ["en-US","en"]         canonical = en-US|en        且 HTTP 头仍是 en-US,en;q=0.9
```

**注意**：HTTP 头不受影响（原生也是 q=0.9），异常只出现在 JS 侧。这个错误就藏在自己的模板里。

## 2. `prefs.js` 残留 —— 上一轮的"移除"其实没生效

Firefox 会把 prefs 持久化进 `prefs.js`；`user.js` 不再写某条 **不等于** 那条被删掉。
实测三个 profile 仍带着旧值：

```
acc01  media.navigator.enabled=false / ice.proxy_only / ice.no_host / devPixelsPerPx=1
acc02  ice.proxy_only / ice.no_host / devPixelsPerPx=1.25
acc03  media.navigator.enabled=false / ice.* / maxHardwareConcurrency=4
```

后果：`navigator.mediaDevices === undefined`、直连下 WebRTC 收集不到候选、DPR 仍是 1.25。
已加 `./bin/gacc N --purge-legacy-prefs` 清理（幂等），并已对 01–03 执行。

## 3. `XDG_RUNTIME_DIR` 覆盖导致 WebGL 全灭

旧代码把它指到 `<runtime>/run`，而 `WAYLAND_DISPLAY=wayland-0` 仍指向 `/run/user/1000`：

```
$ XDG_RUNTIME_DIR=…/run ./firefox/gfxtest glx -w
  ERROR  Could not connect to wayland display, WAYLAND_DISPLAY=wayland-0
```

后果：`canvas.getContext('webgl')` 与 `webgl2` 全部返回 null —— 这本身就是极强的 VM 特征。
已移除该覆盖。修复后实测：`webgl1=YES  webgl2=YES  renderer=llvmpipe, or similar`。

**但这台机器上渲染器仍是 `llvmpipe`（软件渲染）**，属于 WSLg 环境事实，改配置解决不了。
若你的环境里 GPU 进程沙箱是开着的，可能报 `D3D12 (Intel…)`，请自行在控制台确认。

## 4. socket 进程沙箱未关导致 WebRTC 卡死

容器里 `unshare` 不可用时，旧逻辑只关了 content / gpu 沙箱，负责 STUN/ICE 的
**socket 进程**仍按默认 level 2 运行 → 崩溃（`exited on signal 11`）→
`iceGatheringState` 永远停在 `"new"`。已补 `security.sandbox.socket.process.level = 0`
与 `MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1`。

## 归因（两份评审一致）

kimi：机房 IP + 多账号 + 节点轮换 **80–90%**，浏览器改造 **10–20%**。
argon：**75–85%** / **15–25%**，并指出反证——acc01 带着 `mediaDevices=undefined`、`WebGL=null`
仍然登录正常，说明浏览器改造不是单一决定性因素。

两份都建议：**只保留 3 条改造**（TZ 注入、遥测关闭、更新冻结），其余全部还原。

## 5. WebGL 渲染器字符串（实测澄清）

修复 `XDG_RUNTIME_DIR` 后 WebGL 恢复。渲染器字符串对照：

| 场景 | RENDERER / UNMASKED |
|---|---|
| 全新 profile（不含任何 pref），X11 后端 | `llvmpipe, or similar` |
| 全新 profile，headless | `llvmpipe, or similar` |
| 你的浏览器（Wayland 后端） | `Generic Renderer` |

两个字符串在 `libxul.so` 里相邻，都是 Firefox 自己的渲染器名称规范化输出。
**全新 profile 也不报真实 GPU 型号**，所以这不是本工具的 pref 造成的，而是 WSLg 下
Firefox 拿不到 GPU 适配器名称（软件渲染）。

附带发现：`screen` 的报值随后端变化（X11 下 1920x1200，Wayland 下 1440x960），
而 X root 是 4000x1440（双虚拟显示器拼接：1440x960 + 2560x1440）。

---

# 第三轮：REVIEW-5 复核后的收尾修复

argon 的第五轮复核发现上一轮修复有 5 处没闭环，均已修并实测：

| # | 问题 | 修法 | 实测证据 |
|---|---|---|---|
| 1 | `P_ACCEPT` 默认值仍是 `"en-US,en;q=0.9"`（bin/gacc 两处 + deploy 内嵌三处）→ 新建账号会复发 | 改为 `"en-US, en"`，deploy 内嵌副本已同步 | `grep` 确认 5 处全部一致 |
| 2 | `prefs.js` 里还残留 7 项（search.suggest / disablePrefetch / prefetch-next / predictor / speculative-parallel-limit / use_us_english_locale / ice.default_address_only） | `--purge-legacy-prefs` 的匹配清单扩到 12 项 | 三账户各清掉 7–8 行，复查 0 残留 |
| 3 | `prepare_profile` 在 `--purge-legacy-prefs / --fp / --doctor / --sync-tz` 前无条件执行，只读命令也会改写 user.js | 这四个子命令跳过渲染 | 代码已加条件 |
| 4 | `unshare` 恢复后只删了 content/gpu 两个 sandbox 等级，漏删 `socket.process.level` | sed 补一条 | 代码已加 |
| 5 | 受限环境只关了 CONTENT/SOCKET，RDD 子进程仍崩 | 补 `MOZ_DISABLE_RDD_SANDBOX/UTILITY/GMP_SANDBOX=1` | 代码已加 |
| 6 | `unset MOZ_ENABLE_WAYLAND` 并不能禁用 Wayland → screen 报 1440x960、窗口不在 X 树里 | 改为 `export MOZ_ENABLE_WAYLAND=0` 固定 X11 | 实测：X11 窗口可截、`screen=1920x1200`、WebGL 仍为 YES |

## 收尾后的运行时实测（acc03，真实启动）

```
languages    = ["en-US","en"]
canonical    = en-US|en            （不再抛 RangeError）
mediaDevices = function            （不再 undefined）
webgl        = YES                 （修复前是 NULL）
RENDERER     = llvmpipe, or similar
dpr          = 1
screen       = 1920x1200           （X11 后端；Wayland 下是 1440x960）
cores        = 8                   （原生值，未伪造）
```

## 渲染器字符串的最终解释（argon 反汇编确认）

`webgl.sanitize-unmasked-renderer` 默认开启，两个值都是**原生脱敏输出**：

- 软件渲染（swrast）→ 匹配内置规则 → `"llvmpipe, or similar"`
- 用户环境走 Mesa d3d12 驱动 → 前缀 `"D3D12 (Intel…)"` 不在内置规则表里 → 回退 `"Generic Renderer"`

所以 `"Generic Renderer"` **不是改装证据**；保留默认脱敏反而掩盖了 WSL2 特有的 `D3D12` 字样。
