# 把 Antigravity 的登录关进指定账户环境

目标：Antigravity（Google 的 IDE）点「Sign in with Google」时，登录页**只能**落在
`gacc` 的某个 profile 里，账号会话不出现在系统其他浏览器中。

## 为什么必须跑在 WSL 里

Antigravity 是 Electron 应用，登录走 `shell.openExternal()` → 系统默认浏览器。
如果它跑在 **Windows** 上，「默认浏览器」由 Windows 决定，WSL 侧的 `xdg-settings` 管不到；
而且它的 OAuth 回调是 `http://127.0.0.1:<端口>` 的 **loopback**，在 WSL 的 NAT 网络下
WSL 里的浏览器根本连不上 Windows 的那个端口。

跑进 WSL 之后链路就闭环了：

```
Antigravity(WSL) ──openExternal──▶ xdg 默认浏览器 ──▶ gacc 的 profile
                                         │
                    回调 http://127.0.0.1:<port> 仍在 WSL 内部
```

不需要 `networkingMode=mirrored`。

## 安装

```bash
./bin/install-antigravity.sh                       # 默认装到 ~/opt/antigravity
ANTIGRAVITY_DIR=~/apps/ag ./bin/install-antigravity.sh   # 换位置
./bin/install-antigravity.sh arm                   # ARM64
```

脚本做的事（也就是官方的全部流程）：

1. 从 <https://antigravity.google/download> 解析当前版本的
   `.../antigravity-hub/<build>/linux-x64/Antigravity.tar.gz`；
2. 解压（官方**只发 tar.gz**，没有 `.deb`、没有官方 apt 源）；
3. `apt install` 运行时依赖（`libnss3` `libnspr4` 等，要 sudo）；
4. `chrome-sandbox` 设 `root:root` + `4755`（Electron 在 Linux 的标准步骤，
   VS Code 的 deb 也是 postinst 做的）；
5. 写 `.desktop`，让它在应用菜单 / WSLg 开始菜单里出现。

**不要用第三方 APT 源**（社区确实有打包好的源）：这套工具的价值在「环境可控」，
为它引入第三方签名源等于把信任链交出去。官方 tarball 解压即用，一样的体积。

## 让登录弹窗进指定 profile

```bash
./bin/install-shortcuts.sh --accounts "1 2 3" --as-default 1
xdg-settings get default-web-browser     # 应为 gacc-acc01.desktop
xdg-open https://example.com             # 应当开在 acc01 里
```

用完还原：`./bin/install-shortcuts.sh --revert-default`。

**只对 Linux 侧的应用有效**。Windows 上的程序调的是 Windows 默认浏览器，这套够不着。

## 那个点不动的 Verify 按钮

Antigravity 的验证页在 DOM 里就是一条外链：

```html
<a href="https://accounts.google.com/v3/signin/continue?...
          &continue=https://developers.google.com/gemini-code-assist/auth/auth_success_gemini"
   target="_blank">Verify</a>
```

`target="_blank"` 会被主进程的 `setWindowOpenHandler` 接走，转成
`shell.openExternal()` → Linux 上就是调 `xdg-open` → `gacc N <url>`。

**所以它能不能点动，完全取决于 `gacc` 会不会把 URL 交给已运行的实例。**
`gacc` 早期版本在这里有个 bug：实例已在跑时直接退出，URL 被丢弃，表现就是「点了没反应」。
现已修复（启动时不再加 `--no-remote`，同一 profile 的实例之间可以转交 URL）。

升级后需要**重启一次该账户**，让运行中的实例切换成新模式：

```bash
./bin/gacc 1 --stop && ./bin/gacc 1
```

实在不想修，也可以把链接直接粘到 profile 窗口里——验证流程本身只在 Google 侧。

## 启动日志里那些"看起来像错误"的行

| 日志 | 判断 |
|---|---|
| `Failed to connect to the bus: /run/user/1000/bus: No such file or directory` | WSL 没有 user session bus。**无害**（不再影响外链，因为外链走的是 `xdg-open` 而不是 portal） |
| `APPIMAGE env is not defined, current application is not an AppImage` | 无害，自动更新检查跳过（我们也不想让它自动更新） |
| `[IDE Wizard] ~/.gemini/antigravity not found — user was not migrated` | 无害，首次运行没有旧配置可迁移 |
| `failed to get cs path: cs path /usr/bin/cs invalid` | 无害，可选的外部工具没装 |

### 要不要把 user bus 永久修好

可以做（`sudo install -d -m700 -o $USER /run/user/1000` 再起一个 `dbus-daemon`），
但**不建议**，代价是：

1. `/run` 是 tmpfs，`wsl --shutdown` 后消失，要开机自动重建 → 得配 systemd user unit
   或 `/etc/profile.d`，多一层配置面；
2. 有了 session bus，应用会开始尝试 `xdg-desktop-portal`，而 WSL 里通常没有 portal 服务，
   文件选择框这类操作会**卡住等待**，比现在直接失败更难排查；
3. 与 systemd-logind 潜在冲突：一旦 logind 真的接管，会重建目录和权限；
4. 对浏览器指纹没有任何影响（这一点和隔离无关）。

一次性登录不值得。真需要时用 `dbus-run-session -- <程序>` 给单个进程兜住即可——
注意它和 Electron 的单实例锁会打架：**必须先退出旧实例**，否则新进程只是把参数转给旧的然后退出，
看起来就像"什么都没弹出来"。
