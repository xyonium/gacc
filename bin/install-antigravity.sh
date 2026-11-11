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

ARCH="${1:-x64}"
case "$ARCH" in
  x64|arm|arm64) [[ "$ARCH" == arm64 ]] && ARCH=arm ;;
  *) echo "用法：$0 [x64|arm]" >&2; exit 1 ;;
esac

DIR="${ANTIGRAVITY_DIR:-$HOME/opt/antigravity}"
PAGE="https://antigravity.google/download"

say() { printf '\n\033[32m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

for t in curl tar awk grep; do
  command -v "$t" >/dev/null 2>&1 || die "缺少命令 $t"
done

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

say "安装运行时依赖（需要 sudo）"
sudo apt update
sudo apt install -y \
  libnss3 libnspr4 libxkbcommon-x11-0 libxcb-cursor0 libxcb-keysyms1 \
  libgbm1 libasound2 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 libxkbcommon0 \
  libxcomposite1 libxdamage1 libxrandr2 libpango-1.0-0 libcairo2 libgtk-3-0 libx11-xcb1 \
  libxi6 libxtst6 libxcursor1 libxshmfence1 xdg-utils

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
