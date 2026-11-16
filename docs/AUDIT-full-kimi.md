# gacc 环境完整独立评审（kimi 版）

评审对象：`/home/eli/cc-499/gaccounts`（gacc 启动器 + 3 个 Google 账户 profile）。
评审人独立读取了以下文件全文：`etc/user.js.tmpl`、`bin/gacc`（522 行）、`profiles/acc01..acc03` 的
`persona.conf` / `user.js` / `proxy.conf`、`bin/gen-fonts.sh`、`docs/AUDIT-summary.md`、
`docs/ANALYSIS-gemini.md`，并做了本机实测（见各条 [依据]）。

现场事实（委托人提供，未逐条复核）：WSL2 + WSLg、X root 4000x1440、D3D12 映射真实 Intel 核显、
便携版 Firefox 160.0、系统 266 个字体家族、Google/AI 流量由 Windows 侧按域名分流到美国机房、
出口 IP 实测轮换（129.146.247.77 Oracle Phoenix / 161.153.0.146 / 199.180.112.115 IT7 LA）。

本机复核结果：Firefox 版本号 **160.0 是真实官方构建**
（`application.ini`：BuildID 20261104181552，SourceRepository hg.mozilla.org/releases/mozilla-release
[依据: `firefox/application.ini` 全文 / `./firefox/firefox --version` → "Mozilla Firefox 160.0"]）。
当前时间是 2026-11-16，160.0 属正常 Release。**gemini 报告中"rv:160.0 版本号异常/假 UA"的指控不成立。**

---

## 0. 本机实测记录（后续断言的证据基础）

| 实测 | 结果 | 依据 |
|---|---|---|
| 原生（全新 profile，无 user.js）HTTP 头 | `Accept-Language: en-US,en;q=0.9`；UA 完整未裁剪 | 本机 python http.server handler 抓包，firefox --headless 全新 profile |
| `user_pref("intl.accept_languages","en-US,en;q=0.9")` | 头发送值与原生**完全一致**（en-US 是构建 locale，与系统 LANG 无关） | 同上，user.js 对照组 |
| `user_pref("javascript.use_us_english_locale", true)` | 对 HTTP 头**无任何影响**（已删除，正确） | 同上对照组；该 pref 只影响 JS 引擎 toLocaleString 的默认 locale |
| `pref("media.peerconnection.ice.proxy_only", false)` | omni.ja 默认 false | `grep -ao` firefox/omni.ja |
| `pref("browser.search.suggest.enabled", true)` | omni.ja 默认 true（已还原，正确） | 同上 |
| `pref("network.prefetch-next", true)` / `speculative-parallel-limit = 20` | omni.ja 默认值（已还原，正确） | 同上 |
| `pref("security.sandbox.content.level", 6)` | 默认 6（Linux） | `grep -ao` firefox/browser/omni.ja |
| `pref("identity.fxaccounts.enabled", true)` / `app.update.auto = true` / `browser.startup.page = 1` | 默认值确认 | 同上 |
| `media.peerconnection.enabled` / `dom.maxHardwareConcurrency` / `privacy.resistFingerprinting` 默认 | **omni.ja 未直接命中**（C++ 静态 pref 表），按官方文档为 true / 16（不设限）/ false；列入「未能验证」 | 见 §6 |
| 内容沙箱在本环境**不可用** | `Sandbox: writing /proc/self/uid_map: EACCES`，内容进程 SIG11 崩溃 | headless 实测 stderr |
| `libs/` 补丁目录 | **空**，`LD_LIBRARY_PATH` 实际无影响 | `find libs -type f` → 空 |

---

## 1. 逐项清点

### 1.1 渲染后 user.js 的 prefs（现状 = AUDIT-summary 改动后）

先说明三个 profile 的差异来源：`acc03/user.js` 是最新模板渲染（2026-11-16 18:40），
`acc01`/`acc02` 的 user.js 是**旧模板残留**（含已被移除的 prefs），但下次启动会用新模板重新渲染覆盖。
下表以**新模板**为准，旧残留单列。

| # | pref | 与原生 Firefox 160 不同？ | 网页/服务端能否观测 | 风险 | 建议 |
|---|---|---|---|---|---|
| 1 | `network.proxy.type=0`（全部 acc，proxy.conf=direct） | 同默认 | 不可见（页面无 API；服务端只见连接源 IP） | 无 | 保留 |
| 2 | `intl.accept_languages="en-US,en;q=0.9"` | **相同**（实测原生头发的就是这个值） | 可见（HTTP 头），但与原生一致 | 无 | **可删**（删了更干净；保留也无害） |
| 3 | `privacy.resistFingerprinting=false` | 同默认 | 可见（RFP 的一系列标准化值不存在 = 正常） | 无 | 可删 |
| 4 | `media.peerconnection.enabled=true` | 同默认 | `RTCPeerConnection` 存在 = 正常 | 无 | 可删 |
| 5 | `network.captive-portal-service.enabled=false` | 不同（默认 true） | 网页不可见；服务端不可见（ captive 请求只发 Mozilla） | 低 | 保留 |
| 6 | `network.connectivity-service.enabled=false` | 不同 | 同上 | 低 | 保留 |
| 7 | `toolkit.telemetry.*`（4 条）、`datareporting.*`（2 条）、`app.shield.optoutstudies`、`app.normandy.enabled`、`browser.ping-centre.telemetry`、`browser.discovery.enabled`、`activity-stream.*.telemetry`（2 条） | 不同 | **网页/服务端均不可见**（只影响发向 Mozilla 的后台流量；无 JS API 可读取遥测开关） | 无 | 保留 |
| 8 | `identity.fxaccounts.enabled=false` | 不同 | 网页不可见 | 无 | 保留 |
| 9 | `extensions.pocket.enabled=false`、`browser.messaging-system.whatsNewPanel.enabled=false` | 不同 | 不可见 | 无 | 保留 |
| 10 | `app.update.auto/enabled/service.enabled=false` | 不同 | 不可见；且对"指纹稳定"有利（版本不中途变） | 无 | 保留 |
| 11 | `browser.startup.page=3`、`resume_from_crash=true`、`shell.checkDefaultBrowser=false`、`aboutConfig.showWarning=false`、`homepage_override.mstone="ignore"` | 不同 | 不可见（纯本地行为） | 无 | 保留 |
| 12 | `@SANDBOX@` → acc01/acc03 写入 `security.sandbox.content.level=0` + `gpu.level=0` | 不同（默认 6） | **页面无 JS API 直接读沙箱级别**；间接信号（如 `SharedArrayBuffer`/COOP 行为、进程模型）在正常浏览场景不可区分。服务端不可见 | 低（指纹面）；中（安全面——这是纯安全损失） | **环境不支持 userns 时别无选择**；WSL2 可改用 `kernel.unprivileged_userns_clone` 或换 Docker/真机恢复沙箱 |
| 13 | acc01/acc02 user.js 旧残留：`dom.maxHardwareConcurrency=8`、`layout.css.devPixelsPerPx="1"/"1.25"`、`javascript.use_us_english_locale=true`、`ice.proxy_only/no_host`（无代理时）、`dns.disablePrefetch`、`prefetch-next=false`、`predictor.enabled=false`、`speculative-parallel-limit=0`、`browser.search.suggest.enabled=false` | 全部与原生不同 | 多数可见（见下） | **中~高**（历史影响期） | 已被新模板移除；**下次启动自动覆盖**，无需手工处理 |

### 1.2 启动器环境变量（bin/gacc 465–490 行）

| 变量 | 与原生不同 | 可观测性 | 风险 | 建议 |
|---|---|---|---|---|
| `LD_LIBRARY_PATH=$ROOT/libs 下 .so 目录` | 不同 | 不可见（libs/ 为空，实际无加载差异） | 无 | 保留（空操作） |
| `MOZ_CRASHREPORTER_DISABLE=1` | 不同 | 不可见（崩溃报告只发 Mozilla） | 无 | 保留 |
| `MOZ_DISABLE_AUTO_SAFE_MODE=1` | 不同 | 不可见 | 无 | 保留 |
| `GSETTINGS_BACKEND=memory` | 不同 | 不可见（避免 dconf 依赖） | 无 | 保留 |
| `unset MOZ_ENABLE_WAYLAND` | 强制 X11 | UA 里的 `X11` 字样与之一致；WSLg 下 Wayland 反而不稳 | 低 | 保留 |
| `MOZ_DISABLE_CONTENT_SANDBOX=1`（仅当 user.js 里已关沙箱时） | 不同 | 同 #12 | 低 | 跟随 #12 |
| `HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME`/`XDG_DATA_HOME`/`XDG_RUNTIME_DIR` 重定向到 runtime/accNN | 不同 | **不可见**（路径不进任何 JS API；`navigator`/下载默认目录由 Firefox 内部处理） | 无 | 保留（多 profile 隔离必需） |
| `TZ=$P_TZ`（America/Denver / Phoenix / Phoenix） | 不同 | **可见**：`Intl.DateTimeFormat().resolvedOptions().timeZone` 返回该 IANA 名；Date 偏移一致 | 低（IP 与 TZ 同城/邻州时）/ 中（错位时） | 保留，但必须与出口 IP 对齐（见 §2-矛盾 4） |
| `FONTCONFIG_FILE=$PROF/fonts.conf` | 不同 | **可见**（字体枚举/测量） | 中 | **默认关闭是正确决定**（见 1.4） |

### 1.3 启动命令行（bin/gacc 500–501 行）

```
setsid --fork nohup firefox --profile "$PROF" --class "gacc-$ACC" [URLS]
```

| 参数 | 与原生不同 | 可观测性 | 风险 | 建议 |
|---|---|---|---|---|
| `--profile <绝对路径>` | 正常使用方式 | 不可见 | 无 | 保留 |
| `--class "gacc-NN"` | WM_CLASS 含 "gacc" | **网页不可见**；仅本机窗口管理器可见 | 无 | 保留 |
| `setsid --fork nohup … </dev/null >>firefox.log 2>&1` | 进程脱离 | 不可见 | 无 | 保留 |
| **不加** `--no-remote`、不加 `-width/-height` | — | — | — | 正确决定（前者会让 OAuth 弹窗静默失败；后者与会话恢复打架） |

### 1.4 字体子集（bin/gen-fonts.sh）

机制：`FONTCONFIG_FILE` 指向每账户 fonts.conf → 只含 `<dir>profiles/accNN/fonts</dir>` 一个目录，
里面是符号链接：6 个必含基础字体（DejaVu×4 + NotoSansCJK-Regular.ttc + NotoColorEmoji）
+ 按 `ACC%4` 分组取 6~9 个候选（FreeFont/Kacst/Liberation/Noto/Nimbus/TeX Gyre/Arimo/Tinos…白名单）。

现状实测：
- acc02 fonts/ 14 个文件、acc03 fonts/ 15 个文件；系统共 266 家族。
- acc01 无 fonts/ 目录（从未生成）。
- **默认不生效**：`bin/gacc:488` 要求 persona.conf 里 `fonts=on` 才 export FONTCONFIG_FILE，
  三个 persona.conf 都没有该行 → **当前运行时看到的仍是系统全部 266 个字体**。

| 项 | 判断 |
|---|---|
| 与原生不同 | 是（若启用） |
| 可观测 | 页面可通过文本宽度测量/Canvas 探测"某字体是否存在"；19~23 个纯开源家族、零商业字体（无 Arial/Times/Calibri 任何度量兼容字体之外的）是一个**罕见的极简 Linux 字体集** |
| 风险 | **中**：对防关联收益存疑（各账户必含相同 6 基础字体），对"显得自然"为负 |
| 建议 | **保持默认关闭**（现状）。磁盘上的 fonts.conf 无害，不加载即可 |

### 1.5 profile 目录结构

标准 Firefox profile（cookies/places/prefs.js/sessionstore…）+ gacc 附加 4 个文件：
`persona.conf`、`proxy.conf`、`user.js`（每次启动重渲染）、`firefox.log`、可选 `fonts.conf`+`fonts/`。
均不在 web 可观测面。**风险：无。**

---

## 2. 自相矛盾检查（组合不可能/极罕见）

| # | 组合 | 严重度 | 现状 | 说明 |
|---|---|---|---|---|
| 1 | **screen × dpr 乘积相同**：acc02 旧人设 dpr=1.25 → screen 报 3200×1152；acc01/acc03 dpr=1 → 4000×1440。`3200×1.25=4000`、`1152×1.25=1440` 乘积完全相等 | **高**（跨账户关联铁证） | **已修复**：新模板默认不写 devPixelsPerPx，三账户将全部报 4000×1440@1。但注意：这也让"screen 尺寸相同"成为跨账户不变量——同一块物理屏本来就无法伪装，WSLg 下无解（除非上 Xephyr 虚拟屏） | [依据: bin/gacc:128-133 现状 / gemini §4-矛盾2] |
| 2 | **4000×1440 本身**：非任何量产显示器标准分辨率（3440×1440/3840×1600/5120×1440 之外） | 中 | 未解决 | X11 root 尺寸暴露为 screen.width/height（dpr=1 时）。这是 WSLg 窗口自由拉伸的产物。**所有账户共享此值**，比任何 persona 差异都醒目 |
| 3 | **核数与人设声明 vs GPU**：旧配置把 8 核机器强报 4（acc03 persona cores=4），而 WebGL 暴露真实 Intel 核显 + D3D12 映射——"4 核 CPU 配 Iris Xe"不算不可能但偏少 | 低 | 已修复（默认不写 maxHardwareConcurrency，报真实 8） | [依据: AUDIT-summary 一表] |
| 4 | **TZ 与出口 IP 地理错位**（现行最大的现存矛盾）：acc01 TZ=America/Denver、acc02/03 TZ=America/Phoenix；实测出口 IP 轮换于 Phoenix（129.146.247.77 Oracle）与 **Los Angeles**（199.180.112.115 IT7）之间。IP 在 LA 时 TZ=Phoenix/Denver 错位 1 小时；冬令时 LA(UTC-8) vs Phoenix(UTC-7) 确实差 1 小时 | **中~高** | **未解决** | `Intl` 时区页面必可见；IP 地理服务端必可见。邻州 1 小时单独看无害，但**同一账户的 IP 在多个城市的机房轮换而 TZ 固定**，等于宣告"人在用代理池"。修复在出口侧（钉节点），不在浏览器侧 |
| 5 | UA / Accept-Language / JS 引擎一致性 | 无矛盾 | OK | 实测 UA 完整、AL 头与原生逐字节一致；未改 `general.useragent.override`，TLS/HTTP2 栈原生 |
| 6 | acc02 与 acc03 **人设撞车**：tz 都是 America/Phoenix（gen_persona 的"不撞时区"约束在 acc03 生成时未生效——acc03 persona.conf 时间戳与 acc02 同日，疑似手工/早期版本产物） | 低~中 | **现存** | 两账户同 TZ + 同屏幕 + 同 GPU + 同 UA → 可区分维度只剩 IP/cookie。若两账户同时在线且共用出口，关联面很大 |
| 7 | `identity.fxaccounts.enabled=false` + 无任何 Mozilla 服务流量 | 无 | OK | 真人大量如此，不是异常 |
| 8 | （历史）`RTCPeerConnection` 存在但 ICE 候选为空（无代理却设 proxy_only） | 中 | **已修复**（仅配代理时才写） | [依据: bin/gacc:176-187 现在 proxy_only 只在 socks5 分支] |

---

## 3. 归因判断

### 3.1 权重估计（非 Google 内部数据，基于触发时序与机制推断）

| 因素 | 权重 | 理由 |
|---|---|---|
| **机房 IP + 多账号 + IP 轮换** | **80–90%** | 决定性证据是行为时序：03 号"吊销全部会话 + 换 5 个号码均验证失败"是**账户级风控**（账号-环境信誉绑定），02 号 AI Studio 验证、01 号正常，三账户浏览器指纹几乎相同（同屏幕/同 GPU/同 UA/同 AL 头），差异恰好在**账号行为与历史**上。若指纹是主因，三个账户应同罪。另外 `We couldn't verify your number — unusual activity` 是 Google 对"号码+IP 段+设备信誉"综合打分的典型文案，机房段+IP 池轮换是已知最强负向信号 |
| **浏览器改造（现存配置）** | **10–20%**（且主要是历史配置的残留影响 + 跨账户关联面） | 见下 |

### 3.2 哪些改造**根本不可能**导致 Google 验证（避免过度归因）

以下各项页面 JS 与服务端均无任何观测通道，**判无责**：

1. 全部遥测/数据上报开关（`toolkit.telemetry.*`、`datareporting.*`、`app.normandy`、`shield studies`、`ping-centre`、`activity-stream telemetry`）——只影响发向 Mozilla 的流量。
2. `identity.fxaccounts.enabled=false`、`extensions.pocket.enabled=false`——chrome 层 UI 开关。
3. `app.update.*=false`——更新只联系 Mozilla/AUS。
4. `browser.startup.page=3`、`resume_from_crash`、`shell.checkDefaultBrowser` 等启动行为——纯本地。
5. `MOZ_CRASHREPORTER_DISABLE`、`GSETTINGS_BACKEND=memory`、HOME/XDG 重定向、setsid/nohup、--class、--profile——进程/环境层，网页零可见。
6. `MOZ_DISABLE_CONTENT_SANDBOX` / `security.sandbox.content.level=0`——**页面无 API 读沙箱级别**；它是纯安全损失，不是指纹问题（无法断言 Google 完全不做侧信道探测，列入 §6 不确定项）。
7. `network.captive-portal-service` / `connectivity-service` 关闭——请求目标是 Mozilla，Google 看不到。
8. 空 `LD_LIBRARY_PATH`（libs/ 无文件）。

### 3.3 浏览器侧真实有罪/有嫌疑的（按罪名排序）

1. **（历史，已修复）dpr=1.25 制造 3200×1152**：孤本 screen 值 + 与其它账户乘积相等——跨账户关联铁证。02 号恰好是被要求验证的那个，时间上与其使用该人设的窗口重叠，**嫌疑真实存在但无法定量**。
2. **（现存）IP 轮换 × 固定 TZ**：每 5 次请求换机房间的 IP，配固定 TZ/固定屏幕/固定 GPU——这不是浏览器改造的错，但浏览器侧的"完全稳定"放大了出口侧"完全不稳定"的反差。
3. **（现存）4000×1440 共享屏幕 + 共享 GPU 渲染器 + 同 UA 版本**：三账户在这些维度完全一致，persona 差异（TZ/核数）杯水车薪。这不是"异常"，但让"多账户防关联"目标基本落空。
4. **（历史，已修复）删 prefetch/predictor/search.suggest**：行为层微弱差异，基本无责。

---

## 4. 最终建议

### 4.1 最保守 user.js（可直接替换 `etc/user.js.tmpl` 全文）

```javascript
// ===== gacc 最保守模板 =====
// 原则：凡是"页面或 Google 服务端有任何可能观测到"的，一律保持原生；
//       只保留"观测不到"或"观测到也属于真人正常行为"的项。

// ---- 代理（gacc 按 proxy.conf 渲染；无代理时整块为空）----
@PROXY@

// ---- 时区：经 TZ 环境变量注入（bin/gacc 483 行），不落 prefs ----
// 语言：实测原生头发的就是 en-US,en;q=0.9，无需任何 pref
// （空占位，保持模板结构）
@PERSONA@

// ---- 沙箱：仅在环境不支持时写入（安全损失，非指纹需要）----
@SANDBOX@

// ---- 以下全部"网页/服务端不可见"，保留 ----
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.server", "data:,");
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("app.normandy.enabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.discovery.enabled", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);
user_pref("identity.fxaccounts.enabled", false);
user_pref("extensions.pocket.enabled", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);

// ---- 版本冻结：指纹不在会话中途变化（网页不可见）----
user_pref("app.update.auto", false);
user_pref("app.update.enabled", false);
user_pref("app.update.service.enabled", false);

// ---- 启动行为（本地便利，网页不可见）----
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutConfig.showWarning", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
```

删除项（相对现模板）：`media.peerconnection.enabled=true`、`privacy.resistFingerprinting=false`、
`intl.accept_languages`——三者都等于默认值，删了少一份"user.js 存在"的痕迹，行为不变。
（user.js 本身网页读不到，删它们主要是洁癖，非必需。）

### 4.2 最安全启动命令

```bash
TZ="America/Los_Angeles" \
HOME="$RUNTIME/home" XDG_CONFIG_HOME="$RUNTIME/config" \
XDG_CACHE_HOME="$RUNTIME/cache" XDG_DATA_HOME="$RUNTIME/data" \
XDG_RUNTIME_DIR="$RUNTIME/run" \
MOZ_CRASHREPORTER_DISABLE=1 GSETTINGS_BACKEND=memory \
setsid --fork nohup ./firefox/firefox --profile "$PROF" --class "gacc-$ACC" </dev/null >>"$PROF/firefox.log" 2>&1 &
```

要点：TZ 与**该账户钉死的出口节点**城市一致；不加 `--no-remote`；不加尺寸参数；
不设 FONTCONFIG_FILE；不设 LD_LIBRARY_PATH（libs/ 为空）。

### 4.3 保留项逐条理由

| 保留 | 理由 |
|---|---|
| 遥测/datareporting/normandy/shield 关闭 | 网页不可见；减少 Mozilla 侧流量与实验分支带来的指纹漂移 |
| fxaccounts/Pocket 关闭 | 网页不可见；避免误登录 Mozilla 账号造成跨 profile 关联 |
| app.update 关闭 | 网页不可见；保证 UA/JS 特征在长会话期间不突变 |
| TZ 注入 | `Intl` 必可见，必须与出口 IP 同城——前提是**先把出口钉死** |
| HOME/XDG 隔离 | 网页不可见；多 profile 共存的基础设施 |
| 会话恢复（startup.page=3） | 网页不可见；保持 cookie/会话连续性正是 Google 信誉积累的关键（见下） |
| 沙箱开关（条件触发） | 环境不支持时无选择；能开则开 |

### 4.4 浏览器之外（真正的主战场，按优先级）

1. **钉死每账户出口**：Windows 分流规则按进程/端口绑定单节点，关闭负载均衡/轮换。
   `bin/gacc --doctor` 已有 3 连测检测，把它当成每次启动前的硬门槛。
2. **换住宅/ISP 代理**：Oracle(AS31898)/IT7 机房段是主因。不换段，浏览器侧做任何事都只是粉饰。
3. **保住已登录会话**：01 号正常就是证据——cookie 信誉 + 固定 IP 的账户存活。
   03 号已死的会话不要在同一 profile 里反复重试验证（号码风控会加深），
   换新出口段 + 静置数天再试，或放弃重建。
4. **（可选）消灭 4000×1440**：Xephyr 起 1920×1080/2560×1440 标准屏，每账户一块虚拟屏。
   这是浏览器侧唯一还剩的"高辨识度共享不变量"。

---

## 5. 如果只能保留 3 条改造

1. **TZ 环境变量注入**（唯一一个"改了比原生更像真人"的项——前提是出口先钉死同城）
2. **遥测/datareporting/normandy/shield 整组关闭**（算一类；网页不可见，消除版本/实验漂移）
3. **app.update 关闭**（网页不可见，版本冻结）

**其余全部还原更好**：是。`dom.maxHardwareConcurrency`、`devPixelsPerPx`、字体子集、
WebRTC/prefetch 阉割、use_us_english_locale、intl.accept_languages——全部回到原生。
现模板已经走在正确方向上（AUDIT-summary 的改动全部认可），本报告确认那轮改动**没有误杀**。

---

## 6. 未能验证的推断（明确标注"不确定"）

1. `media.peerconnection.enabled` / `dom.maxHardwareConcurrency` / `privacy.resistFingerprinting` /
   `javascript.use_us_english_locale` 的 omni.ja 默认值：grep 未直接命中（位于 C++ 静态 pref 表，
   编译进 libxul）。按 Mozilla 文档应为 true / 不设限 / false / false，**未做二进制级复核**。
   不影响结论：这些 pref 在新模板中要么已删、要么等于文档默认值。
2. Google 是否做**沙箱状态侧信道探测**（如通过性能/特性可用性推断 seccomp 状态）：
   公开资料未见实例，**不确定**。判"低风险"而非"无风险"。
3. Google 账号风控中浏览器指纹的确切权重：黑盒，§3.1 的 80/20 划分是基于
   "三账户指纹近似而结果迥异 + 拦截文案指向 IP/号码信誉"的推断，**非内部数据，不确定**。
4. WSLg D3D12 映射下 WebGL `UNMASKED_RENDERER` 的确切字符串（实测为宿主 Intel 核显名而非
   llvmpipe——委托人口述，**未在本机跑 WebGL 实测**，因 headless 环境沙箱受限）。
   若字符串含 "D3D12" 或 "Microsoft"，则"Linux UA + Windows 风格 GPU 串"是新增矛盾点，
   建议用户在实际运行账户的页面控制台执行
   `document.createElement('canvas').getContext('webgl').getParameter(
   document.createElement('canvas').getContext('webgl').getExtension('WEBGL_debug_renderer_info')
   .UNMASKED_RENDERER_WEBGL)` 自查。
5. `channel=entpr`：policies.json 已删除且确认不存在（`ls firefox/distribution/` 只剩
   distribution.ini），gemini 报告所指问题已消除；**未实测**当前搜索 URL 是否还携带该参数。

---

## 7. 一句话总结

**这套环境的浏览器侧已经没有"一眼假"的硬伤（上轮清理是正确且充分的），剩下的高辨识度项
（4000×1440 共享屏、共享 GPU、IP 轮换×固定 TZ）全部指向同一个根因：出口 IP 层的机房段+轮换。
03 号的手机号验证死局是账户级风控，改浏览器改不出去；钉死住宅出口、保住 01 号的会话信誉，
比继续折腾指纹重要一个数量级。**
