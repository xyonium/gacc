# 安全审计与重构建议：多 Google 账户隔离方案 (gacc)

## 1. 结论：整体成立，部分隐患
这套方案在 WSL2 环境下通过独立 Profile 实现隔离，逻辑上是成立的。但当前代码的沙箱管理和进程匹配机制存在不稳定隐患。
- **采纳**：profile 隔离架构、企业策略 MAC 配置、变量硬化思路。
- **需修改**：动态 user.js 修改、`. "$f"` 注入隐患、会话恢复的窗口管理。

## 2. 必须修的错误 (Must-Fix)

| 类型 | 文件:行号 | 错误片段 | 正确做法 |
| :--- | :--- | :--- | :--- |
| **Race Condition** | `bin/gacc:209` | `sed -i '/security\.sandbox\./d' "$prof/prefs.js"` | 移除动态删除逻辑，通过预检脚本在启动前确定是否降级，不再修改已存在的文件。 |
| **代码注入** | `bin/gacc:85` | `. "$f"` | 严禁 Source，使用 `grep` 或 `awk` 提取键值对。 |
| **进程误杀** | `bin/gacc:313` | `pgrep -f -- "--profile $PROF"` | 使用 `pgrep -af -- "--profile $PROF "`，确保匹配完整参数字符串。 |
| **会话冲突** | `bin/gacc:344` | `WARGS=(-width "$w" -height "$h")` | 在 `user.js` 中禁用 `browser.sessionstore.max_windows_undo` 并重置 `xulstore.json`。 |
| **部署 bug** | `deploy-gacc.sh:144` | `ldd "$FFBIN"` | 检查 `firefox-bin` 以及相关的 `.so` 文件，而非 wrapper 脚本。 |

## 3. 风险评估 (Risk Assessment)

| 风险点 | 严重度 | 会不会被检测到 | 处置 |
| :--- | :--- | :--- | :--- |
| TLS 指纹一致性 | 致命 | 高 (Google 侧) | 实施内核分流 |
| 动态修改 user.js 残留 | 中 | 中 | 改用只读模板或 prefs.js 覆盖 |
| 沙箱关闭 | 中 | 高 (浏览器指纹) | 仅在必要时关闭 |
| 相同 machine-id | 中 | 中 | 使用容器或单独用户管理 |

## 4. user.js 替代机制建议
**当前机制代价**：高频破坏性改写导致 `prefs.js` 不可控，容易导致浏览器配置损坏且难以调试。
**替代建议**：引入一个专门的 `user-persona.js` 或 `user-proxy.js` 作为 profile 目录下的只读文件，Firefox 在 `user.js` 中使用 `pref("...", ...)`；或者在 `gacc` 启动前仅在**非零版本**时生成，生成一次后若存在则跳过。
**代价**：需要修改 `gacc` 的初始化逻辑，允许用户在启动时通过 `--force` 参数强制刷新这些配置文件。

## 5. 内核分流方案 (Kernel Splitting)
- **方案建议**：将账户按编号分为两组：奇数号走 Firefox 160，偶数号走 ungoogled-chromium (Portable)。
- **实现方式**：在 `bin/gacc` 中增加 `FF_PATH` 分支判断。
- **现实性**：Firefox 侧维护现有便携包，Chromium 侧建议直接从 ungoogled-software 仓库获取稳定 release。这彻底拉开了 JS 引擎与 TLS 指纹的差距，成本在于两套浏览器二进制的维护。

## 6. 指纹性价比排序 (Top 3)
1. **内核分流**：拉开 TLS 与 JS 引擎指纹，这是防关联的最硬指标。
2. **字体白名单**：通过 `FONTCONFIG_FILE` 限制 profile 可见字体总量，破坏全局字体枚举特征。
3. **调整人设**：降低并发核数与 DPR 的取值多样性，回归主流办公配置，避免过于特征化的设备配置组合。

## 7. 给用户的 3 条最重要提醒
1. **指纹稳定胜过指纹优秀**：不要追求绝对完美的配置，保持每一个账号的 profile 指纹长期稳定不波动。
2. **行为关联是最终的死刑**：无论浏览器怎么改，你在 Google 看来都是同一个人，这是物理意义上的关联，技术手段防不住行为特征。
3. **出口 IP 要与人设对齐**：永远保证你的代理出口 IP 与该 profile 的 `America/Los_Angeles` 等人设时区位于同一地理区域。
