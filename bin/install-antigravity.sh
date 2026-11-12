#!/usr/bin/env bash
# ============================================================================
#  install-antigravity.sh —— 在 WSL / Ubuntu 上装 Google Antigravity
#
#   ./bin/install-antigravity.sh              # x64
#   ./bin/install-antigravity.sh arm          # ARM64
#   ANTIGRAVITY_DIR=~/apps/ag ./bin/install-antigravity.sh
#
# 官方只提供 .tar.gz（没有 .deb、没有官方 apt 源），所以这里：
#   1) 从官方下载页解析出当前版本的 linux 包地址
#   2) 解压到 $ANTIGRAVITY_DIR
#   3) apt 装运行时依赖（这一步要 sudo）
#   4) 修 chrome-sandbox 的 setuid 位（Electron 在 Linux 的标准步骤）
#   5) 写一个 .desktop，让它出现在应用菜单 / WSLg 开始菜单里
#
# 想让它把「用 Google 登录」的弹窗送进指定浏览器 profile，见 docs/antigravity.md
# ============================================================================
set -euo pipefail

CHECK=0; NO_DEPS=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --check)   CHECK=1 ;;
    --no-deps) NO_DEPS=1 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$a") ;;
  esac
done
ARCH="${ARGS[0]:-x64}"
case "$ARCH" in
  x64|arm|arm64) [[ "$ARCH" == arm64 ]] && ARCH=arm ;;
  *) echo "用法：$0 [x64|arm]" >&2; exit 1 ;;
esac

if [[ ${EUID} -eq 0 && -z "${ANTIGRAVITY_DIR:-}" ]]; then
  die "不要用 sudo 运行整个脚本：那样 HOME=/root，会装到 /root/opt/antigravity。
     用普通用户运行，脚本需要权限时会自己调 sudo（会提示你输密码）。"
fi

DIR="${ANTIGRAVITY_DIR:-$HOME/opt/antigravity}"
PAGE="https://antigravity.google/download"

say() { printf '\n\033[32m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

for t in curl tar awk grep; do
  command -v "$t" >/dev/null 2>&1 || die "缺少命令 $t"
done

DEPS=(libnss3 libnspr4 libxkbcommon-x11-0 libxcb-cursor0 libxcb-keysyms1
      libgbm1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0
      libxcomposite1 libxdamage1 libxrandr2 libpango-1.0-0 libcairo2 libgtk-3-0 libx11-xcb1
      libxi6 libxtst6 libxcursor1 libxshmfence1 xdg-utils xclip)

MISSING=()
for pk in "${DEPS[@]}"; do
  if command -v dpkg >/dev/null 2>&1; then
    dpkg -s "$pk" >/dev/null 2>&1 || MISSING+=("$pk")
  else
    MISSING+=("$pk")
  fi
done

if (( CHECK )); then
  if (( ${#MISSING[@]} == 0 )); then
    echo "运行时依赖已齐全（${#DEPS[@]} 个包都在）"
  else
    echo "缺 ${#MISSING[@]} 个：${MISSING[*]}"
  fi
  exit 0
fi

say "解析官方下载地址（linux-$ARCH）"
URL="$(curl -fsSL --compressed -m 40 "$PAGE" 2>/dev/null \
      | grep -oE "https://[A-Za-z0-9./_-]+/antigravity-hub/[A-Za-z0-9._-]+/linux-$ARCH/Antigravity\.tar\.gz" \
      | head -1 || true)"
[[ -n "$URL" ]] || die "没从 $PAGE 解析到 linux-$ARCH 包（官网结构可能变了，手动下载后重跑）"
echo "    $URL"

say "下载并解压到 $DIR"
mkdir -p "$DIR" 2>/dev/null || die "无法创建 $DIR（用 ANTIGRAVITY_DIR=/别的/位置 指定）"
if [[ -f "$DIR/Antigravity.tar.gz" && -x "$(find "$DIR" -maxdepth 2 -name antigravity -type f 2>/dev/null | head -1)" ]]; then
  echo "    已存在，跳过下载（删掉 $DIR 可重装）"
else
  curl -fL --retry 3 --retry-delay 2 -o "$DIR/Antigravity.tar.gz" "$URL"
  tar xzf "$DIR/Antigravity.tar.gz" -C "$DIR"
fi
BIN="$(find "$DIR" -maxdepth 2 -name antigravity -type f | head -1)"
[[ -n "$BIN" ]] || die "解压后找不到 antigravity 可执行文件"
chmod +x "$BIN"


say "运行时依赖"
if (( ${#MISSING[@]} == 0 )); then
  ok "已齐全（${#DEPS[@]} 个包都在），不需要 sudo"
elif (( NO_DEPS )); then
  warn "缺 ${MISSING[*]}，但指定了 --no-deps，跳过安装"
elif ! command -v apt-get >/dev/null 2>&1; then
  die "本脚本只处理 Debian/Ubuntu 的依赖。其它发行版请手动装：
       Fedora:  sudo dnf install nss nspr libxkbcommon xcb-util-cursor gtk3 alsa-lib \
                         cups-libs libdrm mesa-libgbm atk at-spi2-atk pango cairo xdg-utils xclip
       Arch:    sudo pacman -S nss nspr libxkbcommon xcb-util-cursor gtk3 alsa-lib \
                         cups libdrm mesa at-spi2-atk pango cairo xdg-utils xclip"
else
  say "缺 ${#MISSING[@]} 个：${MISSING[*]}"
  say "现在安装（sudo 会在这里提示你输入密码）"
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -qq || warn "apt update 失败，继续尝试安装"
    sudo apt-get install -y "${MISSING[@]}" || die "依赖安装失败，可手动执行：sudo apt-get install -y ${MISSING[*]}"
  else
    apt-get install -y "${MISSING[@]}" || die "无法自动安装（没有 sudo），请手动：apt-get install -y ${MISSING[*]}"
  fi
  ok "依赖装好了"
fi

say "修 chrome-sandbox（Electron/Chromium 在 Linux 的标准步骤）"
SB="$(dirname "$BIN")/chrome-sandbox"
if [[ -f "$SB" ]]; then
  sudo chown root:root "$SB"
  sudo chmod 4755 "$SB"
  ls -l "$SB"
else
  echo "    没有 chrome-sandbox，跳过"
fi

say "注册到应用菜单"
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/antigravity.desktop" <<DESK
[Desktop Entry]
Type=Application
Version=1.0
Name=Antigravity
Comment=Google Antigravity
Exec=$BIN %U
Terminal=false
StartupNotify=true
Categories=Development;IDE;
StartupWMClass=Antigravity
DESK
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

say "完成"
cat <<TIP
启动： $BIN

要让它把「用 Google 登录」的弹窗送进某个账户环境：
  ./bin/install-shortcuts.sh --accounts 1 --as-default 1
  $BIN

细节与已知坑见 docs/antigravity.md
TIP
