# gacc —— 一账户一浏览器 profile 的隔离登录工具（WSL2 / Linux）

在一个 WSL2 环境里登录多个 Google（或任意站点）账户，**账户之间互相看不见**，
并且每个账户在网络上呈现一套**不同但自洽**的指纹特征。

```
$ ./bin/gacc list
账户 代理                     核心  时区               语言
01    direct                     8       America/Denver       en-US
02    socks5://127.0.0.1:1082    8       America/Los_Angeles  en-US
03    direct                     4       America/Phoenix      en-US
```

## 它解决什么 / 不解决什么

| 层面 | 是否解决 | 说明 |
|---|---|---|
| Cookie / localStorage / IndexedDB / 历史 / 缓存 | ✅ | 每个账户一个独立 profile 目录 + 独立进程 |
| 同浏览器切换账号导致的串号 | ✅ | profile 之间没有共享 cookie jar |
| 时区 / 语言 / CPU 核数 / DPR / 字体列表 | ✅ | 每账户一套「人设」，见下文 |
| N 个账户的出口 IP | ❌ | 只提供 per-profile 代理配置，出口你自己给 |
| Canvas / WebGL / GPU / TLS / HTTP2 指纹 | ❌ | 同一二进制、同一台机器，prefs 改不动 |
| Google 侧非浏览器信号（恢复手机、验证设备、登录节奏） | ❌ | 这是关联的主力，技术上无解 |

**别把工具当护身符**：它能保证「账户之间不互相泄漏」，能降低低层信号的一致性，
但不能保证对方认不出是同一个人。

## 为什么用 profile 而不是 Multi-Account Containers

- 官方 MAC **没有** per-container 代理设置，`network.proxy.*` 是全浏览器全局的。
- 容器共享进程 / prefs / 代理；profile 是全套独立，隔离强度更高。
- MAC 仍然装上（企业策略强制，预置 G1–G4 四个容器），用来做「一个窗口开多账户」的便利功能。

## 快速开始

### 方式 A：一键部署（空机器）

```bash
bash deploy-gacc.sh                        # 装到 ./gaccounts，默认 3 个账户
bash deploy-gacc.sh --accounts 5 --dir ~/gaccounts
bash deploy-gacc.sh --proxy-mode direct    # 没有代理时全直连
```

脚本会：下载便携版 Firefox → 补缺失的 `.so`（不需要 root）→ 写配置 → 建账户 → 渲染自检。
依赖：`curl tar dpkg awk sed`；Debian/Ubuntu 系补库用 `apt-get download`（不需要 sudo）。

### 方式 B：直接用（已经有一份装好的）

```bash
./bin/gacc 1                      # 启动账户 1
./bin/gacc 2 --proxy socks5://127.0.0.1:1082
./bin/gacc 3 --direct
./bin/gacc 1 https://mail.google.com
./bin/gacc list                   # 账户 / 代理 / 人设
./bin/gacc 1 --fp                 # 看账户 1 的指纹人设
./bin/gacc 1 --new-fp             # 重掷人设
./bin/gacc 1 --fonts              # 开字体子集（见下）
./bin/gacc 1 --doctor             # 体检
./bin/gacc 1 --stop
```

账户号就是序号：`./bin/gacc 1` ↔ `profiles/acc01/`。新号码会自动创建。

### 桌面 / 开始菜单入口

```bash
./bin/install-shortcuts.sh --accounts "1 2 3 4" --with-fonts
./bin/install-shortcuts.sh --accounts "1 2 3 4" --dry-run    # 只看不写
```

生成两套：

1. `~/.local/share/applications/gacc-accNN.desktop` → **WSLg 会自动收进 Windows 开始菜单**（名字「Firefox 账户 NN」）。这就是在 WSL 里装 GUI 程序时开始菜单里冒出快捷方式的机制。
2. Windows 桌面 `.lnk` → `wsl.exe -d <发行版> -e <gacc> <N>`，最小化启动。

## 每账户的「人设」

首次启动时随机分配并固化在 `profiles/accNN/persona.conf`：

| 维度 | 落地方式 | 验证 |
|---|---|---|
| 时区 | 启动时 `export TZ=`，Firefox 的 `Intl.DateTimeFormat().resolvedOptions().timeZone` 跟随 | ✅ 实测 `TZ=X` → JS 报 `X` |
| 语言 | `intl.accept_languages` | ✅ 实测 `navigator.language` 跟随 |
| CPU 核数 | `dom.maxHardwareConcurrency` | ✅ 实测 `navigator.hardwareConcurrency` 跟随 |
| DPR | `layout.css.devPixelsPerPx` | ✅ 实测 `devicePixelRatio` 跟随 |

取值刻意落在**主流办公机区间**（4/8/12 核，DPR 1/1.25），不用 16 核 + DPR 2 这种稀有组合
——稀有组合会缩小匿名集，反而更好被认出来。

**不用 `privacy.resistFingerprinting`**：它把所有账户抹成同一组值（还强制 UTC），
对「账户之间要有差异」这件事是负收益。

## 字体子集

```bash
./bin/gen-fonts.sh 3 --show     # 生成并打印它能看到哪些家族
./bin/gacc 3 --fonts            # 生成并启动
./bin/gacc 3 --no-fonts         # 撤销
```

做法：`FONTCONFIG_FILE` 指向本账户的 `fonts.conf`，里面只链接触一个精选子集。
基础字体（DejaVu 三族 + Noto CJK + emoji）强制包含，保证不缺字；其余按账户号确定性挑选，
并和其它账户比对签名避免重复。

实测：同一段 JS 在系统配置下量出 `200 / 345.17 / 409.5` 三个宽度，在子集配置下**全部塌成 350**
——确认浏览器只看得见子集里的字体。中文/日文/韩文渲染正常。

顺带效果：`MesloLGS Nerd Font` 这类「开发者机器」标记在开了子集的账户里不可见。

选择方式是**分组互斥**：候选池按序号分成 4 组，每个账户只从自己那组里取 6~9 个，
所以任意两个账户之间只共享「必含基础字体」，其余各不相同。实测 4 个账户两两相差
**6~11 个家族**（并集 24~27），每个账户都有完整 CJK。

> 想进一步放大：多装常见字体包（`fonts-croscore`、`fonts-crosextra-carlito`、
> `fonts-crosextra-caladea`、`fonts-lohit-deva`、`fonts-kacst`、`fonts-unfonts-core`），
> 池子变大后分组内可选范围更宽。反过来，`fonts-noto-extra`（326MB 的冷门文字）
> 对这套选择器完全没用，可以直接 purge。

## 代理

每账户一行 `profiles/accNN/proxy.conf`，支持 `socks5://`、`socks4://`、`http://`、`direct`。
`--proxy` 写文件后立刻生效（每次启动重新渲染 `user.js`）。

**WSL2 的坑**：WSL 里的 `127.0.0.1` 不是 Windows 的 `127.0.0.1`。Windows 上的代理要么监听
`0.0.0.0` 后用网关 IP（`ip route | awk '/default/{print $3}'`），要么在 `.wslconfig` 里开
`networkingMode=mirrored`。

## 沙箱与那条黄条

Firefox 的内容沙箱要写 `/proc/self/uid_map`。某些环境（容器、或把终端套进别的文件沙箱里）
会拒绝这个写入，结果就是内容进程 SIGSEGV、页面全白。`gacc` 每次启动都探测一次：

- 探测通过 → 保持沙箱开启，**不会有黄条**（正常终端里就是这样，实测内容进程全部存活、零崩溃）
- 探测失败 → 自动关闭沙箱，页面正常但地址栏下会常驻一条
  「The security sandbox is disabled」提示。这条**无法用 prefs 压掉**
  （`security.sandbox.warn=false` 实测无效，`security.sandbox.content.level` = 1/2/3 也全部崩溃）

它的含义是「网页内容失去了进程级隔离」，只影响你本机的安全，不影响指纹——对方看不到。

## 目录结构

```
gacc/
├── bin/
│   ├── gacc                  启动器
│   ├── gen-fonts.sh          字体子集生成
│   └── install-shortcuts.sh  开始菜单 / 桌面快捷方式
├── etc/
│   ├── user.js.tmpl          prefs 模板（@PROXY@ / @PERSONA@ / @SANDBOX@ 三个占位符）
│   └── policies.json         企业策略：强装 MAC、关遥测/账号同步
├── profiles/accNN/           ← 账户数据（含登录态，绝不能提交）
│   ├── proxy.conf  persona.conf  user.js  containers.json  fonts.conf
├── runtime/accNN/            每账户独立 HOME / cache / XDG
├── deploy-gacc.sh            一键部署
└── docs/                     PLAN.md（设计）REVIEW*.md（审计）
```

## 排障

| 症状 | 原因 | 处理 |
|---|---|---|
| 窗口起来但全白 | 内容沙箱把进程打崩了 | 看 `profiles/accNN/firefox.log` 有没有 `uid_map: EACCES` / `exited on signal 11` |
| 浏览器启动几秒后消失、profile 目录里只有 3–4 个文件 | `$HOME` 不可写，Firefox 卡在早期初始化 | `gacc` 已把 `HOME`/`XDG_*` 重定向到 `runtime/accNN` |
| `already running` / 抢锁 | 同一 profile 开了两个实例 | `./bin/gacc N --stop` 后再启 |
| 关终端浏览器就没了 | 进程跟着会话被杀 | 已用 `setsid --fork` 双重脱离 |
| `.lnk` 双击没反应 | `wsl.exe -e` 找不到 gacc | 确认路径没搬家；搬家后重跑 `install-shortcuts.sh` |
| 中文显示成方块 | 缺 CJK 字体 | `sudo apt install fonts-noto-cjk` |

## 安全与提交须知

- `profiles/` 里是**真实登录态**（cookie、session）。仓库 `.gitignore` 已排除
  `profiles/`、`runtime/`、`firefox/`、`libs/`、`download/`。
- 提交前自查：`git status --ignored` 里不该出现任何 `profiles/` 内容。
- 本工具不联网、不上报、没有遥测；数据全在本地目录里。
- 备份：关掉浏览器后 `tar czf backup.tgz profiles/`。

## 用途与边界

这是一个**本地浏览器配置工具**，不含任何绕过平台风控、批量注册或自动化登录的功能。
它做的事是「让几个浏览器实例互不共享 cookie、各自有稳定的时区/语言/字体特征」。

- 多账户本身是否被允许，取决于你用的服务条款，请自行判断并遵守。
- 它不会隐藏你的 IP、不会伪造硬件、也不会让同一台机器在对方眼里变成「不同的人」——
  能力边界见上面那张表。
- 作者不对使用方式负责。

## 已验证 / 未验证

**已验证（本机实测）**：便携 Firefox 启动与渲染、多实例并存（X11 WM_CLASS 区分）、
四维人设生效、字体子集生效、per-profile 代理生效、企业策略装 MAC、会话恢复、
沙箱探测与自动降级、快捷方式生成（dry-run）。

**未验证**：`windows/gacc.ps1`（Windows 原生版，逻辑同源但没跑过）、
一套更大字体池下的子集差异幅度。
