# gacc

**一个账户 = 一个浏览器 profile = 一套稳定的指纹特征。**

在 WSL2 / Linux 上把多个账号的登录环境彻底分开：cookie、存储、缓存、代理各自独立，
每个账号还有自己的时区、语言、CPU 核数、DPR 和字体列表。

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-WSL2%20%7C%20Linux-lightgrey)]()
[![Shell](https://img.shields.io/badge/shell-bash%204%2B-4EAA25)]()

```
$ ./bin/gacc list
账户 代理                     核心  时区               语言
01    direct                     8       America/Denver       en-US
02    socks5://127.0.0.1:1082    8       America/Los_Angeles  en-US
03    direct                     4       America/Phoenix      en-US
```

---

## 快速开始

```bash
git clone https://github.com/xyonium/gacc && cd gacc

bash deploy-gacc.sh                  # 装到 ./gacc-install，默认 3 个账户
cd gacc-install && ./bin/gacc 1      # 启动第 1 个账户
```

`deploy-gacc.sh` 会下载便携版 Firefox、校验 SHA256、补缺失的 `.so`（不需要 root）、
写配置、建账户，最后跑一次渲染自检。**不碰系统里已有的 Firefox。**

**前置条件**：`bash 4+`、`curl`、`tar`、`awk`、`sed`；Debian/Ubuntu 系还要 `dpkg`
（用来解包缺失的 `.so`，不需要 root）。WSL2 需要 WSLg（`DISPLAY` 非空）才有窗口，
纯 SSH 环境只能装、不能用。

已经有装好的一份？直接：

```bash
./bin/gacc 1                        # 启动账户 1（编号=序号，对应 profiles/acc01）
./bin/gacc 2 --proxy socks5://127.0.0.1:1082
./bin/gacc list                     # 账户 / 代理 / 人设
./bin/gacc 1 --fp                   # 看这一号的指纹人设
./bin/gacc 1 --doctor               # 体检
./bin/gacc 1 --stop
```

## 它是什么 / 不是什么

| 能做到 | 怎么做到 |
|---|---|
| 账号之间互相看不见 | 一个账号一个 profile 目录 + 独立进程，cookie/storage/cache 物理隔离 |
| 每个账号的网络出口不同 | 每个 profile 一份 `proxy.conf`，Firefox 原生 per-profile 代理 |
| 每个账号的指纹特征不同 | 时区、Accept-Language、`hardwareConcurrency`、`devicePixelRatio`、可见字体子集 |
| 一键启动 | `./bin/gacc N`，或生成开始菜单 / 桌面快捷方式 |

| 做不到 | 原因 |
|---|---|
| 隐藏出口 IP | 只提供 per-profile 代理配置，IP 得你自己给 |
| 改 Canvas / WebGL / GPU / TLS 指纹 | 同一个二进制、同一台机器，prefs 动不了这些 |
| 让同一台机器在对方眼里变成"不同的人" | 对方还有非浏览器信号：恢复手机号、验证设备、登录节奏、行为模式 |
| 伪造硬件 | 本工具只做真实值的差异化，不做伪装 |

**一句话**：它保证「账号之间不互相泄漏」，并降低低层信号的一致性，但它不是隐身工具。

## 设计要点

### 为什么用 profile，不用 Multi-Account Containers

- 官方 MAC **没有** per-container 代理，`network.proxy.*` 是全浏览器全局的；
- 容器共享进程、prefs 和代理，profile 是全套独立，隔离强度更高。

MAC 仍然会被装上（企业策略强制 + 预置 G1–G4），但只作为「一个窗口开多账号」的便利功能。

### 为什么不用 `privacy.resistFingerprinting`

RFP 会把**所有**账户抹成同一组值（时区强制 UTC、语言强制 en-US、窗口取整）。
对「账户之间要有差异」这件事是负收益，还会破坏美西时区设定。已显式设为 `false`。

### 为什么人设取主流值

4/8/12 核、DPR 1/1.25，而不是 16 核 + DPR 2。
稀有组合会缩小你的匿名集，反而更好被认出来——**看起来普通比看起来独特更重要**。

### 人设是稳定的

`persona.conf` 首次生成后固化，`user.js` 每次启动按它重新渲染。
只有显式 `--new-fp` 才会重掷。**指纹稳定性比多样性更重要**：同一账号今天一套明天一套，本身就是异常。

## 命令参考

| 命令 | 作用 |
|---|---|
| `./bin/gacc <N>` | 启动账户 N |
| `./bin/gacc <N> --proxy <url>` | 设置并启动（`socks5://` `socks4://` `http://` `direct`） |
| `./bin/gacc <N> --direct` | 改回直连 |
| `./bin/gacc <N> --fp` | 显示该账户的指纹人设 |
| `./bin/gacc <N> --new-fp` | 重掷人设（下次启动生效） |
| `./bin/gacc <N> --fonts` / `--no-fonts` | 开启 / 关闭字体子集 |
| `./bin/gacc <N> --doctor` | 体检：代理、人设、沙箱、登录态 |
| `./bin/gacc <N> --stop` | 关闭该账户 |
| `./bin/gacc list` | 列出所有账户 |
| `./bin/gen-fonts.sh <N> --show` | 重新生成字体子集并打印可见家族 |
| `./bin/install-shortcuts.sh --accounts "1 2 3" --with-fonts` | 生成开始菜单 + 桌面快捷方式 |

## 每账户的策略

### 代理

一行 `profiles/accNN/proxy.conf`。`--proxy` 写文件后下次启动生效（每次启动重新渲染 `user.js`）。

> **WSL2 注意**：WSL 里的 `127.0.0.1` 不是 Windows 的 `127.0.0.1`。Windows 上的代理要么监听
> `0.0.0.0` 后用网关 IP（`ip route | awk '/default/{print $3}'`），要么在 `.wslconfig` 里开
> `networkingMode=mirrored`。

### 字体子集

```bash
./bin/gacc 3 --fonts
```

`FONTCONFIG_FILE` 指向本账户的 `fonts.conf`，只暴露一个精选子集：

- 基础字体强制包含（DejaVu 三族 + Noto CJK + emoji），保证不缺字；
- 其余从「普通桌面常见字体」白名单里取，候选池按序号分成 4 组，账户只从自己那组取 6~9 个；
- 与其它账户比对签名，避免碰撞。

实测：同一段 JS 在系统配置下量出 `200 / 345.17 / 409.5` 三个宽度，在子集配置下**全部塌成 350**
——确认浏览器真的只看得见子集。四个账户两两相差 6~11 个家族，CJK 始终完整。

### 桌面 / 开始菜单入口

```bash
./bin/install-shortcuts.sh --accounts "1 2 3 4" --with-fonts
```

生成两套：

1. `~/.local/share/applications/gacc-accNN.desktop` → **WSLg 自动收进 Windows 开始菜单**；
2. Windows 桌面 `.lnk` → `wsl.exe -d <发行版> -e <gacc> <N>`，最小化启动。

### 让第三方应用的登录弹窗进指定账户

跑在 WSL / Linux 里的应用（例如 Google Antigravity）调用「系统默认浏览器」时，可以把它固定到某个账户：

```bash
./bin/install-shortcuts.sh --accounts 1 --as-default 1
xdg-settings get default-web-browser    # 应为 gacc-acc01.desktop
```

Windows 上的程序不受影响（它调的是 Windows 默认浏览器）。
完整流程见 [docs/antigravity.md](docs/antigravity.md)。

## 沙箱与那条黄条

Firefox 的内容沙箱要写 `/proc/self/uid_map`。某些环境（容器、或把终端套进别的文件沙箱里）
会拒绝这个写入，结果是内容进程 SIGSEGV、页面全白。`gacc` 每次启动探测：

- 探测通过 → 保持沙箱开启，**不会有黄条**（实测内容进程全部存活、零崩溃）；
- 探测失败 → 自动关闭沙箱，页面正常但地址栏下常驻一条
  「The security sandbox is disabled」。

这条**压不掉**：`security.sandbox.warn=false` 实测无效，`security.sandbox.content.level` 取 1/2/3
也全部崩溃（不存在"降级可用"的中间态）。它只影响你本机的安全——**对方看不到**。

## 排障

| 症状 | 原因 | 处理 |
|---|---|---|
| 窗口起来但全白 | 内容沙箱把进程打崩 | 看 `profiles/accNN/firefox.log` 有无 `uid_map: EACCES` / `signal 11` |
| 启动几秒后消失，profile 里只有 3–4 个文件 | `$HOME` 不可写，Firefox 卡在早期初始化 | `gacc` 已把 `HOME`/`XDG_*` 重定向到 `runtime/` |
| `already running` / 抢锁 | 同一 profile 开了两个实例 | `./bin/gacc N --stop` 再启 |
| 关终端浏览器就没了 | 进程跟着会话被杀 | 已用 `setsid --fork` 双重脱离 |
| 中文显示成方块 | 缺 CJK 字体 | `sudo apt install fonts-noto-cjk` |
| `.lnk` 双击没反应 | gacc 路径搬家了 | 重跑 `install-shortcuts.sh` |
| PowerShell 脚本报乱码/语法错 | PS 5.1 需要 UTF-8 BOM | 仓库里的 `gacc.ps1` 已带 BOM |

## 目录结构

```
gacc/
├── bin/gacc                  启动器
├── bin/gen-fonts.sh          字体子集生成
├── bin/install-shortcuts.sh  开始菜单 / 桌面快捷方式
├── etc/user.js.tmpl          prefs 模板（@PROXY@ / @PERSONA@ / @SANDBOX@）
├── etc/policies.json         企业策略：强装 MAC、关遥测/账号同步
├── deploy-gacc.sh            一键部署
├── windows/gacc.ps1          Windows 原生版（逻辑同源，未在 Windows 上实测）
├── docs/                     设计与两轮审计记录
└── profiles/accNN/           账户数据（首次启动自动创建，绝不入库）
```

## 卸载

```bash
for n in 1 2 3 4; do ./bin/gacc $n --stop; done      # 先关掉所有账户
rm -f ~/.local/share/applications/gacc-acc*.desktop   # 开始菜单项
```

Windows 桌面上的 `Firefox 账户 NN.lnk` 直接删。最后删掉整个安装目录即可。
`profiles/` 里是真实登录态，只清某个账户用 `rm -rf profiles/accNN`。

## 安全

- `profiles/` 里是真实登录态。`.gitignore` 已排除 `profiles/`、`runtime/`、`firefox/`、
  `libs/`、`download/`，并显式列出 `cookies.sqlite` / `logins.json` / `key4.db`。
- 提交前自查：`git status --ignored` 不应出现任何 `profiles/` 内容。
- 本工具不联网、不上报、无遥测。Firefox 的遥测与 Mozilla 账号同步由 `policies.json` 关闭。
- `deploy-gacc.sh` 会校验 Mozilla 官方 `SHA256SUMS`；哈希不符直接中止。

## 已验证 / 未验证

**已验证（Linux + WSLg 实测）**：便携 Firefox 启动与渲染、多实例并存、四维人设生效、
字体子集生效、per-profile 代理生效、企业策略装 MAC、会话恢复、沙箱探测与自动降级、
快捷方式生成、`deploy-gacc.sh` 全流程 + SHA256 校验、`windows/gacc.ps1` 语法解析。

**未验证**：`windows/gacc.ps1` 的运行时行为（没有 Windows 环境实测）；
更大字体池下的子集差异幅度。

## FAQ

**启动后页面全白？**
内容沙箱被环境挡住了，见上面「沙箱与那条黄条」。检查 `profiles/accNN/firefox.log`
里有没有 `uid_map: EACCES`。

**提示缺 `libasound.so.2` 之类？**
`sudo apt install libdbus-glib-1-2 libasound2 libstartup-notification0`，
或者交给 `deploy-gacc.sh` 自己补（不需要 root）。

**怎么确认代理真的生效？**
`./bin/gacc N --doctor` 会打印该 profile 的代理并探测连通性；窗口里访问
`https://www.gstatic.com/generate_204` 返回 204 也说明通了。

**`./bin/gacc list` 里看不到刚加的号？**
账户目录在**首次启动**时才创建，先跑一次 `./bin/gacc N`。

**能不能同时开两个同号？**
不行，同一个 profile 只能有一个实例，先 `--stop` 再启动。

**能不能用 `apt` / `snap` 装的 Firefox，而不是随包下载的便携版？**
可以：`GACC_FIREFOX=/snap/bin/firefox ./bin/gacc 1`。
注意 Ubuntu 22.04 的 `firefox` 包是 snap 转接包，snap 会**自动更新**，而每次更新都会改变
UA / TLS / 渲染指纹——这套工具的价值在于指纹长期稳定，所以用 snap 的话请先
`sudo snap refresh --hold firefox`。另外 snap 版的企业策略要放 `/etc/firefox/policies/`
（要 root），便携版是直接放在安装目录里。

**换了字体包之后要做什么？**
重跑 `./bin/gen-fonts.sh N`，子集按新的字体池重建。

## 用途与边界

这是一个**本地浏览器配置工具**，不含任何绕过平台风控、批量注册或自动化登录的功能。
它做的事是「让几个浏览器实例互不共享 cookie、各自有稳定且不同的时区/语言/字体特征」。

- 多账户本身是否被允许，取决于你用的服务条款，请自行判断并遵守；
- 它不隐藏 IP、不伪造硬件，能力边界见上表；
- 作者不对使用方式负责。

## License

[MIT](LICENSE)
