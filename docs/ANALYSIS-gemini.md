# Google `/sorry/` 拦截案例归因与指纹人设评估

## 1. 归因排名与依据

### 归因占比排名（估算区间）

> 说明：Google 搜索反滥用系统（含前端网关限流与 BotGuard JS 遥测）的具体特征权重属于非公开黑盒，以下占比基于已知拦截时机（HTTP 请求层 vs JS 挑战层）与工程实测机制推导，非 Google 内部精确参数。

| 排名 | 维度 | 估算占比 | 触发层级与角色 |
| :--- | :--- | :--- | :--- |
| **1** | **出口 IP 信誉（AS31898 Oracle Cloud 机房段）** | **~65% – 75%** | **主触发器（一票否决级底座）**：决定请求直接进入高危桶（Data Center ASN） |
| **2** | **会话与行为状态（无 Cookie 全新 Profile + 冷启动直搜）** | **~20% – 25%** | **豁免缺失器**：缺少高信誉 Cookie（`NID` / `AEC` / `__Secure-ENID` / 登录态 `SID`）来抵消机房 IP 的默认拦截 |
| **3** | **浏览器指纹与配置异常** | **~5% – 10%** | **次级加权项 / 跨账号关联项**：对首包 HTTP 302 `/sorry/` 贡献极小，但在 BotGuard 校验、验证码难度及多账号防关联（登录态风控）中起负向作用 |

### 核心依据

1. **Google 搜索风控的分层顺序（关键时序证据）**：
   - 用户在地址栏输入 `google` 回车（触发 URL `https://www.google.com/search?client=firefox-b-d&channel=entpr&q=google&sei=...`），Google 在 **HTTP GET `/search` 阶段**即直接 302 重定向到 `/sorry/index`。
   - **时序证明**：如果是地址栏直接发起的首次搜索，浏览器在收到 `/sorry/` 之前甚至还没完整执行搜索结果页的 BotGuard 深度指纹脚本（Canvas/WebGL/Font 枚举/WebRTC API 探测）。即便先打开了 `https://www.google.com/` 首页再搜索，Oracle Cloud（`AS31898`，`129.146.0.0/16`）作为免费层（Always Free）与廉价 VPS 滥用重灾区，在 Google 的 IP 信誉库中常年处于 **低信誉机房段（Hosting/DC ASN）**。
   - 对此类 ASN，Google 搜索的默认策略是：**无有效高信誉 Cookie（如已通过验证的 `AEC`/`NID` 或已登录 Google 账号 Cookie）的请求，默认触发 `/sorry/` reCAPTCHA 验证**；即便用完全原生的 Windows Chrome 真机挂同一个 Oracle IP 裸奔无痕搜索，极大概率同样秒弹 `/sorry/`。
2. **全新 Profile 无 Cookie 的放大效应**：
   - Google 通过 `AEC`（防滥用 Cookie）、`NID`/`__Secure-ENID` 以及登录态 Cookie 为可信会话放行。全新 Profile（零历史 Cookie）+ 机房 IP = 「未知客户端从已知爬虫网段发起搜索」，直接命中网关基础规则。
3. **`client=firefox-b-d&channel=entpr` 参数的信息量解析**：
   - `client=firefox-b-d`：Firefox 官方内置 Google 搜索插件的标准 partner code（`b-d` 代表 browser-default）。本身是正常 Firefox 流量标志。
   - **`channel=entpr`（高信息量细节）**：当 Firefox 检测到启用了企业策略（即 [`firefox/distribution/policies.json`](../firefox/distribution/policies.json) 生效，`Services.policies.status === ACTIVE`）时，Firefox 搜索服务会自动在默认搜索请求中注入 `channel=entpr`（Enterprise Channel）。
   - **风控含义**：它在 HTTP URL 层直接向 Google 明牌宣告 **「这是一台受 `policies.json` 集中管控的 Firefox 实例」**。单凭 `channel=entpr` 不会导致住宅 IP 被封（真实企业大量存在），但在 **「Oracle 机房 IP + Linux X11 + 无企业域登录态 + 多个账号全部带 `channel=entpr`」** 的场景下，它既增加了「自动化/批量受控环境」的特征，又成为了所有账户共用的固定标签。
   - `sei=...`：Google 首页或客户端生成的 Search Event ID，属正常跳转参数。

---

## 2. 现有「指纹人设」逻辑逐项评估

这套工具的设计意图是「同机多账号防关联」，但部分改动混淆了 **「防追踪扩展的隐私硬化」** 与 **「拟真多账号防关联」**，导致造出了罕见甚至异常的客户端特征。

| 改动项 | 评级 | 评估与依据 |
| :--- | :--- | :--- |
| **1. 时区 (`America/Los_Angeles`) 与 IP 地理 (`Phoenix`) 差 1 小时** | **中性（搜索阶段） / 轻度有害（高敏登录风控）** | **注意夏令时细节**：案例发生时间为 `2026-11-12`（11 月第一个周日之后，美国已结束夏令时进入冬令时）：此时 LA 是 `UTC-8`（PST），Phoenix 全年不实行夏令时是 `UTC-7`（MST），确实相差 **1 小时**（若在夏令时期间 3–11 月，两者同为 `UTC-7` 差 0 小时）。<br>同属美西邻州、1 小时时差在真实网络（跨州 VPN、差旅、移动热点、骨干网 Anycast 路由就近出口）中常见，不会单独触发 `/sorry/`；但 `Intl.DateTimeFormat().resolvedOptions().timeZone` 报 `America/Los_Angeles` 而 IP 在 Arizona，属于不必要的长期低分摩擦项。 |
| **2. Linux UA (`X11; Linux x86_64`) + 云机房 IP (`AS31898`)** | **有害（强负向组合）** | 绝大多数无头爬虫、Docker 容器、Playwright/Selenium 集群默认就是 `Linux x86_64` + 机房 IP。当 `X11; Linux x86_64` 与 `AS31898 (Oracle Cloud)` 同时出现且伴随软件渲染 GPU（WSLg 下通常是 `llvmpipe` 或 `D3D12` 虚拟化后端）时，在反爬模型中高度吻合「云端 Linux 自动化容器」画像。 |
| **3. 强制 `DPR=1.25` 配 `4000x1440` 屏幕** | **有害（显式暴露非整数缩放与怪异 CSS 视口）** | 物理/虚拟根窗口 `4000x1440` 本身已是极罕见的非标分辨率（既不是 `3440x1440` 也不是 `3840x1600`/`5120x1440`）。强制设 `layout.css.devPixelsPerPx = 1.25` 后，Firefox 暴露给 JS 的 `window.screen.width x height` 会变成 **`3200 x 1152`**（`4000/1.25 x 1440/1.25`），搭配 `devicePixelRatio = 1.25`。在 Linux X11 下，`3200x1152 @ 1.25x` 属于全球万里挑一的孤本指纹，不仅没起到混入主流办公机的作用，反而让这套环境在屏幕维度上极具辨识度。 |
| **4. 只暴露 19 个字体家族（系统共 266）** | **无害但无用（对降拦截） / 轻度有害（对防关联）** | 网页 JS 无法直接运行 `fc-list`，只能通过测量候选字体列表的文本渲染宽度/Canvas 来探测「已知常见字体是否存在」。[`bin/gen-fonts.sh`](../bin/gen-fonts.sh) 的白名单只保留了 DejaVu、Noto CJK、Liberation 等 Linux 开源字体，完全不含 Windows/macOS 常见字体（哪怕安装了 `ttf-mscorefonts-installer` 也会被过滤）。19 个家族对最小化安装的 Linux 桌面不算物理不可能，但它存在两个问题：<br>1) 各账户必含相同的 6 个基础字体文件，且仅在几款开源字体间排列组合，探测脚本眼里依然是典型的「精简版 Linux 容器字体集」；<br>2) 限制字体无助于改善机房 IP 触发的 `/sorry/`。 |
| **5. 关闭 WebRTC（`media.peerconnection.enabled=false`）+ 关闭 `media.navigator.enabled=false`** | **有害（高辨识度篡改特征）** | 见 [`etc/user.js.tmpl:18`](../etc/user.js.tmpl#L18) 和 [`bin/gacc:126`](../bin/gacc#L126)：<br>1) `media.peerconnection.enabled = false` 会导致 `window.RTCPeerConnection === undefined`；<br>2) `media.navigator.enabled = false` 会导致 HTTPS 下 `navigator.mediaDevices === undefined`。<br>原生 Firefox 160 正常用户**绝不会**缺失这两个核心 Web API。BotGuard 等风控脚本只需检查 `'RTCPeerConnection' in window` 和 `'mediaDevices' in navigator` 即可 100% 判定该浏览器经过了人为的 `about:config` 隐私/反爬改装。更关键的是：**你已经设了 `media.peerconnection.ice.proxy_only = true`**，WebRTC 流量本来就已经强制走 SOCKS5 代理且不会泄漏宿主机中国移动 IP，再把整个 API 删掉纯属画蛇添足。 |
| **6. 关闭 captive portal / 遥测 / 自动更新（通过 `user.js` 与 `policies.json`）** | **页面不可见部分无害，但 `policies.json` 衍生特征有害** | **页面能否看到的精确边界**：<br>- **页面完全看不到（无害）**：`network.captive-portal-service.enabled`、`network.connectivity-service.enabled`、`toolkit.telemetry.*`、`datareporting.*`、`app.normandy.*`、`identity.fxaccounts.enabled`、`DisableAppUpdate` 等均为浏览器特权层（Chrome/Parent 进程）配置，普通网页 JS **没有 API 可读取**。<br>- **页面/服务端能直接看到的泄漏点（有害）**：<br>  1) 如前所述，因为使用了 [`etc/policies.json`](../etc/policies.json) 关更新/装扩展，导致默认搜索 URL 携带 `channel=entpr`；<br>  2) `browser.search.suggest.enabled = false` 让用户在地址栏输入时零 `/complete/search` 联想请求，直接敲回车发 `/search`，行为序列比普通用户少一步交互。 |
| **7. `8 核 + 19 字体 + 4000 宽 (CSS 3200x1152)` 组合稀有度** | **有害（缩小匿名集，违背防关联初衷）** | [`bin/gacc:48`](../bin/gacc#L48) 注释写着「不用稀有组合：稀有组合会把匿名集缩小，反而更好被认出来」，但实际运行结果恰恰掉进了**极小匿名集**：所有账户共享同一个 `4000x1440` WSLg X11 根窗口、同一个 WebGL Renderer（WSLg 虚拟显卡/llvmpipe）、同一个缺失 `RTCPeerConnection`/`mediaDevices` 的特征、同一个 `Firefox 160.0`（注意：160 并不是当前主流真实版本号，若为修改或远期测试版更扎眼）。在这些罕见不变量面前，把核数从 4 改到 8、DPR 从 1 改到 1.25，根本无法阻止 Google 识别出「这是同一台 WSLg 机器切出来的不同 Profile」。 |

---

## 3. 真正能降低触发率的改动 vs 无效/有害改动

### 真正能降低触发率的改动（按投入产出比排序，Top 5）

1. **【最高优先级】更换出口 IP 类型：从机房 ASN（AS31898 Oracle）换为住宅/原生 ISP 代理，或为出站 Google 流量启用 Cloudflare Warp / 干净的双栈出口**
   - **依据**：65%–75% 的问题是 `AS31898` 机房段本身被 Google 标记。如果不换掉数据中心 IP，改任何浏览器参数都无法避免冷启动搜索弹 `/sorry/`。
   - **落地做法**：
     - 方案 A（推荐）：为每个账户绑定固定的**静态住宅 ISP 代理（Static Residential / ISP Proxy）**（如 AT&T / Comcast / Verizon / Frontier 等家庭宽带 ASN）。
     - 方案 B（零成本缓解，若仍在 Oracle VPS 上自建代理）：在 Oracle VPS 服务端为发往 `*.google.com` 的流量套一层 **Cloudflare WARP（WireGuard 出站）** 或启用干净的 IPv6（注：Oracle IPv6 同样可能受限，WARP 对 Google 搜索放行率显著高于裸 Oracle IPv4）。
2. **【高性价比】保持 Profile 的 Cookie 持久化与预热（不要每次冷启动直奔地址栏裸搜）**
   - **依据**：Google 对携带有历史信誉 Cookie（尤其是已通过一次验证的 `AEC`、`NID` 或已登录 Google 账号）的会话容忍度远高于空白 Profile。
   - **落地做法**：
     - 首次遇到 `/sorry/` 时，手动点过一次 reCAPTCHA，让 Google 写入 `AEC` / `NID` Cookie 并正常登录对应 Google 账号；
     - 确认 [`etc/user.js.tmpl`](../etc/user.js.tmpl) 中**没有**开启 `privacy.sanitize.sanitizeOnShutdown` 或 `network.cookie.lifetimePolicy = 2`（目前模板未清 Cookie，保持即可）。一旦账号登录态建立且 IP 固定，后续同 Profile 触发 `/sorry/` 的概率会断崖式下降。
3. **【高性价比】恢复 `RTCPeerConnection` 与 `mediaDevices` API，仅用 `proxy_only` 防泄漏**
   - **依据**：消除网页 JS 100% 可检测的「阉割版浏览器」硬伤，同时不牺牲 IP 防泄漏安全性。
   - **落地做法**：
     - 在 [`bin/gacc:126`](../bin/gacc#L126) 删除 `user_pref("media.navigator.enabled", false);`（不授权摄像头权限时，未授权页面调用 `enumerateDevices()` 本就只返回空标签占位，不会泄漏硬件序列号，但 API 对象必须存在）。
     - 在 [`etc/user.js.tmpl:17-19`](../etc/user.js.tmpl#L17-L19) 将 WebRTC 配置改为：
       ```javascript
       user_pref("media.peerconnection.enabled", true);
       user_pref("media.peerconnection.ice.proxy_only", true);
       user_pref("media.peerconnection.ice.default_address_only", true);
       user_pref("media.peerconnection.ice.no_host", true);
       ```
       这样 `window.RTCPeerConnection` 正常存在，且所有 ICE 候选强制走 SOCKS5 代理、彻底屏蔽本地局域网/宿主机 IP。
4. **【中优先级】从代理出口自动同步 Persona 的时区（消除 IP 与 TZ 错位）**
   - **依据**：既然每个账户已经有独立的 `proxy.conf`，工具完全可以在启动或 `--proxy` 设置时通过代理查询一次出口 IP 的真实 `timezone`，写入 `persona.conf`，而不是盲目随机分配导致 Phoenix IP 配上 LA/Honolulu/Anchorage 时区。
   - **落地做法**：在 [`bin/gacc`](../bin/gacc) 的 `write_proxy` 或 `prepare_profile` 中，当设置了代理时执行一次：
     ```bash
     tz="$(curl -fsSL -m 5 --proxy "$spec" https://ipinfo.io/timezone 2>/dev/null || true)"
     ```
     若获取到合法时区（如 `America/Phoenix`），直接将 `persona.conf` 的 `tz=` 锁定为该值。
5. **【中优先级】修正 WSLg 的怪异屏幕尺寸泄漏与 `channel=entpr` 标记**
   - **依据**：`4000x1440` 叠加 `DPR=1.25` 算出的 `screen.width=3200, screen.height=1152` 是所有账户共用的强异常指纹；`policies.json` 触发的 `channel=entpr` 是不必要的受控标志。
   - **落地做法**：
     - 将 `PERSONAS` 中的 `dpr` 固定为 `1`（在 Linux X11 下，`devicePixelRatio=1` 占压倒性多数，避免产生 `3200x1152` 这种非整除怪异 `screen` 尺寸）；或者在独立 Xephyr/Xvfb 实例中指定标准分辨率（如 `1920x1080` 或 `2560x1440`）。
     - 移除 `firefox/distribution/policies.json`（其中绝大部分开关如 `DisableTelemetry`、`DisablePocket`、`DisableFirefoxAccounts`、`DisableFirefoxStudies` 已经在 [`etc/user.js.tmpl`](../etc/user.js.tmpl) 里通过 `user_pref` 实现了），避免 Firefox 自动往 Google 搜索 URL 里塞 `channel=entpr`。

### 无效甚至有害的改动（建议停止或回退）

- **有害**：`media.peerconnection.enabled = false` 和 `media.navigator.enabled = false`（直接暴露篡改痕迹）。
- **有害**：在 `PERSONAS` 里塞入 `America/Anchorage`、`Pacific/Honolulu` 并随机配给美国本土机房 IP（夏威夷/阿拉斯加人口占比极低，且与美西/美中代理 IP 严重冲突）。
- **有害**：在 `4000x1440` 的 X11 屏幕下混用 `DPR=1` 和 `DPR=1.25`（制造出 `4000x1440` 和 `3200x1152` 两种同样极其罕见的 `window.screen` 尺寸）。
- **无用**：靠关掉 `captive-portal`、`telemetry`、`dns.disablePrefetch` 来「防 Google 风控」——这些只会减少 Firefox 发往 Mozilla 的后台流量，对 Google 页面完全透明，不影响 Google 判定。

---

## 4. 「自相矛盾、一眼假」的硬性组合排查

以下组合在真实自然人设备分布中几乎不可能同时出现，风控脚本或跨账号关联模型极易识别：

1. **【硬性矛盾 1】现代桌面 Firefox 160 却同时缺失 `window.RTCPeerConnection` 与 `navigator.mediaDevices`**
   - 正常 Firefox 只有在开启极端隐私模式或手动修改 `about:config` 时才会删掉这两个全局接口，而你的配置又显式设了 `privacy.resistFingerprinting = false`。这种「既不是 Tor/RFP 标准形态、又残缺核心媒体 API」的状态是典型的**自定义反检测脚本痕迹**。
2. **【硬性矛盾 2】`Linux x86_64` + WSLg 虚拟渲染器（`llvmpipe` / `Mesa D3D12`）+ 多账户共享 `4000x1440` 根屏幕**
   - [`bin/gacc:290`](../bin/gacc#L290) 自己也注明了：`跨账户仍然相同的部分：Canvas / WebGL / GPU 字符串 / TLS 与 HTTP2 指纹`。
   - 当账户 1 报 `screen: 4000x1440 @ DPR 1, GPU: Mesa D3D12/llvmpipe`，账户 2 报 `screen: 3200x1152 @ DPR 1.25, GPU: Mesa D3D12/llvmpipe`（注意 `3200 * 1.25 = 4000`，`1152 * 1.25 = 1440`，乘积完全相等！），任何把 `screen.width * devicePixelRatio` 还原为物理像素的风控逻辑，一眼就能算出两个账户跑在同一个 `4000x1440` 的物理/虚拟帧缓冲上。
3. **【硬性矛盾 3】`rv:160.0` 版本号异常**
   - 需核实便携版 Firefox 的真实版本来源：截至 2026 年，Mozilla 官方正式版（Release）版本号远未达到 `160.0`。如果这是通过 `general.useragent.override` 或自编译修改出的虚构版本号（`Firefox/160.0`），而 TLS 指纹（JA3/JA4）、HTTP/2 Settings 帧和 JS 引擎特征却对应旧版内核，属于**一票否决级的假 UA**。
4. **【次级矛盾】`8 核 + 19 个字体家族 + 4000x1440 超宽屏`**
   - 「8 核 + 19 个字体」本身在 Linux 容器/极简桌面（如 Arch/i3wm）上不算物理矛盾；但「用着 4000x1440 超宽带鱼屏的 Linux 桌面用户，系统里却只有 19 个基础字体且渲染后端是 WSLg 虚拟显卡 + 走 Oracle 机房 IP」，画像高度收敛到开发者宿主机上的 WSL2 虚拟机。

---

## 5. 一句话结论

**这次 `/sorry/` 拦截 70% 以上是「Oracle 机房 IP（AS31898）+ 全新无 Cookie 会话」直接触发的网关层拦截（属于 IP 问题），但你现有的指纹人设逻辑（删 WebRTC/`mediaDevices` API、4000x1440 乘 1.25 缩放、随机分配与 IP 不符的时区、`policies.json` 暴露 `channel=entpr`）不仅对绕过拦截毫无帮助，反而在 JS 层把浏览器改成了「一眼假的受控改装实例」，并因共享 `4000x1440` 物理像素和 WebGL 渲染器而无法实现真正的多账户防关联。**
