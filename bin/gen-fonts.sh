#!/usr/bin/env bash
# ============================================================
# gen-fonts.sh —— 给某个账户生成「只看得见一部分字体」的 fontconfig
#
#   ./bin/gen-fonts.sh 3          生成 profiles/acc03/fonts.conf + fonts/
#   ./bin/gen-fonts.sh 3 --show   生成后打印它实际看到的家族
#   ./bin/gen-fonts.sh 3 --plain  只打印选中的字体，不写文件
#
# 原理：FONTCONFIG_FILE 指向本账户的 fonts.conf，fontconfig 只扫 <dir> 里的软链接。
# 选择规则：
#   基础（强制，按文件名）：DejaVu Sans / Serif / Sans Mono + NotoSansCJK + ColorEmoji
#   可变（3~6 个）：只从「普通桌面常见字体」白名单里挑，避开 Tangut / SignWriting 这类冷门
#   唯一性：生成时和已有账户比对签名，撞了就换偏移，保证每个账户的子集不一样
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -ge 1 ]] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
ACC="$1"; shift || true
SHOW=0; PLAIN=0
for a in "$@"; do
  case "$a" in
    --show) SHOW=1 ;;
    --plain) PLAIN=1 ;;
    *) echo "不认识的参数：$a" >&2; exit 1 ;;
  esac
done

[[ "$ACC" =~ ^[0-9]+$ ]] || { echo "账户号要是数字" >&2; exit 1; }
NN="$(printf '%02d' "$ACC")"
PROF="$ROOT/profiles/acc$NN"
FDIR="$PROF/fonts"
CONF="$PROF/fonts.conf"
FTMP="$ROOT/runtime/acc$NN/fontcache"

# 普通桌面会有的字体族（白名单）。故意不含 Nerd Font，也不含 Tangut/SignWriting 这类冷门字。
COMMON_RE='^(DejaVu (Sans|Serif|Sans Mono)( Condensed)?|Liberation (Sans|Serif|Mono)|Ubuntu( Mono)?|Free(Sans|Serif|Mono)|Noto (Sans|Serif|Mono)|Noto Sans Mono|Noto Color Emoji|Noto Sans CJK (SC|TC|JP|KR|HK)|Noto Sans Mono CJK (SC|TC|JP|KR|HK)|Noto Sans Symbols2?|Nimbus (Sans|Roman|Mono)( L)?|TeX Gyre .*|Arimo|Tinos|Cousine|Carlito|Caladea|Croscore .*|Lohit .*|Kacst[A-Za-z]*|Un(Batang|Dinaru|Dotum|Graphic|Gungseo|Pilgi))$'

mapfile -t PAIRS < <(fc-list --format '%{file}|%{family[0]}\n' 2>/dev/null | sort -u)
CANDS=(); BASE=()
declare -A seen=()
for line in "${PAIRS[@]}"; do
  f="${line%%|*}"; fam="${line#*|}"
  # 基础字体按文件名强制包含：NotoSansCJK 是 .ttc，每张脸的 family[0] 顺序不同
  # （可能报成 "Noto Sans Mono CJK TC"），靠 family 名判断会漏掉，导致中文全丢。
  case "$f" in
    */dejavu/DejaVuSans.ttf|*/dejavu/DejaVuSans-Bold.ttf|*/dejavu/DejaVuSerif.ttf|\
    */dejavu/DejaVuSansMono.ttf|*/noto/NotoSansCJK-Regular.ttc|*/noto/NotoColorEmoji.ttf)
      [[ -n "${seen[$f]:-}" ]] && continue
      seen[$f]=1; BASE+=("$f"); continue ;;
  esac
  [[ "$fam" =~ $COMMON_RE ]] || continue
  [[ -n "${seen[$f]:-}" ]] && continue
  seen[$f]=1; CANDS+=("$f")
done

(( ${#BASE[@]} )) || { echo "基础字体一个都没找到（装了 DejaVu 和 Noto CJK 吗？）" >&2; exit 1; }

# 分组互斥：候选池按 index % GROUP 分成若干组，账户只从自己那组里取。
# 这样两个账户之间只共享「必含基础字体」，差异最大化；同时每个账户的字体集
# 依然是个合理的桌面子集（不会出现同一台机器上几十种语言字体全齐的怪相）。
N=${#CANDS[@]}
GROUP=4
ARITY=$(( ACC % GROUP ))
mapfile -t MYGROUP < <(i=0; while (( i < N )); do if (( i % GROUP == ARITY )); then printf '%s\n' "${CANDS[$i]}"; fi; i=$((i+1)); done)
M=${#MYGROUP[@]}
K=$(( 6 + ACC % 4 ))                      # 从本组里取 6~9 个

build_set() { local seed=$1 i; local out=("${BASE[@]}")
  if (( M > 0 )); then
    for i in $(seq 0 $((K-1))); do out+=("${MYGROUP[$(( (seed + i) % M ))]}"); done
  fi
  printf '%s\n' "${out[@]}" | awk '!s[$0]++' | sort
}
sig() { while read -r l; do basename "$l"; done | sort | md5sum | cut -c1-8; }

# 与已有账户比对签名，撞了就往后挪（同组内基本不会撞）
CHOSEN=(); SIG=""
for try in $(seq 0 15); do
  mapfile -t CHOSEN < <(build_set $(( (ACC * 3 + try) % (M > 0 ? M : 1) )))
  SIG="$(printf '%s\n' "${CHOSEN[@]}" | sig)"
  clash=0
  for other in "$ROOT"/profiles/acc*/fonts/.set; do
    [[ -f "$other" ]] || continue
    [[ "$other" == "$FDIR/.set" ]] && continue
    [[ "$(cat "$other")" == "$SIG" ]] && { clash=1; break; }
  done
  (( clash == 0 )) && break
done

if (( PLAIN )); then printf '%s\n' "${CHOSEN[@]}"; exit 0; fi

mkdir -p "$PROF" "$FTMP"
rm -rf "$FDIR"; mkdir -p "$FDIR"
for f in "${CHOSEN[@]}"; do ln -sf "$f" "$FDIR/$(basename "$f")"; done
printf '%s\n' "$SIG" > "$FDIR/.set"

cat > "$CONF" <<EOF
<?xml version="1.0"?>
<!-- 账户 $NN 专用字体子集（签名 $SIG），由 bin/gen-fonts.sh 生成，重跑同名命令覆盖 -->
<fontconfig>
  <dir>$FDIR</dir>
  <cachedir>$FTMP</cachedir>
</fontconfig>
EOF

echo "账户 $NN: ${#CHOSEN[@]} 个字体文件 / 签名 $SIG ← 候选池 ${N}"
if (( SHOW )); then
  echo "--- 可见的中文家族 ---"
  FONTCONFIG_FILE="$CONF" fc-list :lang=zh --format '%{family[0]}\n' 2>/dev/null | sort -u | sed 's/^/  /'
  echo "--- 家族数：系统 $(fc-list --format '%{family[0]}\n' | sort -u | wc -l) → 本账户 $(FONTCONFIG_FILE="$CONF" fc-list --format '%{family[0]}\n' | sort -u | wc -l) ---"
fi
