#!/usr/bin/env bash
# ==============================================================================
#  deploy-gacc.sh —— 一键部署「一个 Google 账户 = 一个 Firefox profile + 独立代理」
#
#  面向：WSL2 / 容器 / 没有 root 的 Linux 环境（不需要 apt install，不动系统）
#
#  用法：
#     bash deploy-gacc.sh                          # 装到 ./gaccounts，1 个账户 + 快捷方式
#     bash deploy-gacc.sh --dir ~/gacc --accounts 5 --base-port 1081
#     bash deploy-gacc.sh --proxy-mode direct      # 全部直连（没有代理时用这个）
#     bash deploy-gacc.sh --force                  # 重新下载 Firefox
#
#  做完之后：
#     cd gaccounts && ./bin/gacc 1
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$SCRIPT_DIR/gaccounts"
ACCOUNTS=1
BASE_PORT=1081
PROXY_MODE="auto"          # auto | direct | socks5 | http
LANG_CODE="zh-CN"
FF_URL="${FF_URL:-}"
FORCE=0
SKIP_SMOKE=0
NO_SHORTCUTS=0

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
step()  { printf '\n%s==>%s %s\n' "$c_ok" "$c_off" "$*"; }
ok()    { printf '    %s✔%s %s\n' "$c_ok" "$c_off" "$*"; }
warn()  { printf '    %s!%s %s\n' "$c_warn" "$c_off" "$*"; }
note()  { printf '    %s%s%s\n' "$c_dim" "$*" "$c_off"; }
die()   { printf '\n%s✘ %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)          DIR="${2:?--dir 后面要跟路径}"; shift 2 ;;
    --accounts)     ACCOUNTS="${2:?}"; shift 2 ;;
    --base-port)    BASE_PORT="${2:?}"; shift 2 ;;
    --proxy-mode)   PROXY_MODE="${2:?}"; shift 2 ;;
    --lang)         LANG_CODE="${2:?}"; shift 2 ;;
    --ff-url)       FF_URL="${2:?}"; shift 2 ;;
    --no-smoke)     SKIP_SMOKE=1; shift ;;
    --no-shortcuts) NO_SHORTCUTS=1; shift ;;
    --force)        FORCE=1; shift ;;
    -h|--help)      usage ;;
    *) die "不认识的参数：$1（--help 看用法）" ;;
  esac
done

[[ "$ACCOUNTS" =~ ^[0-9]+$ ]] && (( ACCOUNTS >= 1 )) || die "--accounts 要是正整数"
[[ "$BASE_PORT" =~ ^[0-9]+$ ]] || die "--base-port 要是数字"
case "$PROXY_MODE" in auto|direct|socks5|http) ;; *) die "--proxy-mode 只能是 auto/direct/socks5/http" ;; esac

mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
printf '%s\n' "部署目标：$DIR"

# ---------------------------------------------------------------- 1. 预检
step "环境预检"

for t in curl tar awk sed find dpkg grep; do
  command -v "$t" >/dev/null 2>&1 || die "缺少命令 $t"
done
ok "基础命令齐全"

if [[ -n "${DISPLAY:-}" ]]; then
  ok "DISPLAY=$DISPLAY（WSLg / X11 可用）"
else
  warn "没有 DISPLAY，浏览器窗口起不来（只装配置？给 --no-smoke 可跳过自检）"
fi

if command -v apt-get >/dev/null 2>&1; then
  HAVE_APT=1; ok "apt-get 可用（用来补 .so，不需要 root）"
else
  HAVE_APT=0; warn "没有 apt-get：缺库时需要你手动装（见下文提示）"
fi

# 有没有 user namespace —— 决定 Firefox 自带沙箱能不能开
USERNS=1
if ! unshare --user --map-root-user true >/dev/null 2>&1; then USERNS=0; fi
if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]] &&
   [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" == "0" ]]; then USERNS=0; fi
if (( USERNS )); then
  ok "unprivileged user namespace 可用 → Firefox 沙箱保持开启"
else
  warn "user namespace 被禁（容器/沙箱环境常见）→ 启动时会自动关闭 Firefox 内容沙箱"
  note "代价：网页内容失去进程级隔离，且地址栏下会出现黄条。你自己的终端里通常不会走到这一步。"
fi

free_kb=$(df -Pk "$DIR" | awk 'NR==2{print $4}')
(( free_kb > 1200000 )) || warn "剩余空间 $((free_kb/1024))MB，建议留 1.5GB 以上"

# ---------------------------------------------------------------- 2. Firefox
step "准备便携版 Firefox"
FFBIN="$DIR/firefox/firefox"

resolve_url() {
  local u="${FF_URL}"
  if [[ -z "$u" ]]; then
    u="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=${LANG_CODE}"
  fi
  curl -fsSIL -m 40 -o /dev/null -w '%{url_effective}' "$u" 2>/dev/null || true
}

# 用 Mozilla 官方的 SHA256SUMS 校验下载物。拿不到就告警放行（镜像站可能不提供），
# 能拿到但哈希不符则直接中止——宁可装不上，也不装一个被替换过的浏览器。
verify_tarball() {
  local url="$1" file="$2" base sums want got
  command -v sha256sum >/dev/null 2>&1 || { warn "系统没有 sha256sum，跳过校验"; return 0; }
  [[ -f "$file" ]] || return 0
  base="${url%/linux-x86_64/*}"
  sums="$DIR/download/SHA256SUMS"
  if ! curl -fsSL -m 60 -o "$sums" "$base/SHA256SUMS" 2>/dev/null; then
    warn "拿不到 $base/SHA256SUMS，跳过校验（建议手动核对）"
    return 0
  fi
  # 必须按「相对路径」匹配，不能只看文件名：SHA256SUMS 里
  # linux-x86_64/en-US/firefox-X.tar.xz 和 linux-x86_64/zh-CN/firefox-X.tar.xz
  # 同名但哈希不同，按 basename 匹配会取到别的语言包。
  rel="$(printf '%s' "$url" | sed -E 's#^.*/releases/[^/]+/##')"
  # 自定义 --ff-url（镜像/自建源）可能不含 /releases/<ver>/ 结构，此时 rel 会等于整条 URL
  [[ "$rel" == *"/"* && "$rel" != *"://"* ]] || rel=""
  want=""
  [[ -n "$rel" ]] && want="$(awk -v r="$rel" '$2 == r {print $1; exit}' "$sums")"
  if [[ -z "$want" ]]; then
    # 镜像站布局可能不同：退回到 basename，但要求唯一命中，否则不放行
    local cand
    cand="$(awk -v b="$(basename "$file")" 'substr($2, length($2)-length(b)+1) == b {print $1}' "$sums" | sort -u)"
    if [[ -n "$cand" && "$(printf '%s\n' "$cand" | wc -l)" -eq 1 ]]; then
      want="$cand"
    else
      warn "SHA256SUMS 里无法唯一确定 $(basename "$file")，跳过校验"
      return 0
    fi
  fi
  got="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$got" == "$want" ]]; then
    ok "SHA256 校验通过（${got:0:16}…）"
  else
    die "SHA256 不匹配！期望 $want，实际 $got —— 已中止，请检查网络或镜像"
  fi
}

if [[ -x "$FFBIN" && $FORCE -eq 0 ]]; then
  ok "已有 $FFBIN，跳过下载（--force 可重装）"
else
  URL="$(resolve_url)"
  [[ -n "$URL" ]] || die "解析 Firefox 下载地址失败（网络？可加 --ff-url <直链>）"
  VERSION="$(basename "$URL")"; VERSION="${VERSION#firefox-}"; VERSION="${VERSION%.tar.xz}"
  note "版本 $VERSION"
  note "地址 $URL"

  mkdir -p "$DIR/download"
  TARBALL="$DIR/download/firefox-$VERSION.tar.xz"
  if [[ -s "$TARBALL" ]] && tar -tf "$TARBALL" >/dev/null 2>&1; then
    ok "压缩包已存在，跳过下载"
  else
    rm -f "$TARBALL.part"
    note "下载中（约 90MB）…"
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o "$TARBALL.part" "$URL"; then
      rm -f "$TARBALL.part"
      curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$TARBALL.part" "$URL" ||
        die "下载失败，可用 --ff-url 指定镜像直链"
    fi
    mv "$TARBALL.part" "$TARBALL"
    ok "下载完成（$(du -h "$TARBALL" | cut -f1)）"
  fi

  verify_tarball "$URL" "$TARBALL"

  rm -rf "$DIR/firefox"
  tar -xf "$TARBALL" -C "$DIR" || die "解压失败（tar 支持 xz 吗？）"
  chmod +x "$DIR/firefox/firefox" "$DIR/firefox/firefox-bin" 2>/dev/null || true
  ok "解压到 $DIR/firefox"
fi

# ---------------------------------------------------------------- 3. 补 .so
step "检查运行时依赖"

libdirs() { find "$DIR/libs" -name '*.so*' -printf '%h\n' 2>/dev/null | sort -u | paste -sd: - || true; }
missing_so() {
  local lp; lp="$(libdirs)"
  # 只查 firefox-bin：它带 RPATH=$ORIGIN，能正确解析自带的 libmoz*/NSS。
  # 直接 ldd libxul.so 会把这些自带库全报成 missing（假阳性）。
  LD_LIBRARY_PATH="${lp}${lp:+:}${LD_LIBRARY_PATH:-}" ldd "$DIR/firefox/firefox-bin" 2>/dev/null |
    awk '/not found/{print $1}' | sort -u
}

# soname → Debian/Ubuntu 包名（只列 Firefox 常见的，缺什么补什么）
declare -A PKG=(
  [libdbus-glib-1.so.2]=libdbus-glib-1-2  [libasound.so.2]=libasound2
  [libstartup-notification-1.so.0]=libstartup-notification0
  [libgtk-3.so.0]=libgtk-3-0              [libXcomposite.so.1]=libxcomposite1
  [libXdamage.so.1]=libxdamage1           [libXrandr.so.2]=libxrandr2
  [libgbm.so.1]=libgbm1                   [libxkbcommon.so.0]=libxkbcommon0
  [libatk-1.0.so.0]=libatk1.0-0           [libatk-bridge-2.0.so.0]=libatk-bridge2.0-0
  [libcups.so.2]=libcups2                 [libpango-1.0.so.0]=libpango-1.0-0
  [libdrm.so.2]=libdrm2                   [libXt.so.6]=libxt6
  [libdbus-1.so.3]=libdbus-1-3            [libxcb.so.1]=libxcb1
  [libX11-xcb.so.1]=libx11-xcb1           [libnss3.so]=libnss3
  [libnspr4.so]=libnspr4                  [libpulse.so.0]=libpulse0
  [libwayland-client.so.0]=libwayland-client0
)

mapfile -t MISSING < <(missing_so)
if (( ${#MISSING[@]} == 0 )); then
  ok "依赖齐全"
else
  note "缺 ${#MISSING[@]} 个：${MISSING[*]}"
  (( HAVE_APT )) || die "没有 apt-get，装不了。请手动安装提供这些 .so 的包后重跑"
  mkdir -p "$DIR/libs/debs" "$DIR/libs/root"
  for so in "${MISSING[@]}"; do
    pkg="${PKG[$so]:-}"
    if [[ -z "$pkg" ]]; then
      warn "$so 没有预置包名映射，跳过（可用 apt-file search $so 查）"
      continue
    fi
    if ( cd "$DIR/libs/debs" && apt-get download "$pkg" >/dev/null 2>&1 ); then
      for d in "$DIR/libs/debs/${pkg}"_*.deb; do
        [[ -f "$d" ]] && dpkg -x "$d" "$DIR/libs/root"
      done
      ok "补上 $so ← $pkg"
    else
      warn "下载 $pkg 失败（apt 索引？）"
    fi
  done
  mapfile -t STILL < <(missing_so)
  if (( ${#STILL[@]} )); then
    warn "仍缺：${STILL[*]}"
    note "把对应的包装好（或解包到 $DIR/libs/root 下）后重跑本脚本"
  else
    ok "依赖已补齐（放在 $DIR/libs，不污染系统）"
  fi
fi

"$FFBIN" --version 2>/dev/null | tail -1 || warn "firefox --version 跑不通，后面自检会说明原因"

# ---------------------------------------------------------------- 4. 配置
step "写入配置"

mkdir -p "$DIR/etc" "$DIR/bin" "$DIR/profiles"

# 4.1 profile 硬化模板（沙箱开关按本机情况决定）
TMPL="$DIR/etc/user.js.tmpl"
cat > "$TMPL" <<'TMPL_EOF'
// ============================================================
// gacc profile 硬化模板 —— 由 bin/gacc 每次启动时渲染成 user.js
// 改这里，不要改 profiles/*/user.js（会被覆盖）
// 占位符：@PROXY@ @PERSONA@ @SANDBOX@ 由 gacc 生成
// ============================================================

// ---------- 代理（每个 profile 独立，Firefox 原生支持） ----------
@PROXY@

// ---------- 指纹人设（每账户不同，见 gacc <n> --fp） ----------
@PERSONA@

// ---------- 沙箱（仅在环境不支持时才会写入） ----------
@SANDBOX@

// ---------- WebRTC / DNS 泄漏防护 ----------
user_pref("media.peerconnection.ice.proxy_only", true);
user_pref("media.peerconnection.enabled", false);        // 要用 Google Meet 就改 true
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.prefetch-next", false);
user_pref("network.predictor.enabled", false);
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("browser.search.suggest.enabled", false);

// ---------- 关掉 Firefox 自己的遥测 / 实验 / 账号同步 ----------
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.server", "data:,");
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("app.normandy.enabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.discovery.enabled", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);
user_pref("identity.fxaccounts.enabled", false);              // 无 Mozilla 账号 / 云同步
user_pref("extensions.pocket.enabled", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);

// ---------- 启动行为：恢复上次会话，每个账户的标签页自动回来 ----------
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutConfig.showWarning", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
TMPL_EOF
ok "etc/user.js.tmpl"

# 4.2 企业策略：强装 Multi-Account Containers + 关遥测
# 故意不生成 policies.json：企业策略会让 Firefox 在搜索 URL 里带 channel=entpr，
# 等于向对方宣告"这是个受管控的浏览器"。关遥测 / 锁更新全部用 user.js 实现。
mkdir -p "$DIR/firefox/distribution"
rm -f "$DIR/firefox/distribution/policies.json"
ok "不使用企业策略（避免 channel=entpr 标记）"

# 4.3 启动器
cat > "$DIR/bin/gacc" <<'GACC'
#!/usr/bin/env bash
# ============================================================
# gacc —— 每个 Google 账户一个独立 Firefox profile + 独立指纹人设
#
#   ./bin/gacc 1                     启动账户 1
#   ./bin/gacc 2 --proxy socks5://127.0.0.1:1082
#   ./bin/gacc 3 --direct            不走代理
#   ./bin/gacc list                  所有账户 + 代理 + 人设
#   ./bin/gacc 1 --fp                看账户 1 的指纹人设
#   ./bin/gacc 1 --new-fp            重掷一套人设（下次启动生效）
#   ./bin/gacc 1 --doctor            体检
#   ./bin/gacc 1 --stop              关掉
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 默认用随包的便携版；设 GACC_FIREFOX 可以指向任意 Firefox（apt / snap / 自编译）
FF="${GACC_FIREFOX:-$ROOT/firefox/firefox}"
# 系统装了那几个 .so 就不用管；没装时找 libs/ 下的本地补丁（目录名随发行版变，故全量收集）
LIBDIRS="$(find "$ROOT/libs" -name '*.so*' -printf '%h\n' 2>/dev/null | sort -u | paste -sd: - || true)"
PROFROOT="$ROOT/profiles"
TMPL="$ROOT/etc/user.js.tmpl"

die() { echo "gacc: $*" >&2; exit 1; }

[[ -x "$FF" ]] || die "找不到 $FF（Firefox 没解压？）"
[[ -f "$TMPL" ]] || die "找不到模板 $TMPL"

prof_of()     { printf '%s/acc%02d' "$PROFROOT" "$1"; }
proxyfile_of(){ printf '%s/proxy.conf'  "$(prof_of "$1")"; }
persona_of()  { printf '%s/persona.conf' "$(prof_of "$1")"; }

# 精确匹配某个 profile 的进程：路径后面必须紧跟空格或行尾，
# 否则 acc01 会命中 acc010（10 号账户）的进程，--stop 就会杀错人。
# 用 ps + 字面匹配而不是 pgrep 的正则：路径里含空格、括号、加号时，
# 正则会把它们当元字符；而且 acc01 会命中 acc010。case 是纯字面比较，没有这些问题。
pids_of_profile() {
  local pid cmd
  while read -r pid cmd; do
    case "$cmd" in
      *"--profile $1 "*|*"--profile $1") printf '%s\n' "$pid" ;;
    esac
  done < <(ps -eo pid=,args= 2>/dev/null)
}

# ---------------------------------------------------------------- 指纹人设
# 格式：时区|核心数|DPR —— 取值刻意落在主流办公机的常见区间，
# 不用 16 核 / DPR 2 这种稀有组合：稀有组合会把「匿名集」缩小，反而更好被认出来。
# 语言固定 en-US / 美西时区（按用户要求）。
PERSONAS=(
  'America/Los_Angeles|8|1'
  'America/Los_Angeles|4|1'
  'America/Los_Angeles|8|1.25'
  'America/Los_Angeles|12|1'
  'America/Phoenix|4|1'
  'America/Phoenix|8|1.25'
  'America/Denver|8|1'
  'America/Anchorage|4|1'
  'Pacific/Honolulu|4|1'
  'America/Los_Angeles|12|1.25'
)
P_LOCALE="en-US"
P_ACCEPT="en-US,en;q=0.9"

gen_persona() {  # $1=acc → 写 persona.conf
  local acc="$1" f used tz cores dpr line
  f="$(persona_of "$acc")"
  mkdir -p "$(dirname "$f")"
  # 尽量不和已有账户撞时区，也不撞 (核心数,DPR) 组合
  used="$(cat "$PROFROOT"/*/persona.conf 2>/dev/null | awk -F= '/^tz=/{print $2}' || true)"
  usedhw="$(cat "$PROFROOT"/*/persona.conf 2>/dev/null | awk -F= '/^(cores|dpr)=/{v=v$2"/"} END{print v}' || true)"
  local -a candidates=() strict=()
  for line in "${PERSONAS[@]}"; do
    tz="${line%%|*}"
    grep -qx -- "$tz" <<<"$used" && continue
    candidates+=("$line")
    IFS='|' read -r _ c d <<<"$line"
    grep -q -- "$c/$d/" <<<"$usedhw" || strict+=("$line")
  done
  (( ${#strict[@]} )) && candidates=("${strict[@]}")
  (( ${#candidates[@]} )) || candidates=("${PERSONAS[@]}")
  local pick
  if command -v shuf >/dev/null 2>&1; then
    pick="$(printf '%s\n' "${candidates[@]}" | shuf -n1)"
  else
    pick="${candidates[RANDOM % ${#candidates[@]}]}"
  fi
  IFS='|' read -r tz cores dpr <<<"$pick"
  cat > "$f" <<EOF
locale=$P_LOCALE
accept=$P_ACCEPT
tz=$tz
cores=$cores
dpr=$dpr
EOF
}

# 键值对解析，不 source：persona.conf 是用户可编辑文件，
# source 会让文件里任意一行变成「能改 ROOT/FF 的代码」。
load_persona() {  # $1=acc → 设置 P_TZ / P_CORES / P_DPR
  local f k v depth="${2:-0}"
  (( depth < 3 )) || { echo "gacc: persona.conf 生成失败（$1）" >&2; exit 1; }
  f="$(persona_of "$1")"
  [[ -f "$f" ]] || gen_persona "$1"
  local ACC_RE='^[A-Za-z0-9,;=.q-]+$'
  P_LOCALE="en-US"; P_ACCEPT="en-US,en;q=0.9"; P_TZ=""; P_CORES="8"; P_DPR="1"
  while IFS='=' read -r k v; do
    case "$k" in
      locale) [[ "$v" =~ ^[A-Za-z-]+$ ]] && P_LOCALE="$v" ;;
      accept) [[ "$v" =~ $ACC_RE ]] && P_ACCEPT="$v" ;;
      tz)     [[ "$v" =~ ^[A-Za-z0-9/_+-]+$ ]] && P_TZ="$v" ;;
      cores)  [[ "$v" =~ ^[0-9]+$ ]] && P_CORES="$v" ;;
      dpr)    [[ "$v" =~ ^[0-9.]+$ ]] && P_DPR="$v" ;;
    esac
  done < "$f"
  [[ -n "$P_TZ" ]] || { gen_persona "$1" || die "写不了 $(persona_of "$1")"; load_persona "$1" $((depth+1)); return; }
}

render_persona_block() {  # $1=acc
  load_persona "$1"
  cat <<EOF
user_pref("intl.accept_languages", "$P_ACCEPT");
user_pref("dom.maxHardwareConcurrency", $P_CORES);
user_pref("layout.css.devPixelsPerPx", "$P_DPR");
user_pref("privacy.resistFingerprinting", false);   // RFP 会把所有账户抹成同一组值，反而利于关联
// 不要关 media.navigator.enabled：开着才正常；设备列表本身不含硬件指纹
user_pref("javascript.use_us_english_locale", true);
EOF
}

# ---------------------------------------------------------------- 代理
# 不使用企业策略：policies.json 会让 Firefox 在 Google 搜索 URL 里注入
# channel=entpr（等于主动告知对方「这是受管控的浏览器」）。遥测/更新锁等全部改用 user.js。
# 老版本装出来的 policies.json 在这里顺手清掉。
ensure_no_policies() {
  rm -f "$ROOT/firefox/distribution/policies.json" 2>/dev/null || true
}

write_proxy() {  # $1=account $2=spec
  local acc="$1" spec="$2" p
  p="$(proxyfile_of "$acc")"
  mkdir -p "$(dirname "$p")"
  if [[ "$spec" == "direct" || "$spec" == "none" || "$spec" == "off" ]]; then
    printf 'direct\n' > "$p"; return
  fi
  [[ "$spec" == *"://"* ]] || spec="socks5://$spec"
  local scheme="${spec%%://*}" rest="${spec#*://}"
  local host="${rest%:*}" port="${rest##*:}"
  [[ "$rest" == *:* ]] || die "代理要带端口，例如 socks5://127.0.0.1:1081"
  [[ "$port" =~ ^[0-9]+$ ]] || die "端口不是数字：$port"
  case "$scheme" in
    socks5|socks5h) scheme=socks5 ;;
    socks4|socks)   scheme=socks4 ;;
    http|https)     ;;
    *) die "只支持 socks5:// socks4:// http:// https:// 或 direct" ;;
  esac
  printf '%s://%s:%s\n' "$scheme" "$host" "$port" > "$p"
}

render_proxy_block() {  # $1=account
  local acc="$1" p spec scheme host port
  p="$(proxyfile_of "$acc")"
  spec="$(cat "$p" 2>/dev/null || echo direct)"
  if [[ "$spec" == "direct" || -z "$spec" ]]; then
    printf 'user_pref("network.proxy.type", 0);   // 直连\n'
    return
  fi
  scheme="${spec%%://*}"; local rest="${spec#*://}"
  host="${rest%:*}"; port="${rest##*:}"
  case "$scheme" in
    socks5)
      cat <<EOF
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "$host");
user_pref("network.proxy.socks_port", $port);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);   // DNS 走代理，防泄漏
user_pref("network.proxy.share_proxy_settings", true);
user_pref("network.proxy.no_proxies_on", "");
EOF
      ;;
    socks4)
      cat <<EOF
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "$host");
user_pref("network.proxy.socks_port", $port);
user_pref("network.proxy.socks_version", 4);
user_pref("network.proxy.socks_remote_dns", false);
user_pref("network.proxy.share_proxy_settings", true);
user_pref("network.proxy.no_proxies_on", "");
EOF
      ;;
    http|https)
      cat <<EOF
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "$host");
user_pref("network.proxy.http_port", $port);
user_pref("network.proxy.ssl", "$host");
user_pref("network.proxy.ssl_port", $port);
user_pref("network.proxy.share_proxy_settings", true);
user_pref("network.proxy.no_proxies_on", "");
user_pref("network.proxy.socks_remote_dns", true);
EOF
      ;;
  esac
}

prepare_profile() {  # $1=account
  local acc="$1" prof proxy_blk persona_blk sandbox_blk=""
  prof="$(prof_of "$acc")"
  mkdir -p "$prof"
  [[ -f "$(proxyfile_of "$acc")" ]] || printf 'direct\n' > "$(proxyfile_of "$acc")"
  proxy_blk="$(render_proxy_block "$acc")"
  persona_blk="$(render_persona_block "$acc")"

  # 本环境能不能跑 Firefox 的内容沙箱（写 /proc/self/uid_map 被拒 → 起不来）
  if ! unshare --user --map-root-user true >/dev/null 2>&1; then
    sandbox_blk=$'user_pref("security.sandbox.content.level", 0);\nuser_pref("security.sandbox.gpu.level", 0);'
  elif [[ -f "$prof/prefs.js" ]]; then
    # 环境恢复了：只删我们自己写进去的那两行，不动用户在 about:config 里设的其它 sandbox 值
    sed -i \
      -e '/^user_pref("security\.sandbox\.content\.level", 0);$/d' \
      -e '/^user_pref("security\.sandbox\.gpu\.level", 0);$/d' \
      "$prof/prefs.js" 2>/dev/null || true
  fi

  # 原子写：先写临时文件再 mv，避免中途打断留下半个 user.js
  awk -v pb="$proxy_blk" -v fb="$persona_blk" -v sb="$sandbox_blk" '
    /^@PROXY@$/   { print pb; next }
    /^@PERSONA@$/ { print fb; next }
    /^@SANDBOX@$/ { if (sb != "") print sb; next }
    { print }
  ' "$TMPL" > "$prof/user.js.tmp"
  mv "$prof/user.js.tmp" "$prof/user.js"
  printf '%s\n' "$prof"
}

cmd_list() {
  printf '%-5s %-26s %-7s %-20s %s\n' 账户 代理 核心 时区 语言
  local d acc p c t l
  for d in "$PROFROOT"/acc*; do
    [[ -d "$d" ]] || continue
    acc="${d##*/acc}"
    p="$(cat "$d/proxy.conf" 2>/dev/null || echo direct)"
    c="$(awk -F= '/^cores=/{print $2}'  "$d/persona.conf" 2>/dev/null || true)"
    t="$(awk -F= '/^tz=/{print $2}'     "$d/persona.conf" 2>/dev/null || true)"
    l="$(awk -F= '/^locale=/{print $2}' "$d/persona.conf" 2>/dev/null || true)"
    if [[ -z "$c" ]]; then
      printf '%-5s %-26s %-7s %-20s %s\n' "$acc" "$p" - 未初始化 -
    else
      printf '%-5s %-26s %-7s %-20s %s\n' "$acc" "$p" "$c" "$t" "$l"
    fi
  done
}

cmd_fp() {  # $1=account
  load_persona "$1"
  echo "账户 $1 的指纹人设"
  echo "  时区 (TZ)           : $P_TZ"
  echo "  Accept-Language     : $P_ACCEPT"
  echo "  hardwareConcurrency : $P_CORES"
  echo "  devicePixelRatio    : $P_DPR"
  echo
  if [[ -f "$(prof_of "$1")/fonts.conf" ]]; then
    local nf
    nf="$(ls "$(prof_of "$1")/fonts" 2>/dev/null | wc -l)"
    echo "  字体子集            : 已启用（$nf 个字体文件可见，系统共 $(fc-list 2>/dev/null | wc -l) 个）"
  else
    echo "  字体子集            : 未启用（看到系统全部字体）→ ./bin/gacc $1 --fonts"
  fi
  echo
  echo "  跨账户仍然相同的部分：Canvas / WebGL / GPU 字符串 / TLS 与 HTTP2 指纹"
}

cmd_doctor() {  # $1=account
  local acc="$1" prof spec rest host port
  prof="$(prof_of "$acc")"; spec="$(cat "$(proxyfile_of "$acc")" 2>/dev/null || echo direct)"
  echo "账户 $acc"
  echo "  Firefox : $FF"
  echo "  profile : $prof"
  echo "  代理    : $spec"
  if [[ "$spec" != "direct" ]]; then
    rest="${spec#*://}"; host="${rest%:*}"; port="${rest##*:}"
    printf '  连通性  : '
    curl -sS -m 8 -o /dev/null -w "HTTP %{http_code} (%{time_total}s)\n" \
         --proxy "$spec" https://www.gstatic.com/generate_204 2>&1 || true
  fi
  load_persona "$acc"
  printf '  人设    : TZ=%s  语言=%s  核心=%s  DPR=%s\n' "$P_TZ" "$P_ACCEPT" "$P_CORES" "$P_DPR"
  printf '  沙箱    : '
  if unshare --user --map-root-user true >/dev/null 2>&1; then
    echo "可开（正常，无黄条）"
  else
    echo "本环境不可用 → 自动关闭（地址栏下会出现黄条，无法消除）"
  fi
  printf '  已登录? : '
  if [[ -f "$prof/cookies.sqlite" ]]; then echo "有 cookies.sqlite（$(du -h "$prof/cookies.sqlite" | cut -f1)）"; else echo "全新 profile"; fi
}

# ---------------- main ----------------
[[ $# -ge 1 ]] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

case "$1" in
  list) cmd_list; exit 0 ;;
  fp) [[ $# -ge 2 ]] || die "用法：gacc fp <账户号>"; cmd_fp "$2"; exit 0 ;;
  -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

[[ "$1" =~ ^[0-9]+$ ]] || die "第一个参数要是账户编号，比如 1 / 2 / 3"
ACC="$1"; shift

URLS=(); DOCTOR=0; NEWFP=0; SHOWFP=0; FONTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy) [[ $# -ge 2 ]] || die "--proxy 后面要跟地址"; write_proxy "$ACC" "$2"; shift 2 ;;
    --proxy=*) write_proxy "$ACC" "${1#*=}"; shift ;;
    --direct) write_proxy "$ACC" direct; shift ;;
    --doctor) DOCTOR=1; shift ;;
    --fp) SHOWFP=1; shift ;;
    --new-fp) NEWFP=1; shift ;;
    --fonts) FONTS=1; shift ;;
    --no-fonts) FONTS=0; shift ;;
    --stop)
      pids="$(pids_of_profile "$(prof_of "$ACC")")"
      if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null || true
        echo "已停止账户 $ACC (pid: $(echo $pids | tr '\n' ' '))"
      else
        echo "账户 $ACC 没在跑"
      fi
      exit 0 ;;
    *) URLS+=("$1"); shift ;;
  esac
done

if (( NEWFP )); then
  rm -f "$(persona_of "$ACC")"
  gen_persona "$ACC"
  echo "账户 $ACC 已重掷人设："; cmd_fp "$ACC"
  exit 0
fi

PROF_EARLY="$(prof_of "$ACC")"
if [[ "$FONTS" == "1" ]]; then
  if "$ROOT/bin/gen-fonts.sh" "$ACC" >/dev/null; then
    echo "✔ 已生成账户 $ACC 的字体子集"
  else
    echo "! 字体子集生成失败，本账户继续用系统全部字体（不影响启动）" >&2
  fi
elif [[ "$FONTS" == "0" ]]; then
  rm -f "$PROF_EARLY/fonts.conf"; echo "✔ 已移除账户 $ACC 的字体子集（回到系统全部字体）"
fi

prepare_profile "$ACC" >/dev/null
ensure_no_policies

if (( SHOWFP )); then cmd_fp "$ACC"; exit 0; fi
if (( DOCTOR )); then cmd_doctor "$ACC"; exit 0; fi

PROF="$(prof_of "$ACC")"

# 同一个 profile 只能有一个 Firefox 实例，否则会弹 "already running" 并且抢锁
EXIST="$(pids_of_profile "$PROF" | head -1)"
if [[ -n "$EXIST" ]]; then
  if (( ${#URLS[@]} == 0 )); then
    echo "✔ 账户 $ACC 已经在运行 (pid $EXIST)，不重复启动"
    echo "  profile : $PROF"
    echo "  代理    : $(cat "$PROF/proxy.conf")"
    echo "  （要改用别的代理：先 ./bin/gacc $ACC --stop）"
    exit 0
  fi
  # 旧版 gacc 起的实例带 --no-remote，它根本收不到转发的 URL。
  # 这种情况下直接启动会撞 profile 锁（弹 "already running"），所以先告诉用户。
  case "$(ps -o args= -p "$EXIST" 2>/dev/null || true)" in
    *--no-remote*)
      echo "! 账户 $ACC 正在运行的实例是旧模式（带 --no-remote），收不到转发的 URL。" >&2
      echo "  先 ./bin/gacc $ACC --stop 再 ./bin/gacc $ACC，之后就正常了。" >&2
      exit 2 ;;
  esac
  # 实测：Firefox 不会把 URL 交给已运行的实例（--class / -P / 有无 dbus 全试过，
  # 第二次启动只会留下一个 "already running" 对话框并抢 profile 锁）。
  # 所以这里绝不再启动第二个实例，退化为「把 URL 交到用户手上」。
  url="${URLS[0]}"
  clip=0
  if command -v xclip >/dev/null 2>&1 && printf '%s' "$url" | xclip -selection clipboard 2>/dev/null; then clip=1
  elif command -v xsel >/dev/null 2>&1 && printf '%s' "$url" | xsel --clipboard --input 2>/dev/null; then clip=1
  elif command -v wl-copy >/dev/null 2>&1 && printf '%s' "$url" | wl-copy 2>/dev/null; then clip=1
  fi
  echo "! 账户 $ACC 已经在运行，无法把 URL 注入这个实例（Firefox 限制）。" >&2
  if (( clip )); then
    echo "  ✔ URL 已复制到剪贴板 → 切到该窗口 Ctrl+T 再粘贴回车即可。" >&2
  else
    echo "  URL: $url" >&2
    echo "  （装上 xclip 就会自动复制：sudo apt install xclip）" >&2
  fi
  echo "  或者：./bin/gacc $ACC --stop 之后再点一次，它会直接带着 URL 启动。" >&2
  exit 0
fi

[[ -n "$LIBDIRS" ]] && export LD_LIBRARY_PATH="$LIBDIRS${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export MOZ_CRASHREPORTER_DISABLE=1
export MOZ_DISABLE_AUTO_SAFE_MODE=1
export GSETTINGS_BACKEND=memory
unset MOZ_ENABLE_WAYLAND
grep -qE '^[[:space:]]*user_pref\("security\.sandbox\.content\.level",[[:space:]]*0\)' "$PROF/user.js" 2>/dev/null \
  && export MOZ_DISABLE_CONTENT_SANDBOX=1

# 每个账户独立的 HOME/缓存，互不污染
RUNTIME="$ROOT/runtime/$(printf 'acc%02d' "$ACC")"
export HOME="$RUNTIME/home" XDG_CONFIG_HOME="$RUNTIME/config" \
       XDG_CACHE_HOME="$RUNTIME/cache" XDG_DATA_HOME="$RUNTIME/data" \
       XDG_RUNTIME_DIR="$RUNTIME/run"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

# 指纹的核心：时区（已验证 Firefox 的 Intl 跟随 TZ）
load_persona "$ACC"
[[ -n "$P_TZ" ]] && export TZ="$P_TZ"

# 字体子集：只让这个账户看见 fonts.conf 里列出的字体（需绝对路径）
if [[ -f "$PROF/fonts.conf" ]]; then
  export FONTCONFIG_FILE="$PROF/fonts.conf"
fi

# 不用 -width/-height：它会和 browser.startup.page=3 的会话恢复打架
# （恢复的窗口用 xulstore.json 里的旧尺寸，参数要么被忽略要么多开一个窗口）。
# 窗口尺寸本来也会被用户拖动改变，不作为指纹维度。

# 不能加 --no-remote：它会关掉「把 URL 交给同 profile 已运行实例」的能力，
# 于是 xdg-open / 桌面快捷方式 / OAuth 登录弹窗全部会静默失败。
# 不同 profile 之间不会互相接管（实测两个账户可并存），所以不需要它。
# setsid --fork：双重脱离（新 session + 挂到 init 下），关终端也不带走浏览器
setsid --fork nohup "$FF" --profile "$PROF" \
      --class "gacc-$ACC" "${URLS[@]}" </dev/null >>"$PROF/firefox.log" 2>&1 &

PID=""
for _ in $(seq 1 30); do
  PID="$(pids_of_profile "$PROF" | head -1)"
  [[ -n "$PID" ]] && break
  sleep 0.3
done
sleep 2

if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
  echo "✔ 账户 $ACC 已启动 (pid $PID)"
  echo "  profile : $PROF"
  echo "  代理    : $(cat "$PROF/proxy.conf")"
  echo "  人设    : TZ=$P_TZ  语言=${P_ACCEPT%%,*}  核心=$P_CORES  DPR=$P_DPR"
  echo "  日志    : $PROF/firefox.log"
  echo "  停止    : $ROOT/bin/gacc $ACC --stop"
else
  echo "✘ 账户 $ACC 启动失败，最后 15 行日志：" >&2
  grep -viE 'dconf-CRITICAL|org.a11y' "$PROF/firefox.log" 2>/dev/null | tail -15 >&2
  exit 1
fi
GACC
chmod +x "$DIR/bin/gacc"
ok "bin/gacc"

# 其余脚本也要一起装过去，否则 --fonts / 快捷方式 / Antigravity 槽位都用不了
for f in gen-fonts.sh install-shortcuts.sh agsw install-antigravity.sh; do
  if [[ -f "$SCRIPT_DIR/bin/$f" ]]; then
    cp "$SCRIPT_DIR/bin/$f" "$DIR/bin/$f"
    chmod +x "$DIR/bin/$f"
    ok "bin/$f"
  fi
done

# ---------------------------------------------------------------- 5. 账户
step "创建 $ACCOUNTS 个账户"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

declare -a ASSIGNED=()
for i in $(seq 1 "$ACCOUNTS"); do
  pdir="$DIR/profiles/$(printf 'acc%02d' "$i")"
  mkdir -p "$pdir"
  port=$(( BASE_PORT + i - 1 ))
  case "$PROXY_MODE" in
    direct) spec="direct" ;;
    socks5) spec="socks5://127.0.0.1:$port" ;;
    http)   spec="http://127.0.0.1:$port" ;;
    auto)
      if port_open "$port"; then spec="socks5://127.0.0.1:$port"
      else spec="direct"; fi
      ;;
  esac
  printf '%s\n' "$spec" > "$pdir/proxy.conf"
  ASSIGNED+=("$(printf 'acc%02d' "$i")  $spec")
  printf '    %s  →  %s\n' "$(printf 'acc%02d' "$i")" "$spec"
done

if [[ "$PROXY_MODE" == "auto" ]]; then
  note "auto 模式：端口上有服务就绑 socks5，没有就先直连（能用最重要）"
  note "等你的代理起来了，逐条改：./bin/gacc 1 --proxy socks5://127.0.0.1:1081"
fi

# ---------------------------------------------------------------- 6. 自检
if (( ! SKIP_SMOKE )) && [[ -n "${DISPLAY:-}" ]]; then
  step "渲染自检"
  SMOKE="$DIR/.smoke"; rm -rf "$SMOKE"; mkdir -p "$SMOKE" \
    "$DIR/runtime/home" "$DIR/runtime/cache" "$DIR/runtime/data" "$DIR/runtime/config"
  # 注意两点：Firefox 不会自己创建 --profile 目录；$HOME 不可写时会误报 "Could not find profile folder"
  if HOME="$DIR/runtime/home" XDG_CACHE_HOME="$DIR/runtime/cache" \
       XDG_DATA_HOME="$DIR/runtime/data" XDG_CONFIG_HOME="$DIR/runtime/config" \
       GSETTINGS_BACKEND=memory MOZ_DISABLE_CONTENT_SANDBOX=1 \
       timeout 90 "$FFBIN" --headless --profile "$SMOKE" --no-remote --window-size=800,600 \
       --screenshot "$SMOKE.png" https://example.com >"$SMOKE.log" 2>&1 &&
     [[ -s "$SMOKE.png" ]]; then
    ok "能渲染网页（截图 $(du -h "$SMOKE.png" | cut -f1)）"
  else
    warn "渲染自检没通过，最后几行日志："
    grep -viE 'dconf-CRITICAL|org.a11y' "$SMOKE.log" 2>/dev/null | tail -8 | sed 's/^/      /'
    warn "不影响脚本继续；先试试 ./bin/gacc 1，打不开就把上面日志发我"
  fi
  rm -rf "$SMOKE" "$SMOKE.png" "$SMOKE.log"
fi

# ---------------------------------------------------------------- 7. 收尾
cat > "$DIR/QUICKSTART.md" <<'Q'
# 怎么用

```bash
cd "$(dirname "$0")"      # 本文件所在目录
./bin/gacc 1              # 启动账户 1
./bin/gacc 2 --proxy socks5://127.0.0.1:1082   # 换个代理
./bin/gacc 1 --doctor     # 体检
./bin/gacc list           # 看所有账户
./bin/gacc 1 --stop       # 关掉
```

- 一个账户 = 一个 profile = 独立 cookie/存储/缓存/代理，物理隔离在 `profiles/accNN/`。
- 加账户：`./bin/gacc 7 --proxy socks5://127.0.0.1:1087`，自动建。
- 通用配置（WebRTC、遥测、DNS）改 `etc/user.js.tmpl`，下次启动生效。
  要开 Google Meet：把 `media.peerconnection.enabled` 改成 `true`。
- Multi-Account Containers 会从 AMO 自动装上，预置了 G1–G4 四个容器身份；
  它适合「一个窗口多账户」，但**共用当前 profile 的代理**。
- 数据全在本地，无云同步。备份：关掉浏览器后 `tar czf backup.tgz profiles/`。

## WSL2 特有的坑（脚本已处理）

1. WSL2 禁用 user namespace → Firefox 内容沙箱会崩。模板里已写死关掉。
   **代价：网页失去进程沙箱**；在原生桌面上一键部署会自动保持沙箱开启。
2. `$HOME` 不可写 → Firefox 静默卡死。已把 HOME/XDG 重定向到 `runtime/`。
3. `nohup &` 起的 GUI 会被回收 → 已用 `setsid --fork` 脱离。
4. **WSL 的 127.0.0.1 不是 Windows 的 127.0.0.1**（NAT）。Windows 上的代理要用
   网关 IP（`ip route | awk '/default/{print $3}'`），或在 `.wslconfig` 里开
   `networkingMode=mirrored`。
Q
sed -i "s|\$(dirname \"\$0\")|$DIR|" "$DIR/QUICKSTART.md"

printf '\n%s部署完成%s\n' "$c_ok" "$c_off"
printf '  目录   %s\n' "$DIR"
printf '  账户   %s\n' "$(printf 'acc%02d ' $(seq 1 "$ACCOUNTS"))"
if command -v xclip >/dev/null 2>&1; then
  printf '  剪贴板  xclip 已装（实例已在跑时，链接会自动进剪贴板）\n'
else
  printf '  剪贴板  未装 xclip —— sudo apt install xclip 后，链接会自动进剪贴板\n'
fi
printf '  沙箱   %s\n' "$( ((USERNS)) && echo '本机可开 → 启动时保持开启' || echo '本机不可用 → 启动时自动关闭（会有黄条）' )"
if (( ! NO_SHORTCUTS )) && [[ -n "${DISPLAY:-}" ]]; then
  step "生成桌面 / 开始菜单入口"
  if "$DIR/bin/install-shortcuts.sh" --accounts "$ACCOUNTS" 2>&1 | sed 's/^/    /'; then
    :
  else
    warn "快捷方式没生成成功，稍后手动跑：$DIR/bin/install-shortcuts.sh --accounts \"$ACCOUNTS\""
  fi
fi

printf '\n  下一步：\n'
printf '    cd %s\n    ./bin/gacc 1\n\n' "$DIR"
