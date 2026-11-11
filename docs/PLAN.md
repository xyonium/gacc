# 方案：多 Google 账户的「机器层面隔离」

> 状态：方案待审 → 送 `gemini-4-argon` 复核
> 环境：WSL2 (Ubuntu 22.04.5, kernel 6.18.58.1-microsoft-standard-WSL2) + WSLg
> 本文档是最终交付前的设计说明，包含已验证事实、已知 bug、待办与风险。

---

## 1. 目标与非目标

**目标**
1. 一台机器上登录 N 个 Google 账户，账户之间不能互相看到 cookie/存储/登录态。
2. 每个账户在 Google 看来是「不同的人 / 不同的电脑」，至少不能一眼判定为同一台机器的同一用户。
3. 一键启动，账户编号即身份，零手工配置。
4. 不依赖任何第三方云面板，数据全本地。

**非目标**
1. 不做出口 IP 隔离（用户自行随机选择出口，本方案只提供 per-profile 代理接口）。
2. 不追求「对抗国家级对手」级别；目标是**降低自动关联概率**，不是绝对匿名。
3. 不替换用户日常浏览器（日常 Chrome 不动，本方案是独立的一套）。

## 2. 威胁模型：能防什么、防不住什么

| 层面 | 本方案 | 说明 |
|---|---|---|
| Cookie / localStorage / IndexedDB / 历史 / 缓存 | ✅ 物理隔离 | 每个账户一个独立 profile 目录，独立进程 |
| 登录态串号（同浏览器切换账号） | ✅ 消除 | 不同 profile 之间无共享 cookie jar |
| 时区 / 语言 / 核心数 / DPR / 窗口尺寸 | ✅ 每账户不同 | 见 §4 |
| 出口 IP | ⚠️ 仅提供接口 | 由用户自己随机；WSL NAT 下 127.0.0.1 与 Windows 不通 |
| Canvas / WebGL / 字体 / GPU / 音频指纹 | ❌ 完全相同 | 同一二进制 + 同一台机器，prefs 改不动 |
| TLS / HTTP2 指纹 | ❌ 完全相同 | 同一个 Firefox 版本 |
| Google 侧非浏览器信号（恢复手机号、验证设备、登录节奏、行为模式） | ❌ 无解 | 这是真正的关联主力，比指纹权重高 |

**结论性提醒**：本方案能保证「账户之间互相看不见」，能降低低层信号的一致性，但**不能保证 Google 认不出是同一个人**。任何声称单靠浏览器配置就能做到的说法都不成立。

## 3. 选型结论

选 **Firefox + 一账户一 profile**，不选 Multi-Account Containers、不选 ungoogled-chromium。

理由（含对原始假设的纠正）：
1. **官方 MAC 没有 per-container 代理**。`network.proxy.*` 是全浏览器的，容器只管 cookie 分区。原方案里「每容器独立 SOCKS5」这个前提不存在。
2. **profile 的隔离强度严格高于容器**：容器共享进程/prefs/代理，profile 是全套独立。容器在本方案里降级为「同一个人开多标签」的便利功能（已通过企业策略装上并预置 G1–G4）。
3. **ungoogled-chromium 在本机不可行**：无 root（`no_new_privs` 挡住 sudo），Ubuntu 22.04 无官方源，主仓库不提供官方二进制；Windows 侧只有未签名贡献版。它对本方案唯一真正有价值的差异是**换内核 = 换 TLS/JS/渲染指纹**，这一点在 §6 作为「进阶选项」保留。
4. `chrome.enterprise.reportingPrivate` 是企业策略 API，不是消费级遥测后门，不能作为选型依据。

## 4. 每账户「人设」层（已实现）

每个 profile 一个 `persona.conf`，首次启动随机分配（避开已被占用的时区），永久固化：

```
locale=en-US
accept=en-US,en;q=0.9
tz=America/Los_Angeles
cores=8
dpr=1.25
w=1600
h=900
```

映射到实际生效位置：

| 维度 | 落地方式 | 验证状态 |
|---|---|---|
| 时区 | 启动时 `export TZ=...`，Firefox 的 `Intl.DateTimeFormat().resolvedOptions().timeZone` 跟随 | ✅ 已验证（`TZ=Asia/Tokyo` → JS 报 `Asia/Tokyo`） |
| 语言 | `intl.accept_languages` + `javascript.use_us_english_locale` | ✅ 已验证（prefs 设 `de-DE,...` → JS 报 `navigator.language=de-DE`） |
| 核心数 | `dom.maxHardwareConcurrency` | ✅ 已验证（设 4 → `navigator.hardwareConcurrency=4`） |
| DPR | `layout.css.devPixelsPerPx` | ✅ 已验证（设 1.5 → `devicePixelRatio=1.5`；副作用 UI 缩放跟着变） |
| 窗口 | 启动参数 `-width/-height` | ⏳ 待验证（与 `browser.startup.page=3` 会话恢复可能冲突，见 §11.2） |

**人设池已按用户要求锁定美国西部**：`America/Los_Angeles`（5 条）、`America/Phoenix`（2）、`America/Denver`（1）、`America/Anchorage`（1）、`Pacific/Honolulu`（1）。全部 `en-US` / `en-US,en;q=0.9`。

**为什么不用 `privacy.resistFingerprinting`**：RFP 会把所有人抹成同一组值（时区强制 UTC、语言强制 en-US、窗口尺寸取整），结果是「你的 N 个账户全都长得一样」——对防关联是负收益，而且会破坏美西时区设定。已显式设为 `false`。

## 5. 渲染指纹：要不要改、能不能安全改

**要不要改**：看你的对手用不用它。Google 的账号关联主力不是 canvas，而是 IP、行为、恢复信息；但设备指纹确实存在。优先级应该排在「换内核/版本」之后。

**能不能安全改**：能改的只有 canvas 和字体，且都有代价。

| 方案 | 效果 | 风险 | 结论 |
|---|---|---|---|
| `privacy.resistFingerprinting=true` | canvas 被噪声化/统一化 | 所有账户变同一张脸；强制 UTC 破坏人设；破坏网站功能 | ❌ 不用 |
| CanvasBlocker（AMO 开源扩展） | canvas 读取得到的值每站点稳定、跨账户不同 | 需配置成「同站点内稳定」，否则同一账户内指纹飘动反而更显眼；扩展本身可被探测 | ⚠️ 可选，需先做基线测试 |
| WebGL vendor/renderer 伪造 | 改 GPU 字符串 | 无原生 pref；靠扩展 hook，容易导致渲染异常/被检测 | ❌ 不建议 |
| 每 profile 独立 `FONTCONFIG_FILE` | 字体列表不同（很强的信号） | 配错就豆腐块；系统字体总量不变，只是子集 | ⚠️ 可试，需保证 CJK 可用 |
| 换内核/换大版本（一半 Firefox，一半 ungoogled-chromium / Firefox 旧大版本） | TLS + JS 引擎 + 渲染栈全变 | 维护成本翻倍；版本越旧越容易被「浏览器过旧」标记 | ✅ **收益/风险比最高** |

**推荐**：先不上任何 canvas 相关改动。①验证 §4 的人设是否真的落地；②按账户奇偶分两套内核（或两个 Firefox 大版本）——这是唯一能把 TLS 指纹也拉开的手段；③只有在确认对手确实用 canvas 关联时，再评估 CanvasBlocker。

## 6. 架构与文件

```
gaccounts/
├── bin/gacc                 启动器（唯一入口）
├── etc/user.js.tmpl         硬化模板，@PROXY@ / @PERSONA@ / @SANDBOX@ 三个占位符
├── etc/policies.json        企业策略：强装 MAC、关遥测/账号同步
├── firefox/                 便携版 Firefox（解压即用，不碰系统）
├── libs/                    缺失 .so 的本地补丁（**已删**：用户 apt 装好系统库，现直接跑系统库）
├── profiles/accNN/
│   ├── proxy.conf           一行：该账户的代理（或 direct）
│   ├── persona.conf         该账户的人设
│   ├── user.js              每次启动由模板渲染（勿手改）
│   └── containers.json      G1–G4 预置容器
├── runtime/accNN/           每账户独立的 HOME/cache/XDG
├── windows/gacc.ps1         Windows 版（未验证）
├── deploy-gacc.sh           一键部署脚本（有已知 bug，见 §8）
└── PLAN.md / README.md
```

启动链路：`gacc N` → 生成/读取 `persona.conf` → 渲染 `user.js`（代理 + 人设 + 视环境决定是否关沙箱）→ 导出 `TZ`/`HOME`/`XDG_*`/`LD_LIBRARY_PATH` → `setsid --fork firefox --no-remote --profile <dir>`。

## 7. 已验证事实（含证据）

| 事实 | 证据 |
|---|---|
| 便携 Firefox 160.0 可在此环境跑起来 | `firefox --version`；headless 截图渲染出真实页面 |
| `TZ` 影响 JS 时区 | data: URL + 截图，`TZ=Asia/Tokyo` → `TZ=Asia/Tokyo` |
| 每 profile 代理真的生效 | acc01 `network.proxy.type=0`，acc02 `=1` + `socks_port=1082` + `socks_remote_dns=true` |
| 多实例并存 | 两个 Firefox 同时运行，X11 窗口 WM_CLASS 分别为 `gacc-1` / `gacc-2` |
| MAC 被策略强制安装 | profile 下出现 `@testpilot-containers.xpi` |
| 会话恢复可用 | 重启后 Google 登录标签页自动回来 |

## 8. 踩过的坑（对复制部署价值最高，都已修复）

1. **`$HOME` 不可写 → Firefox 静默卡死在启动早期**（profile 只有 4 个文件，无任何报错）。修复：`HOME`/`XDG_*` 重定向到 `runtime/`。**这是最初「标签页全白」的真正原因**，一度被误判为沙箱问题。
2. **`nohup &` 起的 GUI 会被父进程回收**。修复：`setsid --fork` 双重脱离。
3. **内容沙箱在受限环境下必须关**：写 `/proc/self/uid_map` EACCES → 内容进程 SIGSEGV → 白页。已实测 `security.sandbox.content.level` = 1/2/3 全部崩溃，不存在「降级可用」的中间态。
4. **关沙箱后地址栏下方必然出现黄条警告**，`security.sandbox.warn=false` **不能**压掉（已实测）。该黄条只是观感问题；在正常终端里 userns 可用时沙箱开启，不会出现。
5. **一次误判**：我最初把「卡死」归因于沙箱，其实是 (1)。且我用 shell wrapper 做 `ldd` 得出「依赖齐全」的错误结论——真实二进制是 `firefox-bin`/`libxul.so`，缺 `libasound.so.2` 等 3 个库。

## 9. 剩余工作

- [ ] `deploy-gacc.sh`：`ldd` 检查改指向 `firefox-bin` + `libxul.so`（当前误用 wrapper → 假阳性）
- [ ] `deploy-gacc.sh`：接入人设生成（`@PERSONA@`）、去掉「按 userns 预判关沙箱」的旧逻辑（改为 `gacc` 每次启动探测）
- [ ] `deploy-gacc.sh`：若系统已装那几个库，跳过 `dpkg -x` 本地补丁
- [ ] 验证 §4 四个「待验证」维度是否真的落到 JS 可见层
- [ ] README 更新：沙箱结论（旧版写错）、人设层、渲染指纹取舍
- [ ] `windows/gacc.ps1` 未验证
- [ ] （可选）每账户独立 `FONTCONFIG_FILE`；双内核分流

## 10. 风险清单

| 风险 | 影响 | 处置 |
|---|---|---|
| 同内核 → 同 TLS/渲染指纹 | 关联概率高于预期 | 双内核/双版本分流 |
| 时区与出口 IP 地理不匹配 | 反而更可疑 | 人设已锁美西，出口也必须选美西 |
| Google 要求手机验证 | 多号同机触发 | 这是运营问题，非技术可解 |
| 沙箱开启失败的环境 | 白页 | 启动时探测 + 自动降级并提示 |
| 部署脚本 bug 导致「装了但跑不起来」 | 复制部署失败 | 修 §9 前两条后重跑自检 |

## 11. 给复核者的具体问题

1. §2 的威胁模型有没有高估或低估？「防不住」那份清单是否还有遗漏？
2. §4 的人设是否自相矛盾（语言/时区/UA/窗口尺寸之间）？会不会因为「太整齐」反而成为特征？
3. §5 的三档方案排序是否合理？有没有成本更低、收益更高的做法？
4. 有没有「看起来隔离了、其实没隔离」的地方？（共享 `runtime/`、共享字体、共享 X server、共享 DNS、同一 `machine-id`、同一 GPU 等）
5. §8 的修复是否覆盖了所有致命项？部署脚本还有哪些健壮性缺陷？
6. 是否有比「一账户一 profile」更省事的架构（每账户一 Windows 用户、每账户一 WSL 发行版、每账户一容器）？请给出取舍。
