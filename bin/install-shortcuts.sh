#!/usr/bin/env bash
# ============================================================
# install-shortcuts.sh —— 给每个账户生成「点一下就开」的入口
#
#   ./bin/install-shortcuts.sh                 # 按已有 profile 生成（1..N）
#   ./bin/install-shortcuts.sh --accounts "1 2 3 4"
#   ./bin/install-shortcuts.sh --system        # 装到 /usr/share/applications（要 sudo）
#   ./bin/install-shortcuts.sh --dry-run       # 只打印，不写
#
# 会生成两套：
#   1) Linux .desktop → WSLg 自动收进 Windows「开始菜单」（就是你记的那个 Firefox 快捷方式）
#   2) Windows 桌面 .lnk → 指向 wsl.exe -d <发行版> -e <gacc> <N>，双开命中率最高
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GACC="$ROOT/bin/gacc"
ACCOUNTS=""
MODE=user
DRY=0
OUTDIR=""
NO_WIN=0
WITH_FONTS=0
AS_DEFAULT=""
REVERT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --accounts) ACCOUNTS="${2:?}"; shift 2 ;;
    --system)   MODE=system; shift ;;
    --outdir)   OUTDIR="${2:?}"; shift 2 ;;
    --no-windows) NO_WIN=1; shift ;;
    --with-fonts) WITH_FONTS=1; shift ;;
    --as-default) AS_DEFAULT="${2:?--as-default 后面要跟账户号}"; shift 2 ;;
    --revert-default) REVERT=1; shift ;;
    --dry-run)  DRY=1; shift ;;
    -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 1 ;;
  esac
done

[[ -x "$GACC" ]] || { echo "找不到 $GACC" >&2; exit 1; }

# 默认：已有 profile 的账户号
if [[ -z "$ACCOUNTS" ]]; then
  ACCOUNTS="$(ls -d "$ROOT"/profiles/acc* 2>/dev/null | sed 's/.*acc0*//' | sort -n | tr '\n' ' ')"
  [[ -n "${ACCOUNTS// }" ]] || ACCOUNTS="1 2 3"
fi

if [[ -n "$OUTDIR" ]]; then
  APP_DIR="$OUTDIR"
elif [[ "$MODE" == system ]]; then
  APP_DIR=/usr/share/applications
else
  APP_DIR="$HOME/.local/share/applications"
fi

echo "账户：$ACCOUNTS"
echo "目录：$APP_DIR"
echo

# ---------------- 0) 顺便给每个账户开字体子集 ----------------
if (( WITH_FONTS )); then
  for n in $ACCOUNTS; do
    if [[ -f "$ROOT/profiles/acc$(printf '%02d' "$n")/fonts.conf" ]]; then
      echo "  字体子集已存在：账户 $n"
    elif (( DRY )); then
      echo "  （dry-run）将会生成字体子集：账户 $n"
    else
      "$ROOT/bin/gen-fonts.sh" "$n" >/dev/null && echo "  ✔ 生成字体子集：账户 $n"
    fi
  done
  echo
fi

# ---------------- 1) .desktop ----------------
if (( ! DRY )); then mkdir -p "$APP_DIR" 2>/dev/null || sudo mkdir -p "$APP_DIR"; fi
for n in $ACCOUNTS; do
  f="$APP_DIR/gacc-acc$(printf '%02d' "$n").desktop"
  body="[Desktop Entry]
Type=Application
Version=1.0
Name=Firefox 账户 $(printf '%02d' "$n")
Comment=Google 账户 $n（独立 profile + 独立指纹人设）
Exec=$GACC $n %u
TryExec=$GACC
Icon=firefox
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/about;text/html;text/xml;application/xhtml+xml;
StartupWMClass=gacc-$n"
  if (( DRY )); then
    echo "--- $f ---"; printf '%s\n' "$body"; echo
  else
    printf '%s\n' "$body" > "$f"
    chmod 644 "$f"
    echo "✔ $f"
    # 开始菜单能认，但第一次可能要刷新一下
  fi
done

# ---------------- 1.5) 设为 Linux 默认浏览器 ----------------
if [[ -n "$AS_DEFAULT" ]]; then
  f="$APP_DIR/gacc-acc$(printf '%02d' "$AS_DEFAULT").desktop"
  [[ -f "$f" ]] || { echo "找不到 $f，先生成快捷方式" >&2; exit 1; }
  if (( DRY )); then
    echo "（dry-run）会执行：xdg-settings set default-web-browser $(basename "$f")"
  else
    # 记下原来的默认浏览器，--revert-default 才有东西可还原
    PREV="$(xdg-settings get default-web-browser 2>/dev/null || true)"
    if [[ -n "$PREV" ]]; then
      printf '%s\n' "$PREV" > "$APP_DIR/.gacc-prev-browser" 2>/dev/null || true
      echo "   （原默认浏览器已记录：$PREV）"
    fi
    update-desktop-database "$APP_DIR" 2>/dev/null || true
    xdg-mime default "$(basename "$f")" x-scheme-handler/http x-scheme-handler/https \
      text/html application/xhtml+xml 2>/dev/null || true
    if xdg-settings set default-web-browser "$(basename "$f")"; then
      echo "✔ Linux 默认浏览器已设为 $(basename "$f")"
      echo "  验证：xdg-settings get default-web-browser  →  $(xdg-settings get default-web-browser 2>/dev/null)"
    else
      echo "! 设置失败。手动：xdg-settings set default-web-browser $(basename "$f")" >&2
    fi
  fi
  echo
fi

if (( REVERT )) && (( ! DRY )); then
  PREVFILE="$APP_DIR/.gacc-prev-browser"
  prev=""
  [[ -f "$PREVFILE" ]] && prev="$(cat "$PREVFILE" 2>/dev/null || true)"
  if [[ -z "$prev" ]]; then
    # 没有记录过原值：只挑真实存在的 .desktop，别硬编码 firefox.desktop
    for cand in firefox.desktop firefox-esr.desktop chromium.desktop \
                google-chrome.desktop microsoft-edge.desktop; do
      if [[ -f "$APP_DIR/$cand" || -f "/usr/share/applications/$cand" ]]; then
        prev="$cand"; break
      fi
    done
  fi
  if [[ -z "$prev" ]]; then
    echo "! 没有记录过原来的默认浏览器，也没找到常见的浏览器 .desktop。" >&2
    echo "  手动设：xdg-settings set default-web-browser <名字>.desktop" >&2
    echo "  当前目录里有的：$(ls "$APP_DIR" 2>/dev/null | tr '\n' ' ')" >&2
    exit 1
  fi
  if xdg-settings set default-web-browser "$prev"; then
    echo "✔ 已还原为 $prev"
    rm -f "$PREVFILE"
  else
    echo "! 还原失败，手动：xdg-settings set default-web-browser $prev" >&2
  fi
  echo
fi

# ---------------- 2) Windows 桌面 .lnk ----------------
if (( ! NO_WIN )) && command -v powershell.exe >/dev/null 2>&1; then
  DISTRO="${WSL_DISTRO_NAME:-}"
  if [[ -z "$DISTRO" ]]; then
    DISTRO="Ubuntu"
    echo "  ! 读不到 WSL_DISTRO_NAME，桌面快捷方式默认按 -d Ubuntu 生成" >&2
    echo "    如果不是这个名字，右键快捷方式→属性，把 -d 后面的参数改成你的发行版名" >&2
    echo "    （在终端跑 \`wsl.exe -l -q\` 可以看列表）" >&2
  fi
  # PowerShell 里这段是单引号字符串，路径中含 ' 必须转义成 ''，否则参数被截断
  PS_GACC="${GACC//\'/\'\'}"
  PS_DISTRO="${DISTRO//\'/\'\'}"
  PS="$ROOT/share/windows-shortcuts.ps1"
  mkdir -p "$ROOT/share"
  ACCT_PS="$(for n in $ACCOUNTS; do printf '%s,' "$n"; done | sed 's/,$//')"

  printf '\xef\xbb\xbf' > "$PS"          # UTF-8 BOM，避免中文乱码
  cat >> "$PS" <<PSEOF
\$ErrorActionPreference = 'Stop'
\$desktop = [Environment]::GetFolderPath('Desktop')
\$wsl = Join-Path \$env:SystemRoot 'System32\wsl.exe'
\$ffIcon = 'C:\Program Files\Mozilla Firefox\firefox.exe,0'
\$sh = New-Object -ComObject WScript.Shell
foreach (\$n in @($ACCT_PS)) {
  \$name = ('Firefox 账户 {0:D2}' -f \$n)
  \$lnk = Join-Path \$desktop (\$name + '.lnk')
  \$s = \$sh.CreateShortcut(\$lnk)
  \$s.TargetPath = \$wsl
  \$s.Arguments = '-d $PS_DISTRO -e $PS_GACC ' + \$n
  \$s.WorkingDirectory = \$env:USERPROFILE
  \$s.WindowStyle = 7
  \$s.IconLocation = \$ffIcon
  \$s.Description = ('Google 账户 ' + \$n)
  \$s.Save()
  Write-Output ('created: ' + \$lnk)
}
PSEOF

  if (( DRY )); then
    echo "--- $PS （然后执行 powershell -File 它）---"; cat "$PS"; echo
  else
    echo
    echo "生成 Windows 桌面快捷方式（发行版 $DISTRO）…"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(wslpath -w "$PS")" 2>&1 | tr -d '\r'
  fi
fi

echo
cat <<'TIP'
提示：
- WSLg 会把 ~/.local/share/applications/*.desktop 收进 Windows「开始菜单」，
  名字是 "Firefox 账户 NN"，跟当初装 Firefox 时那个快捷方式同一套机制。
  刚生成如果没出现，`wsl.exe --shutdown` 后重开终端即可。
- 桌面上的 .lnk 用的是 wsl.exe -e，最小化窗口启动，不会挡屏幕。
- 想改图标：改 .desktop 里的 Icon= 或 .lnk 的 IconLocation。
TIP
