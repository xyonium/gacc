# 第五轮独立复核报告（REVIEW-5）

> **复核方法声明**：本报告所有结论均通过 `read`、`grep`、`bash`（含 Firefox `--headless --screenshot` 实测、本地 Python HTTP/JS 探针、WebGL 全参数对比、`xwininfo`/`xrandr` 检查、`libxul.so` 反汇编与字符串表取证）独立验证，每条结论均附精确 `文件:行号` 或实测命令输出。

---

## 一、本轮声称修好的四条：逐条独立复核结果

| 编号 | 声称修复项 | 复核结论 | 关键判定摘要 |
|---|---|---|---|
| **修复 1** | `intl.accept_languages` 改为 `"en-US, en"` | **部分通过（存 2 处未闭环漏洞）** | Headless 渲染与截图实测证实 `"en-US, en"` 确实消除了 `"en;q=0.9"` 污染与 `RangeError`，且 `ACC_RE` 允许空格；但 **`profiles/acc02/prefs.js:105` 仍残留 `"en-US,en;q=0.9"`**，且 **`bin/gacc:63` 与 `bin/gacc:106` 的默认变量 `P_ACCEPT` 仍是 `"en-US,en;q=0.9"`**（新账号或 `--new-fp` 会再次写入错误值）。 |
| **修复 2** | 新增 `--purge-legacy-prefs` 清理 `prefs.js` 5 个残留项 | **部分通过（指定 5 项已清且幂等，但漏清另外 7 项历史残留 + 存在 `prepare_profile` 副作用）** | 正则精确锚定行首与完整键名，不会误伤其它项，重复执行幂等；代码中列出的 5 项确实已从 `acc01..03/prefs.js` 清零。但上一轮声称“已恢复原生”的另外 **7 个旧 pref**（`browser.search.suggest.enabled`、`network.dns.disablePrefetch` 等）仍固化在 `acc01..03/prefs.js` 中未清理。 |
| **修复 3** | 移除 `XDG_RUNTIME_DIR` 覆盖，恢复 WebGL | **通过** | `grep -n XDG_RUNTIME_DIR bin/gacc` 确认为 0 命中；实测覆盖 `XDG_RUNTIME_DIR` 时 `gfxtest glx -w` 报 `ERROR: Could not connect to wayland display`，不覆盖时正常输出 `TEST_TYPE=EGL` 且浏览器内 `WebGL 1 / WebGL 2` 全部恢复为 `true`。 |
| **修复 4** | 补 `security.sandbox.socket.process.level = 0` + `MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1` | **部分通过（解决了 socket 进程崩溃，但有 2 个缺陷）** | 仅在 `unshare` 不可用时写入 `user.js`；但：① **`bin/gacc:228-231` 在 `unshare` 恢复分支漏删了 `prefs.js` 里的 `socket.process.level`**（导致切回正常终端后 socket 沙箱永久关闭）；② **漏配 `MOZ_DISABLE_RDD_SANDBOX=1` / `UTILITY` / `GMP`**，导致受限环境下 RDD 等子进程依然报 `uid_map: EACCES` 并以 `SIGSEGV (signal 11)` 崩溃。 |

---

### 1.1 修复 1 详细取证：`intl.accept_languages` 改为 `"en-US, en"`

1. **三个 profile 的 `persona.conf` / `user.js` / `prefs.js` 实际值核查**：
   - 执行 `grep -n "accept=" profiles/acc0{1,2,3}/persona.conf` 与 `grep -n "intl.accept_languages" profiles/acc0{1,2,3}/{user.js,prefs.js}`，输出：
     ```text
     profiles/acc01/persona.conf:2:accept=en-US, en
     profiles/acc02/persona.conf:2:accept=en-US, en
     profiles/acc03/persona.conf:2:accept=en-US, en
     profiles/acc01/user.js:11:user_pref("intl.accept_languages", "en-US, en");
     profiles/acc01/prefs.js:114:user_pref("intl.accept_languages", "en-US, en");
     profiles/acc02/user.js:11:user_pref("intl.accept_languages", "en-US, en");
     profiles/acc02/prefs.js:105:user_pref("intl.accept_languages", "en-US,en;q=0.9");
     profiles/acc03/user.js:11:user_pref("intl.accept_languages", "en-US, en");
     profiles/acc03/prefs.js:104:user_pref("intl.accept_languages", "en-US, en");
     ```
   - **发现问题 A**：`profiles/acc02/prefs.js:105` 依然残留着旧值 `user_pref("intl.accept_languages", "en-US,en;q=0.9");`（因为 `acc02` 在修改 `user.js` 后尚未重新启动写回 `prefs.js`，且 `--purge-legacy-prefs` 未清理该项；好在 `acc02/user.js:11` 已是 `"en-US, en"`，下次通过 `gacc` 启动 `acc02` 时会被 `user.js` 覆盖）。
2. **`load_persona` 正则 `ACC_RE` 与默认值核查（`bin/gacc:63,91,105-110`）**：
   - `bin/gacc:105`：`local ACC_RE='^[A-Za-z0-9,;=.q -]+$'` —— 字符集末尾 `-` 之前**确实包含字面量空格**，因此当 `persona.conf` 已写入 `accept=en-US, en` 时，`[[ "$v" =~ $ACC_RE ]]`（`bin/gacc:110`）匹配成功，不会退回默认值。
   - **发现问题 B（高危未闭环）**：`bin/gacc` 里两处硬编码默认值**根本没改**！
     - `bin/gacc:63`：`P_ACCEPT="en-US,en;q=0.9"`（被 `gen_persona()` 在 `bin/gacc:91` `accept=$P_ACCEPT` 直接写入新生成的 `persona.conf`！）
     - `bin/gacc:106`：`P_LOCALE="en-US"; P_ACCEPT="en-US,en;q=0.9"; P_TZ=""; P_CORES="8"; P_DPR="1"`（`load_persona()` 的初始回退值）
     - 同时仓库根目录下的部署脚本 `deploy-gacc.sh:378,420,421` 不仅 `P_ACCEPT="en-US,en;q=0.9"` 没改，连 `ACC_RE='^[A-Za-z0-9,;=.q-]+$'`（`deploy-gacc.sh:420`）也没有空格！
     - **后果**：只要新建第 4 个账号（`./bin/gacc 4`）或对现有账号执行 `./bin/gacc <N> --new-fp`（`bin/gacc:415-419` 删除 `persona.conf` 并调用 `gen_persona`），生成的 `persona.conf` 又会变回 `accept=en-US,en;q=0.9`，Bug 立即复发！
3. **Headless + `--screenshot` 实测验证**：
   - 使用 `profiles/acc03/user.js`（含 `user_pref("intl.accept_languages", "en-US, en");`）运行：
     ```bash
     ./firefox/firefox --headless --profile "$TMP_DIR/prof" --screenshot /tmp/out_rev5.png file:///tmp/x.html
     ```
   - 截图 `/tmp/out_rev5.png`（1366×768 PNG）实测渲染输出为：
     ```json
     {
       "language": "en-US",
       "languages": [
         "en-US",
         "en"
       ],
       "canonical": "en-US|en",
       "error": null
     }
     ```
   - **结论**：当实际生效值为 `"en-US, en"` 时，`navigator.languages` 与 `Intl.getCanonicalLocales()` 完全恢复原生正常表现；但必须把 `bin/gacc:63` 和 `bin/gacc:106` 的 `P_ACCEPT` 同步改为 `"en-US, en"` 才能彻底杜绝复发。

---

### 1.2 修复 2 详细取证：`--purge-legacy-prefs`

1. **代码与正则安全性审计（`bin/gacc:317-326`）**：
   ```bash
   317: cmd_purge_legacy() {
   318:   local prof="$1" f n=0 before
   319:   f="$prof/prefs.js"
   320:   [[ -f "$f" ]] || { echo "  （还没有 prefs.js，无需清理）"; return 0; }
   321:   before="$(wc -l < "$f")"
   322:   grep -vE '^user_pref\("(layout\.css\.devPixelsPerPx|dom\.maxHardwareConcurrency|media\.navigator\.enabled|media\.peerconnection\.ice\.(proxy_only|no_host))"' \
   323:       "$f" > "$f.tmp" && mv "$f.tmp" "$f"
   324:   n=$(( before - $(wc -l < "$f") ))
   325:   echo "  ✔ 账户 $(basename "$prof"): 清掉 $n 行残留（$before → $(wc -l < "$f")）"
   326: }
   ```
   - **是否会误删别的行？不会。** 正则以 `^user_pref\("` 开头、以闭合双引号 `"` 结尾，且所有 `.` 均已转义为 `\.`。因此它只会精确匹配这 5 个完整 pref 名，绝不会误伤 `media.navigator.permission.disabled` 或 `media.gmp-*` 等其它项。
   - **是否幂等？是。** 本机对 `acc01..03` 再次执行 `./bin/gacc {1,2,3} --purge-legacy-prefs`，输出：
     ```text
     ✔ 账户 acc01: 清掉 0 行残留（233 → 233）
     ✔ 账户 acc02: 清掉 0 行残留（225 → 225）
     ✔ 账户 acc03: 清掉 0 行残留（219 → 219）
     ```
2. **三个 profile 的 `prefs.js` 现状核查**：
   - 针对上述 5 个 pref（`layout.css.devPixelsPerPx`、`dom.maxHardwareConcurrency`、`media.navigator.enabled`、`media.peerconnection.ice.proxy_only`、`media.peerconnection.ice.no_host`），在 `profiles/acc0{1,2,3}/prefs.js` 中 `grep` 结果确认为 **0 命中**（已全部清除）。
   - **但发现遗漏项（上一轮声称“已恢复原生”的另外 7 个旧 pref 仍残留在 `prefs.js` 中！）**：
     `grep` 实测证实，`AUDIT-summary.md:15-17` 声称“恢复原生（已生效）”的各条，加上早期的 `ice.default_address_only`，目前**全部还留在 `acc01..03/prefs.js` 里**：
     - `browser.search.suggest.enabled = false`：`acc01/prefs.js:57`、`acc02/prefs.js:58`、`acc03/prefs.js:57`
     - `javascript.use_us_english_locale = true`：`acc01/prefs.js:115`、`acc02/prefs.js:106`、`acc03/prefs.js:105`
     - `media.peerconnection.ice.default_address_only = true`：`acc01/prefs.js:126`、`acc03/prefs.js:116`
     - `network.dns.disablePrefetch = true`：`acc01/prefs.js:132`、`acc02/prefs.js:122`、`acc03/prefs.js:122`
     - `network.http.speculative-parallel-limit = 0`：`acc01/prefs.js:133`、`acc02/prefs.js:123`、`acc03/prefs.js:123`
     - `network.predictor.enabled = false`：`acc01/prefs.js:134`、`acc02/prefs.js:124`、`acc03/prefs.js:124`
     - `network.prefetch-next = false`：`acc01/prefs.js:135`、`acc02/prefs.js:125`、`acc03/prefs.js:125`
   - **发现代码结构副作用**：`bin/gacc:433` 在判断 `if (( PURGE ))`（`bin/gacc:436`）之前无条件调用了 `prepare_profile "$ACC"`。如果在不支持 `unshare` 的容器/沙箱里执行 `./bin/gacc 1 --purge-legacy-prefs`（或 `--doctor` / `--fp`），`prepare_profile` 会顺手把 `acc01/user.js` 改写为关闭沙箱状态。

---

### 1.3 修复 3 详细取证：移除 `XDG_RUNTIME_DIR` 覆盖

1. **代码核查**：
   - `grep -n "XDG_RUNTIME_DIR" bin/gacc` 无任何输出；查看 `bin/gacc:490-493`：
     ```bash
     490: RUNTIME="$ROOT/runtime/$(printf 'acc%02d' "$ACC")"
     491: export HOME="$RUNTIME/home" XDG_CONFIG_HOME="$RUNTIME/config" \
     492:        XDG_CACHE_HOME="$RUNTIME/cache" XDG_DATA_HOME="$RUNTIME/data"
     493: mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
     ```
     确已彻底移除 `XDG_RUNTIME_DIR="$RUNTIME/run"` 覆盖。
2. **`./firefox/gfxtest glx -w` 对照实测输出**：
   - **覆盖 `XDG_RUNTIME_DIR` 时**（`env XDG_RUNTIME_DIR=/tmp/fake_run ./firefox/gfxtest glx -w`）：
     ```text
     PCI_VENDOR_ID
     0x1414
     PCI_DEVICE_ID
     0x008e
     ERROR
     Could not connect to wayland display, WAYLAND_DISPLAY=wayland-0
     ```
   - **不覆盖 `XDG_RUNTIME_DIR` 时**（保持系统 `/run/user/1000`，运行 `./firefox/gfxtest glx -w`）：
     ```text
     PCI_VENDOR_ID
     0x1414
     PCI_DEVICE_ID
     0x008e
     DRI_DRIVER
     swrast
     VENDOR
     Mesa
     RENDERER
     llvmpipe (LLVM 15.0.7, 256 bits)
     VERSION
     4.5 (Compatibility Profile) Mesa 23.2.1-1ubuntu3.1~22.04.4
     TFP
     TRUE
     MESA_ACCELERATED
     FALSE
     TEST_TYPE
     EGL
     ```
   - **浏览器内 JS 探针实测**：移除覆盖后，`hasWebGL1: true`、`hasWebGL2: true`，彻底修复了此前 `WebGL 1/2 === null` 的顶级异常。

---

### 1.4 修复 4 详细取证：`security.sandbox.socket.process.level = 0` + `MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1`

1. **渲染结果与条件分支核查**：
   - `grep -n "security.sandbox" profiles/acc0{1,2,3}/user.js`：
     - `profiles/acc02/user.js:15-17` 与 `profiles/acc03/user.js:15-17` 均包含：
       ```javascript
       user_pref("security.sandbox.content.level", 0);
       user_pref("security.sandbox.gpu.level", 0);
       user_pref("security.sandbox.socket.process.level", 0);
       ```
     - `profiles/acc01/user.js:14-15` 为空（因为 `acc01/user.js` 是在宿主机正常终端 `unshare` 可用时渲染的）。
   - 查看 `bin/gacc:224-232` 与 `bin/gacc:486-487`：
     ```bash
     224:   if ! unshare --user --map-root-user true >/dev/null 2>&1; then
     225:     sandbox_blk=$'user_pref("security.sandbox.content.level", 0);\nuser_pref("security.sandbox.gpu.level", 0);\nuser_pref("security.sandbox.socket.process.level", 0);'
     226:   elif [[ -f "$prof/prefs.js" ]]; then
     227:     # 环境恢复了：只删我们自己写进去的那两行，不动用户在 about:config 里设的其它 sandbox 值
     228:     sed -i \
     229:       -e '/^user_pref("security\.sandbox\.content\.level", 0);$/d' \
     230:       -e '/^user_pref("security\.sandbox\.gpu\.level", 0);$/d' \
     231:       "$prof/prefs.js" 2>/dev/null || true
     232:   fi
     ```
     ```bash
     486: grep -qE '^[[:space:]]*user_pref\("security\.sandbox\.content\.level",[[:space:]]*0\)' "$PROF/user.js" 2>/dev/null \
     487:   && { export MOZ_DISABLE_CONTENT_SANDBOX=1; export MOZ_DISABLE_SOCKET_PROCESS_SANDBOX=1; }
     ```
   - 确认：确实只在 `! unshare --user --map-root-user true` 时才写入 `user.js` 并导出环境变量。
2. **实测发现的两个缺陷（副作用与遗漏）**：
   - **缺陷 1（`unshare` 恢复时漏删 `prefs.js` 中的 `socket.process.level`）**：
     看 `bin/gacc:227-231` 的注释和代码：“只删我们自己写进去的那两行”。作者在 `225` 行加了第 3 行 `security.sandbox.socket.process.level`，却**忘了在 `228-231` 行的 `sed -i` 里同步加上 `-e '/^user_pref("security\.sandbox\.socket\.process\.level", 0);$/d'`**！
     而查看 `profiles/acc03/prefs.js:141-142`：
     ```javascript
     141: user_pref("security.sandbox.content.level", 0);
     142: user_pref("security.sandbox.socket.process.level", 0);
     ```
     一旦 `acc03` 在受限环境跑过一次，`security.sandbox.socket.process.level = 0` 就被 Firefox 固化进了 `prefs.js:142`。之后哪怕用户回到支持 `unshare` 的正常终端启动，`bin/gacc:228-231` 只删掉了 `content.level`，**`socket.process.level = 0` 会永久残留在 `prefs.js` 中无法自动恢复**！
   - **缺陷 2（受限环境下仍有 RDD 子进程因沙箱崩溃）**：
     检索 `strings firefox/libxul.so | grep -E '^MOZ_DISABLE_[A-Z0-9_]*SANDBOX$'` 可知 Firefox 160 共有 6 个沙箱环境变量：
     `MOZ_DISABLE_CONTENT_SANDBOX`、`MOZ_DISABLE_SOCKET_PROCESS_SANDBOX`、`MOZ_DISABLE_RDD_SANDBOX`、`MOZ_DISABLE_UTILITY_SANDBOX`、`MOZ_DISABLE_GMP_SANDBOX`、`MOZ_DISABLE_GPU_SANDBOX`。
     仅导出 `CONTENT` + `SOCKET_PROCESS` 时，本机实测与 `profiles/acc03/firefox.log:37-38`（修复后最新一次运行日志）均出现：
     ```text
     [211892] Sandbox: writing /proc/self/uid_map: EACCES
     [Parent 211754, IPC I/O Parent] WARNING: process 211892 exited on signal 11
     ```
     实测将 `MOZ_DISABLE_RDD_SANDBOX=1 MOZ_DISABLE_UTILITY_SANDBOX=1 MOZ_DISABLE_GMP_SANDBOX=1` 一并加入 `bin/gacc:487` 后，`uid_map: EACCES` 与 `signal 11` 崩溃彻底归零。

---

## 二、专项评估（问题 5、6、7）

### 2.1 评估问题 5：Wayland vs X11 后端切换、截图问题与指纹差异

#### （1）为什么移除 `XDG_RUNTIME_DIR` 覆盖后 Firefox 改走了 Wayland？
- 在 `bin/gacc:485` 中写的是 `unset MOZ_ENABLE_WAYLAND`。
- 但在新版 Firefox（自 Firefox 121 起，含本机 160.0）中，当检测到 `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`（即 `/run/user/1000/wayland-0`）存在时，**默认就是启用 Wayland 后端**；`unset MOZ_ENABLE_WAYLAND` 只是使用默认值（即走 Wayland），并不会强制 X11！
- 之前之所以走 X11，完全是因为 `XDG_RUNTIME_DIR` 被错误指到了空的 `runtime/accXX/run`，导致连接 Wayland 失败后被动 fallback 到 X11（见 `profiles/acc01/firefox.log:1-2`）。

#### （2）有没有办法既保留 WebGL 又稳定跑 X11？
- **有，而且非常干净：把 `bin/gacc:485` 的 `unset MOZ_ENABLE_WAYLAND` 改为 `export MOZ_ENABLE_WAYLAND=0`（同时保留系统真实的 `XDG_RUNTIME_DIR=/run/user/1000` 不覆盖）！**
- **本机实测证据**：
  1. 在 `export MOZ_ENABLE_WAYLAND=0` + 系统默认 `XDG_RUNTIME_DIR=/run/user/1000` 下启动 Firefox：
     - `xwininfo -root -tree` 实测：`has_x11_window: true`（X11 工具可正常枚举、定位和截图窗口，`--class gacc-NN` 在 X11 下完全生效）；
     - `gfxtest glx -w` 实测：因为 `/run/user/1000/wayland-0` 依然可达，`gfxtest` 正常通过（`TEST_TYPE=EGL`）；
     - 浏览器 JS 探针实测：`hasWebGL1: true, hasWebGL2: true`，WebGL 1/2 100% 正常工作！

#### （3）Wayland 与 X11（`MOZ_ENABLE_WAYLAND=0`）对页面指纹有什么可观测差异？
本机用 Python HTTP + JS 探针分别在 **Wayland（默认）** 与 **X11（`MOZ_ENABLE_WAYLAND=0`）** 下启动真实窗口对比实测，结果如下：

| 观测维度 | Wayland 后端（当前默认） | X11 后端（`export MOZ_ENABLE_WAYLAND=0`） | 指纹与一致性评估 |
|---|---|---|---|
| `navigator.userAgent` | `Mozilla/5.0 (X11; Linux x86_64; rv:160.0) Gecko/20100101 Firefox/160.0` | `Mozilla/5.0 (X11; Linux x86_64; rv:160.0) Gecko/20100101 Firefox/160.0` | 完全相同（Linux Firefox 在 Wayland 下 UA 固定仍写 `X11; Linux x86_64`） |
| **`window.screenX` / `window.screenY`** | **永远恒为 `0, 0`**（实测 `screenX: 0, screenY: 0`） | **真实窗口坐标**（实测 `screenX: 422, screenY: -23` 等非零值） | Wayland 协议层禁止客户端获知全局坐标，因此非最大化窗口 `screenX/Y` 恒为 `0` 是 Wayland 显著特征；X11 则报告真实坐标 |
| **`screen.width × screen.height`** | 取决于 `wl_output` 逻辑缩放：单屏时 `1920x1200`；当宿主机 2880×1920 屏按 Wayland 2x 整数缩放映射时为 **`1440x960`** | 取决于 Xwayland `xrandr`：单屏 `rdp-0` 为 **`1920x1200`**；双屏拼接时若跨屏或旧版无 RandR 则受总 root 尺寸影响 | **`1920x1200`（标准 16:10 WUXGA 分辨率）在桌面人群中远比 `1440x960`（3:2 罕见逻辑分辨率）更常见、匿名集更大** |
| `window.outerWidth × outerHeight` / `innerHeight` | `1332 × 1092`（`innerHeight: 955`） | `1356 × 1137`（`innerHeight: 918`） | 因 CSD（客户端装饰阴影边距）在 Wayland 与 X11 下相差 24px，属正常平台行为 |
| WebGL 参数与扩展列表 | 32 个 WebGL1 扩展、19 个 WebGL2 扩展 | 32 个 WebGL1 扩展、19 个 WebGL2 扩展 | **22 项核心参数与扩展列表逐字完全相同** |
| X11 窗口管理 / 截图工具兼容性 | **不可见**（`xwininfo` 找不到窗口） | **完全可见** | X11 下自动化运维/截图工具全部可用 |

- **建议**：**强烈建议在 `bin/gacc:485` 将 `unset MOZ_ENABLE_WAYLAND` 改为 `export MOZ_ENABLE_WAYLAND=0`**。这样既 100% 保留了 WebGL 1/2，又恢复了 X11 工具截图与窗口控制，同时让 `screen` 稳定报告主流的 `1920x1200`（避免 Wayland 下出现罕见的 `1440x960` 及 `screenX/Y === 0`）。

---

### 2.2 评估问题 6：`llvmpipe, or similar` vs `Generic Renderer` 的根因与可观测差异

#### （1）二进制级根因查明：为什么全新 profile 报 `llvmpipe, or similar`，而用户终端报 `Generic Renderer`？
通过对 `firefox/libxul.so` 的 `.text` 段（VMA `0x7c13331`–`0x7c1415a`）反汇编及对 `profiles/acc01/firefox.log:93` 的取证，真相已经 **100% 水落石出**：

1. **证据 1（`profiles/acc01/firefox.log:93` 现场日志）**：
   用户在自己的真实 WSLg 终端启动 `acc01` 时，`firefox.log` 第 93 行留下了铁证：
   ```text
   Crash Annotation GraphicsCriticalError: |[C0][GFX1-]: Couldn't sanitize GL_RENDERER "D3D12 (Intel(R) Iris(R) Xe Graphics)" (t=75.5409) [GFX1-]: Couldn't sanitize GL_RENDERER "D3D12 (Intel(R) Iris(R) Xe Graphics)"
   ```
2. **证据 2（`firefox/libxul.so` 反汇编 `SanitizeRenderer` 逻辑）**：
   Firefox 默认开启 `webgl.sanitize-unmasked-renderer = true`，所有暴露给网页的 `RENDERER` 和 `UNMASKED_RENDERER_WEBGL` 都要经过 `SanitizeRenderer()` 函数（位于 `libxul.so` `0x7c13200`–`0x7c14190`）清洗：
   - 函数入口（`0x7c13331`）先把默认返回值设为 `"Generic Renderer"`（`.rodata` `0xfb07a0`）；
   - 如果底层 `GL_RENDERER` 命中了内置已知规则（例如 `swrast` 的 `"llvmpipe (LLVM 15.0.7, 256 bits)"` 命中了 `0x1019c0a` 的 `"llvmpipe"`），则在 `0x7c13713` 拼接上 `", or similar"`（`.rodata` `0xfb07b1`），输出 **`"llvmpipe, or similar"`**；
   - 如果底层 `GL_RENDERER` **未能命中任何内置正则规则**——在用户的正常 WSLg 环境下，Mesa 走了硬件加速的 `d3d12` Gallium 驱动，底层返回的 `GL_RENDERER` 是 **`"D3D12 (Intel(R) Iris(R) Xe Graphics)"`**（而在 `libxul.so` 中检索 `"D3D12"` 为 0 命中，Firefox 的 Linux 白名单只认识 `"Mesa Intel(R)..."` 而不认识 WSLg 特有的 `"D3D12 (...)"` 前缀！）——函数就会跳到 `0x7c13ffe` 打印 `Couldn't sanitize GL_RENDERER "D3D12 (Intel(R) Iris(R) Xe Graphics)"`，并直接返回初始兜底值 **`"Generic Renderer"`**！
   - 本机对照实测：当在 `user.js` 中临时设 `webgl.sanitize-unmasked-renderer = false` 时，`UNMASKED_RENDERER_WEBGL` 立即不再返回 `"llvmpipe, or similar"` 或 `"Generic Renderer"`，而是直接暴露底层原始字符串 `"llvmpipe (LLVM 15.0.7, 256 bits)"`（或在用户环境下暴露 `"D3D12 (Intel(R) Iris(R) Xe Graphics)"`）。

#### （2）独立判断：渲染器字符串能否作为“浏览器被改装”的证据？还会不会有别的可观测差异？
- **绝不能作为“浏览器被 `gacc` 改装”的证据**：
  无论是 `"Generic Renderer"` 还是 `"llvmpipe, or similar"`，**100% 都是未修改的原生 Firefox 160 在 `webgl.sanitize-unmasked-renderer=true`（默认值）下的官方标准输出**。全新空 profile 在相同环境下跑出的字符串与 `gacc` 完全一致。
- **但它会暴露“宿主机底层图形栈类型”（环境层信号），且伴随其它可观测差异**：
  1. **在受限沙箱环境（跑出 `"llvmpipe, or similar"`）**：代表当前走的是 CPU 软件光栅化（`swrast`）。除了字符串本身代表无硬件 GPU 外，WebGL 帧率/着色器耗时等性能侧信道会表现为纯 CPU 渲染。
  2. **在用户的正常 WSLg 终端（跑出 `"Generic Renderer"`）**：因为走的是 `D3D12 (Intel(R) Iris(R) Xe Graphics)` 硬件加速，WebGL 渲染性能是真实的 Intel Iris Xe 核显水平，且绝对不要去关 `webgl.sanitize-unmasked-renderer`——因为一旦关掉，网页就会在 `Linux x86_64` UA 下直接看到 `"UNMASKED_VENDOR_WEBGL": "Microsoft Corporation"` 和 `"UNMASKED_RENDERER_WEBGL": "D3D12 (Intel(R) Iris(R) Xe Graphics)"`，反而直接暴露 WSL2 虚拟机身份！保持 Firefox 原生默认的 `"Generic Renderer"` 反而帮用户隐藏了 `"D3D12"` 字样。
  3. **其它 WebGL 可观测参数对比**：本机实测 `MAX_TEXTURE_SIZE: 16384`、`MAX_VIEWPORT_DIMS: [16384, 16384]`、`MAX_COMBINED_TEXTURE_IMAGE_UNITS: 192`、`MAX_VERTEX_UNIFORM_VECTORS: 4096`、`MAX_SAMPLES: 4`、32 个 WebGL1 扩展与 19 个 WebGL2 扩展，在原生空 profile 与 `gacc` profile 之间**完全一致（0 差异）**。

---

### 2.3 评估问题 7：当前方案中剩余的全部“非原生”改动清单与去留建议

以下按 **`etc/user.js.tmpl` / `bin/gacc` 显式改动** 与 **`profiles/acc01..03/prefs.js` 历史残留改动** 两部分列出完整清单：

#### A. 当前 `etc/user.js.tmpl` 与 `bin/gacc` 仍在生效的非原生改动

| 类别 | 具体改动项（文件:行号） | 页面/服务端可见性 | 实际收益 | 建议保留？ |
|---|---|---|---|---|
| **环境变量** | `export TZ="$P_TZ"`（`bin/gacc:497`） | **页面可见**（`Intl` / `Date` 时区），但与系统原生时区完全不可区分 | **极高**：使浏览器时区对齐美国代理出口，消除 `Asia/Shanghai` 硬伤 | **必须保留**（需配合 고정代理节点） |
| **环境变量** | `HOME` / `XDG_CONFIG_HOME` / `XDG_CACHE_HOME` / `XDG_DATA_HOME` 重定向到 `runtime/accNN`（`bin/gacc:491-492`） | **页面不可见** | **高**：多账户进程/缓存隔离，且解决当前环境 `$HOME` 不可写问题 | **保留** |
| **环境变量** | `MOZ_CRASHREPORTER_DISABLE=1`、`MOZ_DISABLE_AUTO_SAFE_MODE=1`（`bin/gacc:482-483`） | **页面不可见** | **中**：防止崩溃弹窗或进入安全模式打断使用 | **保留** |
| **环境变量** | `GSETTINGS_BACKEND=memory`（`bin/gacc:484`） | **间接微弱可见**：使 GTK 主题设置恒为默认浅色（`prefers-color-scheme: light`） | **低~中**：避免无 D-Bus/dconf 环境下刷 `dconf-CRITICAL` 警告 | **可保留** |
| **环境变量** | `unset MOZ_ENABLE_WAYLAND`（`bin/gacc:485`） | **页面可见**：导致走 Wayland（`screenX/Y=0`，X 工具无法截图） | **负收益**（原本意图是走 X11，但 `unset` 在 FF160 下默认走 Wayland） | **建议改为 `export MOZ_ENABLE_WAYLAND=0`** |
| **启动参数** | `--profile "$PROF" --class "gacc-$ACC"`（`bin/gacc:514-515`） | **页面不可见** | **极高**：多账号独立 Cookie/Storage 隔离的核心 | **必须保留** |
| **代理 Prefs** | `network.proxy.type = 0`（直连）或 `1` + `socks5` + `ice.proxy_only/no_host`（`bin/gacc:169-187`） | **JS 不可见**；服务端仅见出口 IP | **极高**：单账号独立代理与防 WebRTC 泄漏的核心 | **必须保留** |
| **人设 Prefs** | `intl.accept_languages = "en-US, en"`（`bin/gacc:124`） | **页面可见**（但 `"en-US, en"` 与英文版 Firefox 160 原生解析值完全一致） | **无额外收益**（不写该 pref 时英文版原生也是 `["en-US", "en"]`，写错反而曾引发大 Bug） | **可保留 `"en-US, en"`（必须修好 `bin/gacc:63,106`），或干脆不写** |
| **人设 Prefs** | `privacy.resistFingerprinting = false`、`media.peerconnection.enabled = true`（`bin/gacc:125`, `etc/user.js.tmpl:19`） | **与原生默认值完全相同（0 差异）** | 防止被误开启 RFP 或误关 WebRTC | **保留（无害）** |
| **沙箱 Prefs & Env** | `security.sandbox.{content,gpu,socket.process}.level = 0` + `MOZ_DISABLE_*_SANDBOX=1`（`bin/gacc:224-225,486-487`） | **页面无 API 可读**（但地址栏下方有黄条，且降低本地安全性） | 仅在 `unshare` 不可用的容器环境里为启动所必需；正常终端不触发 | **保留条件判断，但需补齐 `sed` 清理与 `RDD/UTILITY/GMP` 变量** |
| **后台静默 Prefs** | `network.captive-portal-service.enabled = false`、`network.connectivity-service.enabled = false`、`toolkit.telemetry.*`、`datareporting.*`、`app.shield.*`、`app.normandy.*`、`browser.discovery.enabled`、`identity.fxaccounts.enabled`、`app.update.*`、`browser.startup.page = 3` 等（`etc/user.js.tmpl:20-50`） | **页面与 Google 服务端 100% 不可见**（仅作用于 Firefox 内部及向 Mozilla 发送的请求；其中 6 个已是 FF160 废弃空 pref） | **高**：锁死版本防止指纹中途突变、自动恢复上次登录会话标签页、消除后台杂音 | **全部值得保留** |

#### B. 仍残留在 `profiles/acc01..03/prefs.js` 中的非原生历史改动（全部建议清除！）

| 残留 Pref 名称 | 残留位置（文件:行号） | 页面/行为可见性 | 是否值得保留？ |
|---|---|---|---|
| `intl.accept_languages = "en-US,en;q=0.9"` | `profiles/acc02/prefs.js:105` | **极高危（JS 可见）**：若 `user.js` 未覆盖会直接导致 `navigator.languages` 含 `"en;q=0.9"` | **绝不保留（应立即从 `acc02/prefs.js` 清理）** |
| `browser.search.suggest.enabled = false` | `acc01/prefs.js:57`, `acc02/prefs.js:58`, `acc03/prefs.js:57` | 地址栏搜索无 `/complete/search` 请求 | **不保留（应纳入 `--purge-legacy-prefs` 清理）** |
| `network.dns.disablePrefetch = true`、`network.prefetch-next = false`、`network.predictor.enabled = false`、`network.http.speculative-parallel-limit = 0` | `acc01/prefs.js:132-135`, `acc02/prefs.js:122-125`, `acc03/prefs.js:122-125` | 禁用所有 DNS 预解析与 TCP 投机预连接（时序差异） | **不保留（应纳入 `--purge-legacy-prefs` 清理）** |
| `javascript.use_us_english_locale = true` | `acc01/prefs.js:115`, `acc02/prefs.js:106`, `acc03/prefs.js:105` | FF160 已废弃的死 pref | **不保留（应纳入 `--purge-legacy-prefs` 清理）** |
| `media.peerconnection.ice.default_address_only = true` | `acc01/prefs.js:126`, `acc03/prefs.js:116` | 限制 WebRTC ICE 绑定接口 | **不保留（应纳入 `--purge-legacy-prefs` 清理）** |
| `security.sandbox.socket.process.level = 0` | `acc03/prefs.js:142`（以及 `profiles/tw`、`tp` 测试目录） | 当回到支持 `unshare` 的宿主终端时，因 `bin/gacc:228-231` 漏删该行，会导致 socket 沙箱无法恢复 | **不保留（修复 `bin/gacc:228-231` 的 `sed` 清理）** |

---

## 三、本轮新发现的回归或风险汇总（按严重度排序）

1. **【高危 / 潜伏复发】`bin/gacc:63` 与 `bin/gacc:106` 的 `P_ACCEPT` 默认值仍是 `"en-US,en;q=0.9"`（且 `acc02/prefs.js:105` 仍未清）**
   - **依据**：`bin/gacc:63` (`P_ACCEPT="en-US,en;q=0.9"`)、`bin/gacc:106` (`P_ACCEPT="en-US,en;q=0.9"`)、`profiles/acc02/prefs.js:105`。
   - **影响**：一旦新建账号（`gacc 4`）或运行 `--new-fp`，`gen_persona` 会再次把 `accept=en-US,en;q=0.9` 写进 `persona.conf`，导致 `navigator.languages = ["en-US", "en;q=0.9"]` 致命破绽立刻复发。
   - **修复**：将 `bin/gacc:63` 与 `bin/gacc:106` 改为 `P_ACCEPT="en-US, en"`，并在 `cmd_purge_legacy` 中顺手清理或修正 `prefs.js` 中的 `"en-US,en;q=0.9"`。
2. **【中危】`bin/gacc:228-231` 在环境支持 `unshare` 时漏删 `prefs.js` 中的 `security.sandbox.socket.process.level`**
   - **依据**：`bin/gacc:225` 写了 3 条沙箱 pref，但 `bin/gacc:228-231` 的 `sed -i` 只删了 `content.level` 和 `gpu.level`，漏掉了 `socket.process.level`；同时 `bin/gacc:433` 在 `--fp`/`--doctor`/`--purge-legacy-prefs` 前无条件执行 `prepare_profile`。
   - **影响**：只要在容器里跑过一次，`security.sandbox.socket.process.level = 0` 就会永久留在 `prefs.js`（如 `profiles/acc03/prefs.js:142`），回到正常宿主终端也无法自动恢复 socket 进程沙箱。
   - **修复**：在 `bin/gacc:228-231` 的 `sed -i` 中补上 `-e '/^user_pref("security\.sandbox\.socket\.process\.level", 0);$/d'`。
3. **【中危】受限环境下 `bin/gacc:487` 漏导出 `MOZ_DISABLE_RDD_SANDBOX=1` / `UTILITY` / `GMP`，仍有子进程 `SIGSEGV` 崩溃**
   - **依据**：`profiles/acc03/firefox.log:37-38` 及本机 headless 实测输出 `[211892] Sandbox: writing /proc/self/uid_map: EACCES` + `exited on signal 11`。
   - **影响**：在不支持 `unshare` 的环境下，虽然 socket 进程不再崩，但媒体解码 RDD 进程启动时依然因 userns 沙箱失败而段错误崩溃。
   - **修复**：在 `bin/gacc:487` 同步导出 `MOZ_DISABLE_RDD_SANDBOX=1 MOZ_DISABLE_UTILITY_SANDBOX=1 MOZ_DISABLE_GMP_SANDBOX=1`。
4. **【中低】`cmd_purge_legacy`（`bin/gacc:322`）只清了 5 个 pref，漏掉了上一轮遗留的另外 7 个旧 pref**
   - **依据**：`profiles/acc0{1,2,3}/prefs.js` 中仍存在 `browser.search.suggest.enabled=false`、`network.dns.disablePrefetch=true`、`network.prefetch-next=false`、`network.predictor.enabled=false`、`network.http.speculative-parallel-limit=0`、`javascript.use_us_english_locale=true`、`media.peerconnection.ice.default_address_only=true`。
   - **修复**：将这 7 项一并加入 `bin/gacc:322` 的 `grep -vE` 正则并重跑一次 `--purge-legacy-prefs`；同时删除 `profiles/tp` 与 `profiles/tw` 两个测试残留目录。
5. **【中低】`bin/gacc:485` 的 `unset MOZ_ENABLE_WAYLAND` 导致默认走 Wayland，X11 截图工具失效且 `window.screenX/Y` 恒为 `0`**
   - **依据**：本机实测 `unset MOZ_ENABLE_WAYLAND` 下 `has_x11_window: false`、`screenX: 0, screenY: 0`；改为 `export MOZ_ENABLE_WAYLAND=0` 后 `has_x11_window: true` 且 WebGL 1/2 依然 100% 正常。

---

## 四、一句话结论

**现在的浏览器环境在修复了 `navigator.languages`、`prefs.js` 5 项核心残留与 `XDG_RUNTIME_DIR`（WebGL 恢复）后，网页可见层已经非常接近真实的原生 Linux Firefox 160（不再有任何“一眼假”的 JS API 破绽）；但代码里仍留有 `bin/gacc:63,106` 默认 `P_ACCEPT="en-US,en;q=0.9"` 未改、`prefs.js` 剩余 7 项网络/搜索旧 pref 未清、`unshare` 恢复分支漏删 `socket.process.level` 这几处收尾漏洞，而在浏览器之外，唯一真正致命的破绽仍是「三个账号在直连模式下共用且频繁轮换的美国机房出口 IP（及由此引发的 IP 地域与固定 `TZ` 错位）」。**
