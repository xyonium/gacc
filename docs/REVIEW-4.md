# 代码审查报告：gaccounts v1.0.0 后改动

## 1. 结论
可以发布，但建议修复 2 处潜在阻断风险。

## 2. 必须修
- `bin/gacc:395`：`FORWARD` 逻辑中，如果 `pgrep` 找到的进程（`$EXIST`）不是浏览器而是其它重名进程（虽罕见但存在），或者浏览器正在挂起/响应超时，`sleep 3` 后无条件退出 `0` 是不妥的。建议检查 `ps` 是否在运行且属于该 profile。
- `bin/install-shortcuts.sh:111`：`--revert-default` 硬编码 `firefox.desktop`。在未安装 `firefox` 软件包（仅用便携版）的系统中，该命令会静默失败或报错。应增加 `command -v firefox` 检查或提供回退提示。

## 3. 建议修
- **高**：`bin/gacc` 正则 `( |$)` 虽能防 `acc010` 命中，但若路径包含空格，`pgrep -f` 处理会有歧义。建议用 `pgrep -af` 拿到完整命令行后在 bash 中做前缀匹配。
- **中**：`bin/install-antigravity.sh` 中 `apt` 安装依赖在非 Debian 系 Linux 上会直接崩，建议加 OS 检测（如 `/etc/os-release`）。
- **低**：`bin/gacc` 的 `FORWARD` 分支中 `${URLS[*]}` 拼接若含空格可能出错，建议改用 `"${URLS[@]}"` 或正确引用。

## 4. 实测结论确认
- **去掉 `--no-remote`**：正确。Firefox 会通过 X11/Wayland 或 D-Bus 将 URL 转发给单实例锁拥有者。旧版遗留的 `--no-remote` 进程确实会成为单实例锁拥有者，新版 gacc 此时会进入 `FORWARD` 逻辑（检测到已有进程），这符合预期（URL 转发）。
- **`pgrep` 行为**：新版 `procps` (`pgrep` > 4.0) 的正则行为可能变动，目前代码用的是 `grep -f --` 的语法。如果环境有变，建议显式加入 `-P` 或 `-E` 确保一致性。

## 5. 回归测试清单
1. **多开与转发测试**：启动 A，再用不同账户启动 B（确保均正常）。
2. **URL 转发测试**：启动 A，在终端执行 `./bin/gacc 1 https://google.com`，确认 URL 在 A 窗口打开。
3. **默认浏览器测试**：执行 `--as-default`，确认 `xdg-settings get` 返回 `gacc-acc01.desktop`。
4. **Antigravity 启动**：执行 `install-antigravity.sh`，确认能拉起并正常加载。

## 6. 如果只能改 3 处
1. 修复 `bin/gacc` 中的 `pgrep` 逻辑，改用 `ps -ef` + bash 字符串匹配（彻底解决正则表达式兼容性及路径包含空格问题）。
2. `bin/install-shortcuts.sh` 中增加 `firefox.desktop` 存在性检查，避免还原失败。
3. `bin/gacc` 中的 `FORWARD` 分支，增加对转发是否「真的触发」的简单验证（如检测进程是否真的收到过信号或通过更强的 `dbus-send` 确认）。
