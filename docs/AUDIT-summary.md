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
