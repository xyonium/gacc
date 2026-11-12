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

`target="_blank"` 被主进程的 `setWindowOpenHandler` 接走，转成
`shell.openExternal()` → Linux 上就是 `xdg-open` → `gacc N <url>`。

问题在于**Firefox 不会把 URL 交给「同一 profile 已运行的实例」**。这不是配置问题，本环境实测过：

| 变量 | 结果 |
|---|---|
| 去掉 `--no-remote` | 仍然新起实例（并弹出 "already running"） |
| 加 / 不加 `--class` | 都一样 |
| `-profile <路径>` vs `-P <名字>`（注册进 profiles.ini） | 都一样 |
| 有 / 没有 D-Bus session bus（`dbus-run-session`） | 都一样 |

所以「点按钮 → 已经开着的窗口里弹出验证页」在这个环境里做不到。两条可用的路：

**路 A：点之前先关掉那个账户**

```bash
./bin/gacc 1 --stop
```

然后点 Verify——`xdg-open` 会重新拉起浏览器并**直接带着 URL 启动**，验证页正常出现。
标签页有会话恢复，关掉不会丢。

**路 B：让 URL 自动进剪贴板**（`install-antigravity.sh` 默认会装 `xclip`）

```bash
sudo apt install xclip        # 已经装过就跳过
```

之后点 Verify 会在终端打印提示、并把 URL 放进剪贴板，切到窗口 `Ctrl+T` 粘贴回车即可。

`gacc` 现在的行为是：检测到实例已在运行且带着 URL 时，**不再启动第二个实例**
（那样只会抢 profile 锁并弹 "already running"），而是按上面两条给出提示。


## 多账号槽位（实验性，`bin/agsw`）

Antigravity 本体只保存**一个**登录态。要同时挂多个账号，就得给它不同的配置根目录：
Electron 的 `--user-data-dir` 决定 userData，单实例锁也按它隔离，所以多个槽位可以**同时运行**。

```bash
./bin/agsw list                 # 槽位 + 运行状态
./bin/agsw login 2              # 一步到位：槽位 2 + 登录弹窗指向 gacc 2 号
./bin/agsw new work             # 新建槽位（名字可以是 2 这样的纯数字）
./bin/agsw run work             # 用 work 槽位启动
./bin/agsw run work --gacc 2    # 同时把登录弹窗指向 gacc 的 2 号账户
./bin/agsw stop work
./bin/agsw rm work              # 会二次确认，删前先 stop
./bin/agsw run work --dry-run   # 只打印将要执行的命令
```

槽位名用账户号最省事：`agsw login 2` 等于 `agsw new 2` + `--as-default 2` + `agsw run 2`。
登录成功后再次启动就不用带 `--gacc` 了（登录态已经存在槽位里）：

```bash
./bin/agsw run 2
```

槽位数据在 `~/.local/share/agsw/slots/<名字>/`，和现有的 `~/.config/Antigravity` 完全隔离。

**注意：只换 `--user-data-dir` 是不够的。** Antigravity 把登录态放在 `$HOME/.gemini`
（`oauth_creds.json`、`google_accounts.json`、`antigravity/`），那不属于 Electron 的
userData，所以 `agsw` 连 `HOME` 一起换成 `<槽位>/home`。实测：新槽位首次启动显示
"Welcome to Antigravity!"（未登录），而 `~/.gemini` 的时间戳不变。

**改成独立 HOME 后还要补一步**：`xdg-open` 是按 `$HOME/.config/mimeapps.list` +
`$HOME/.local/share/applications/` 找默认浏览器的。槽位是空的，点登录就会落到 WSL 的兜底
（打开 Windows 浏览器）。所以 `agsw` 每次启动前会把当前的默认浏览器 `.desktop` 复制进槽位，
并写一份槽位自己的 `mimeapps.list`。验证：

```bash
env HOME=~/.local/share/agsw/slots/2/home xdg-mime query default x-scheme-handler/https
# 应输出 gacc-acc02.desktop
```

想强制指定：`AGSW_DEFAULT_BROWSER=gacc-acc03.desktop ./bin/agsw run 2`。

**先别直接用于正式环境**，用独立的根目录试（这也是验证它不会越界的最快方式）：

```bash
AGSW_HOME=/tmp/agsw-test ./bin/agsw new t1
AGSW_HOME=/tmp/agsw-test ./bin/agsw run t1 --no-browser-switch
AGSW_HOME=/tmp/agsw-test ./bin/agsw list
AGSW_HOME=/tmp/agsw-test ./bin/agsw stop t1
```

- `--no-browser-switch`：不改系统默认浏览器（`--gacc N` 才需要改）。
- 在受限 shell（带 `PR_SET_NO_NEW_PRIVS`，比如被别的沙箱套住）里启动 Chromium 会报
  `Zygote process exited prematurely`，这时加 `-- --no-sandbox`。普通终端不需要。

> 已知：这个脚本的管理功能（建/列/停/删/状态检测、`--user-data-dir` 隔离）已验证；
> **GUI 的实际启动没能在开发环境里跑通**（沙箱挡住了 `/dev/shm` 和 setuid helper），
> 你在自己的终端里跑才作数。

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
