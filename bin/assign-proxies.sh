#!/usr/bin/env bash
# =============================================================================
#  assign-proxies.sh —— 给每个账户按 round-robin 绑定一个 SOCKS5 代理
#
#  用法（环境变量）：
#    GACC_PX_HOST=1.2.3.4 GACC_PX_PORTS=1080-1089 \
#    GACC_PX_USER=u GACC_PX_PASS=p ./bin/assign-proxies.sh
#
#    GACC_PX_HOST    代理域名或 IP（必填）
#    GACC_PX_PORTS   端口范围 "1080-1089" 或列表 "1080,1083,1087"（必填）
#    GACC_PX_USER    用户名（可选）
#    GACC_PX_PASS    密码（可选）
#    GACC_PX_SCHEME  socks5（默认）/ socks5h / http / https
#
#  用法（命令行，覆盖环境变量）：
#    ./bin/assign-proxies.sh --host 1.2.3.4 --ports 1080-1089 --user u --pass p
#    ./bin/assign-proxies.sh --accounts 1-5 --dry-run
#    ./bin/assign-proxies.sh --accounts 1-5 --check      # 逐个测连通 + 检测 IP 轮换
#    ./bin/assign-proxies.sh --accounts 1-5 --sync-tz    # 顺便把时区对齐到出口 IP
#
#  已有代理的账户默认跳过（不会被静默改写）；确实要改加 --force。
#
#  分配规则：账户号 i 依次取第 (i-1) % 端口数 个端口，即 round-robin。
#  写入 profiles/accNN/proxy.conf（权限 600），并在下次启动时渲染进 user.js。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GACC="$ROOT/bin/gacc"

HOST="${GACC_PX_HOST:-}"
PORTS="${GACC_PX_PORTS:-}"
USER_="${GACC_PX_USER:-}"
PASS_="${GACC_PX_PASS:-}"
SCHEME="${GACC_PX_SCHEME:-socks5}"
ACCOUNTS=""
DRY=0
CHECK=0
SYNC_TZ=0
FORCE=0
ECHO_URL="${GACC_PX_ECHO:-https://chatgpt.com/cdn-cgi/trace}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)     HOST="${2:?}"; shift 2 ;;
    --ports)    PORTS="${2:?}"; shift 2 ;;
    --user)     USER_="${2:?}"; shift 2 ;;
    --pass)     PASS_="${2:?}"; shift 2 ;;
    --scheme)   SCHEME="${2:?}"; shift 2 ;;
    --accounts) ACCOUNTS="${2:?}"; shift 2 ;;
    --dry-run)  DRY=1; shift ;;
    --check)    CHECK=1; shift ;;
    --sync-tz)  SYNC_TZ=1; shift ;;
    --force)    FORCE=1; shift ;;
    --echo)     ECHO_URL="${2:?}"; shift 2 ;;
    -h|--help)  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "不认识的参数：$1" ;;
  esac
done

[[ -x "$GACC" ]] || die "找不到 $GACC"
[[ -n "$HOST" ]] || die "缺少 --host（或环境变量 GACC_PX_HOST）"
[[ -n "$PORTS" ]] || die "缺少 --ports（或环境变量 GACC_PX_PORTS），例如 1080-1089"
[[ "$USER_" == *@* ]] && die "用户名里不能有 @"
[[ "$PASS_" == *@* ]] && die "密码里不能有 @（会破坏 URL 解析）"

# ---------- 展开端口列表 ----------
PORTS_LIST=()
if [[ "$PORTS" == *-* ]]; then
  lo="${PORTS%%-*}"; hi="${PORTS##*-}"
  [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || die "端口范围格式：1080-1089"
  (( lo <= hi )) || die "端口范围起始大于结束：$PORTS"
  for ((p=lo; p<=hi; p++)); do PORTS_LIST+=("$p"); done
else
  IFS=',' read -ra PORTS_LIST <<< "$PORTS"
  for p in "${PORTS_LIST[@]}"; do [[ "$p" =~ ^[0-9]+$ ]] || die "端口不是数字：$p"; done
fi
(( ${#PORTS_LIST[@]} > 0 )) || die "端口列表为空"

# ---------- 展开账户列表 ----------
ACC_LIST=()
if [[ -n "$ACCOUNTS" ]]; then
  if [[ "$ACCOUNTS" == *-* ]]; then
    a="${ACCOUNTS%%-*}"; b="${ACCOUNTS##*-}"
    for ((n=a; n<=b; n++)); do ACC_LIST+=("$n"); done
  else
    IFS=',' read -ra ACC_LIST <<< "$ACCOUNTS"
  fi
else
  for d in "$ROOT"/profiles/acc*; do
    [[ -d "$d" ]] || continue
    n="${d##*/acc}"; [[ "$n" =~ ^[0-9]+$ ]] && ACC_LIST+=("$((10#$n))")
  done
fi
(( ${#ACC_LIST[@]} > 0 )) || die "没有可分配的账户（profiles/ 下没有 accNN）"

spec_for() {  # $1=account -> socks5://user:pass@host:port
  local idx=$(( ($1 - 1) % ${#PORTS_LIST[@]} ))
  local port="${PORTS_LIST[$idx]}" auth=""
  [[ -n "$USER_" ]] && auth="$USER_:${PASS_}"
  if [[ -n "$auth" ]]; then
    printf '%s://%s@%s:%s' "$SCHEME" "$auth" "$HOST" "$port"
  else
    printf '%s://%s:%s' "$SCHEME" "$HOST" "$port"
  fi
}

mask() {  # 隐藏密码
  local spec="$1"
  if [[ "$spec" == *@* ]]; then printf '%s://%s:***@%s' "${spec%%://*}" "$(printf '%s' "${spec#*://}" | cut -d@ -f1 | cut -d: -f1)" "${spec##*@}"
  else printf '%s' "$spec"; fi
}

# 已有非 direct 绑定的账户默认跳过：重跑脚本不该改写既有出口
SKIP_LIST=()
PLAN_LIST=()
for n in "${ACC_LIST[@]}"; do
  cur="$(cat "$ROOT/profiles/acc$(printf '%02d' "$n")/proxy.conf" 2>/dev/null || echo '')"
  if [[ -n "$cur" && "$cur" != direct && $FORCE -eq 0 ]]; then SKIP_LIST+=("$n")
  else PLAN_LIST+=("$n"); fi
done

step "分配方案（round-robin，${#PORTS_LIST[@]} 个端口 / ${#PLAN_LIST[@]} 个账户待分配）"
printf '  %-8s %-6s %-12s %s\n' 账户 端口 动作 代理
for n in "${PLAN_LIST[@]}"; do
  spec="$(spec_for "$n")"; port="${spec##*:}"
  cur="$(cat "$ROOT/profiles/acc$(printf '%02d' "$n")/proxy.conf" 2>/dev/null || echo '')"
  act="绑定"; [[ -n "$cur" && "$cur" != direct ]] && act="覆盖"
  printf '  acc%02d   %-6s %-12s %s\n' "$n" "$port" "$act" "$(mask "$spec")"
  if [[ "$act" == 覆盖 ]]; then printf '           %-12s ↑ 原为 %s\n' "" "$(mask "$cur")"; fi
done
for n in "${SKIP_LIST[@]}"; do
  printf '  acc%02d   %-6s %-12s %s\n' "$n" "-" "已绑定·跳过" "$(mask "$(cat "$ROOT/profiles/acc$(printf '%02d' "$n")/proxy.conf")")"
done
(( ${#SKIP_LIST[@]} > 0 )) && say "  （已有出口的账户不会被改动；确实要改请加 --force）"

if (( ${#PLAN_LIST[@]} == 0 )); then
  say ""
  say "所有目标账户都已有代理，无需改动。"
  exit 0
fi

if (( DRY )); then
  say ""
  say "（--dry-run，未写入任何文件）"
  exit 0
fi

step "写入 proxy.conf 并渲染 user.js"
for n in "${PLAN_LIST[@]}"; do
  spec="$(spec_for "$n")"
  "$GACC" "$n" --proxy "$spec" --render >/dev/null 2>&1 \
    && printf '  ✔ acc%02d → %s\n' "$n" "${spec#*@}" \
    || warn "acc$n 写入失败"
done

# ---------- 连通性 + 轮换检测 ----------
if (( CHECK )); then
  step "连通性与出口稳定性（每个代理连查 3 次）"
  command -v curl >/dev/null 2>&1 || { warn "没有 curl，跳过检查"; exit 0; }
  for n in "${ACC_LIST[@]}"; do
    spec="$(spec_for "$n")"
    ips=""
    for i in 1 2 3; do
      ip="$(curl -sS -m 6 --proxy "$spec" "$ECHO_URL" 2>/dev/null | sed -n 's/^ip=//p')"
      if [[ -z "$ip" ]]; then
        # 第一次就连不通，不用再试后面两次
        (( i == 1 )) && break
        continue
      fi
      ips+="$ip"$'\n'
    done
    uniq="$(printf '%s' "$ips" | grep . | sort -u | paste -sd' ' || true)"
    if [[ -z "$uniq" ]]; then
      printf '  acc%02d  ✘ 连不通（%s）\n' "$n" "${spec#*@}"
    elif [[ "$(printf '%s' "$ips" | grep . | sort -u | wc -l)" -gt 1 ]]; then
      printf '  acc%02d  ⚠ 出口在轮换：%s\n' "$n" "$uniq"
    else
      printf '  acc%02d  ✔ 出口固定：%s\n' "$n" "$uniq"
    fi
  done
fi

# ---------- 时区对齐 ----------
if (( SYNC_TZ )); then
  step "按出口 IP 对齐时区"
  for n in "${ACC_LIST[@]}"; do "$GACC" "$n" --sync-tz 2>&1 | sed 's/^/  /'; done
fi

{
  echo "# 账户 → 代理（密码已省略）  生成于 $(date -Iseconds)"
  for n in "${PLAN_LIST[@]}"; do printf 'acc%02d %s\n' "$n" "$(mask "$(spec_for "$n")")"; done
} > "$ROOT/profiles/.proxy-map"
say ""
say "分配表已写入 profiles/.proxy-map（不含密码）"
say "完成。下次启动各账户时生效：./bin/gacc <n>"
say "提示：一个账户应长期固定同一个出口；轮换会让 Google 判为异常。"
