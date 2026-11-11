<#
.SYNOPSIS
  gacc.ps1 —— 一个 Google 账户 = 一个 Firefox profile + 一个独立代理（Windows 版）

.DESCRIPTION
  和 bin/gacc（WSL/Linux 版）同一套逻辑，改成直接驱动 Windows 上已装的 Firefox：
  不需要装任何东西，不需要关沙箱，代理就在本机 127.0.0.1 上，不经过 WSL 的 NAT。

.EXAMPLE
  .\gacc.ps1 -Account 1 -Proxy socks5://127.0.0.1:1081
  .\gacc.ps1 -Account 2 -Proxy http://127.0.0.1:1082
  .\gacc.ps1 -Account 3 -Direct
  .\gacc.ps1 -List
  .\gacc.ps1 -Account 1 -Stop
#>
[CmdletBinding()]
param(
  [int]$Account,
  [string]$Proxy,
  [switch]$Direct,
  [switch]$Stop,
  [switch]$List,
  [string]$Root    = "D:\google_profiles",
  [string]$Firefox = "C:\Program Files\Mozilla Firefox\firefox.exe"
)

$ErrorActionPreference = 'Stop'

function Get-Profile([int]$n) { Join-Path $Root ("acc{0:D2}" -f $n) }

function Convert-ProxySpec([string]$spec) {
  if ([string]::IsNullOrWhiteSpace($spec) -or $spec -in @('direct','none','off')) {
    return @{ Kind = 'direct' }
  }
  if ($spec -notmatch '://') { $spec = "socks5://$spec" }
  $u = [uri]$spec
  $scheme = $u.Scheme.ToLower()
  if ($scheme -notin @('socks5','socks4','http','https')) {
    throw "只支持 socks5:// socks4:// http:// https:// 或 direct"
  }
  return @{ Kind = $scheme; Host = $u.Host; Port = $u.Port }
}

function Get-ProxyBlock($p) {
  if ($p.Kind -eq 'direct') {
    return 'user_pref("network.proxy.type", 0);   // 直连'
  }
  if ($p.Kind -like 'socks*') {
    $ver = if ($p.Kind -eq 'socks4') { 4 } else { 5 }
    $rdns = if ($ver -eq 5) { 'true' } else { 'false' }
    return @"
user_pref("network.proxy.type", 1);
user_pref("network.proxy.socks", "$($p.Host)");
user_pref("network.proxy.socks_port", $($p.Port));
user_pref("network.proxy.socks_version", $ver);
user_pref("network.proxy.socks_remote_dns", $rdns);
user_pref("network.proxy.share_proxy_settings", true);
user_pref("network.proxy.no_proxies_on", "");
"@
  }
  return @"
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "$($p.Host)");
user_pref("network.proxy.http_port", $($p.Port));
user_pref("network.proxy.ssl", "$($p.Host)");
user_pref("network.proxy.ssl_port", $($p.Port));
user_pref("network.proxy.share_proxy_settings", true);
user_pref("network.proxy.no_proxies_on", "");
"@
}

function Write-UserJs([string]$prof, [string]$block) {
  $js = @"
// 由 gacc.ps1 生成，每次启动会覆盖。要改配置请改 gacc.ps1 里的模板。

// ---------- 代理（本 profile 专属，Firefox 原生支持） ----------
$block

// ---------- WebRTC / DNS 泄漏防护 ----------
user_pref("media.peerconnection.ice.proxy_only", true);
user_pref("media.peerconnection.enabled", false);        // 要开 Google Meet 就改 true
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.prefetch-next", false);
user_pref("network.predictor.enabled", false);
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("browser.search.suggest.enabled", false);

// ---------- 关遥测 / 实验 / Mozilla 账号同步 ----------
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.server", "data:,");
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("app.normandy.enabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("identity.fxaccounts.enabled", false);
user_pref("extensions.pocket.enabled", false);

// ---------- 启动行为：自动恢复该账户上次的标签页 ----------
user_pref("browser.startup.page", 3);
user_pref("browser.sessionstore.resume_from_crash", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
"@
  $enc = New-Object System.Text.UTF8Encoding($false)   # 不写 BOM，否则首行 prefs 解析失败
  [System.IO.File]::WriteAllText((Join-Path $prof 'user.js'), $js, $enc)
}

# ---------------- list ----------------
if ($List) {
  if (-not (Test-Path $Root)) { Write-Host "还没有账户（$Root 不存在）"; return }
  Get-ChildItem $Root -Directory -Filter 'acc*' | Sort-Object Name | ForEach-Object {
    $p = Join-Path $_.FullName 'proxy.conf'
    $spec = if (Test-Path $p) { (Get-Content $p -Raw).Trim() } else { 'direct' }
    '{0,-8} {1,-30} {2}' -f $_.Name, $spec, $_.FullName
  }
  return
}

if ($Account -lt 1) { throw "需要 -Account N（例如 -Account 1），或用 -List / -Stop" }
$prof = Get-Profile $Account

# ---------------- stop ----------------
if ($Stop) {
  $hits = Get-CimInstance Win32_Process -Filter "Name = 'firefox.exe'" |
          Where-Object { $_.CommandLine -and $_.CommandLine -like "*$prof*" }
  if (-not $hits) { Write-Host "账户 $Account 没在跑"; return }
  $hits | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Write-Host "已停止账户 $Account"
  return
}

# ---------------- start ----------------
if (-not (Test-Path $Firefox)) { throw "找不到 Firefox：$Firefox（用 -Firefox 指定路径）" }
New-Item -ItemType Directory -Force -Path $prof | Out-Null

$confPath = Join-Path $prof 'proxy.conf'
if ($Direct)          { 'direct' | Set-Content -Path $confPath -Encoding ASCII }
elseif ($Proxy)       { $Proxy   | Set-Content -Path $confPath -Encoding ASCII }
elseif (-not (Test-Path $confPath)) { 'direct' | Set-Content -Path $confPath -Encoding ASCII }

$spec  = (Get-Content $confPath -Raw).Trim()
$parsed = Convert-ProxySpec $spec
Write-UserJs $prof (Get-ProxyBlock $parsed)

# -no-remote + 独立 -profile：同一时间可以开任意多个账户
Start-Process -FilePath $Firefox -ArgumentList @('-no-remote', '-profile', "`"$prof`"") | Out-Null

Write-Host "✔ 账户 $Account 已启动"
Write-Host "  profile : $prof"
Write-Host "  代理    : $spec"
if ($parsed.Kind -ne 'direct') {
  $listen = Test-NetConnection -ComputerName 127.0.0.1 -Port $parsed.Port -WarningAction SilentlyContinue
  if (-not $listen.TcpTestSucceeded) {
    Write-Host "  ⚠ 127.0.0.1:$($parsed.Port) 没有服务在监听 —— 这个账户会打不开网页" -ForegroundColor Yellow
  } else {
    Write-Host "  ✔ 127.0.0.1:$($parsed.Port) 在监听" -ForegroundColor Green
  }
}
