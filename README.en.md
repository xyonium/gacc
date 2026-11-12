# gacc

**One account = one browser profile = one stable fingerprint.**

Keep multiple accounts on one machine (WSL2 / Linux) fully separated: cookies, storage,
cache and proxy per account, plus per-account timezone, language, CPU cores, device pixel
ratio and a curated font subset.

```
$ ./bin/gacc list
acct proxy                      cores tz                   locale
01   direct                     8     America/Denver       en-US
02   socks5://127.0.0.1:1082    8     America/Los_Angeles  en-US
03   direct                     4     America/Phoenix      en-US
```

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> 中文文档见 [README.md](README.md)

---

## Quick start

```bash
git clone https://github.com/xyonium/gacc && cd gacc

bash deploy-gacc.sh                  # installs into ./gacc-install, 3 accounts
cd gacc-install && ./bin/gacc 1      # launch account 1
```

`deploy-gacc.sh` downloads a portable Firefox, **verifies Mozilla's SHA256SUMS**, pulls
any missing shared libraries without root, writes the config, creates accounts and runs a
render smoke test. It never touches the Firefox already installed on your system.

**Requirements:** `bash 4+`, `curl`, `tar`, `awk`, `sed`, plus `dpkg` on Debian/Ubuntu
(used to unpack missing `.so` files — no root needed). WSL2 needs WSLg (`DISPLAY` set) to show windows; over plain SSH you can install but not
run it. Recommended: `sudo apt install xclip` so links land on the clipboard when the
account is already running (optional).

Already installed? Then just:

```bash
./bin/gacc 1                        # account number == directory number (acc01)
./bin/gacc 2 --proxy socks5://127.0.0.1:1082
./bin/gacc list
./bin/gacc 1 --fp                   # show this account's fingerprint profile
./bin/gacc 1 --doctor               # diagnostics
./bin/gacc 1 --stop
```

## What it does / does not do

| ✅ | How |
|---|---|
| Accounts cannot see each other | one profile directory + one process per account |
| Different egress per account | per-profile `proxy.conf` (Firefox supports proxy per profile natively) |
| Different fingerprint surface | timezone, Accept-Language, `hardwareConcurrency`, `devicePixelRatio`, visible font set |
| One-click launch | `./bin/gacc N`, or generated Start-Menu / desktop shortcuts |

| ❌ | Why |
|---|---|
| Hiding your IP | it only stores per-account proxy settings; the egress is yours |
| Changing Canvas / WebGL / GPU / TLS fingerprints | same binary, same machine — prefs can't move those |
| Making one machine look like different people | the other side also has non-browser signals: recovery phone, verified devices, login cadence |
| Faking hardware | it only differentiates *real* values, it does not spoof |

**In one line:** it keeps accounts from leaking into each other and lowers the consistency
of low-level signals. It is not an anonymity tool.

## Design notes

**Profiles, not Multi-Account Containers.** The official MAC extension has no per-container
proxy — `network.proxy.*` is browser-global, while containers share the process, prefs and
proxy. Profiles are independent in every respect. MAC is still installed (via enterprise
policy, with G1–G4 pre-seeded) purely as a convenience for "many accounts in one window".

**No `privacy.resistFingerprinting`.** RFP flattens *every* account onto the same values
(UTC, en-US, rounded window sizes). For "accounts should differ from each other" that is
counter-productive, and it would destroy the timezone setting. It is explicitly disabled.

**Mainstream persona values.** 4/8/12 cores and DPR 1/1.25 rather than 16 cores + DPR 2.
Rare combinations shrink the anonymity set and make you *more* recognisable —
looking ordinary beats looking unique.

**Personas are stable.** Generated once, persisted in `persona.conf`; `user.js` is re-rendered
from it on every launch. Only an explicit `--new-fp` re-rolls it. A fingerprint that changes
daily is itself an anomaly.

## Commands

| Command | Effect |
|---|---|
| `./bin/gacc <N>` | launch account N |
| `./bin/gacc <N> --proxy <url>` | set proxy and launch (`socks5://` `socks4://` `http://` `direct`) |
| `./bin/gacc <N> --direct` | back to direct |
| `./bin/gacc <N> --fp` / `--new-fp` | show / re-roll the fingerprint profile |
| `./bin/gacc <N> --fonts` / `--no-fonts` | enable / disable the font subset |
| `./bin/gacc <N> --doctor` / `--stop` | diagnostics / quit |
| `./bin/gacc list` | list accounts |
| `./bin/gen-fonts.sh <N> --show` | regenerate the font subset and print visible families |
| `./bin/install-shortcuts.sh --accounts "1 2 3" --with-fonts` | Start-Menu + desktop shortcuts |

## Font subset

```bash
./bin/gacc 3 --fonts
```

`FONTCONFIG_FILE` points at a per-account `fonts.conf`, so Fontconfig only scans that
directory:

- base fonts are always included (DejaVu trio + Noto CJK + emoji) so nothing renders as tofu;
- the rest is drawn from a whitelist of ordinary desktop fonts; the pool is split into four
  groups by index and each account takes 6–9 files from *its* group only;
- sets are compared by signature so two accounts never collide.

Measured: the same JS snippet reports `200 / 345.17 / 409.5` under the system config and
**collapses to 350** under a subset config — proof the browser really only sees the subset.
Four accounts differ pairwise by 6–11 families while keeping full CJK coverage.

Side effect: developer-only fonts (e.g. `MesloLGS Nerd Font`) are not visible to accounts
that use a subset.

### Adding an account: change one number

Nothing needs to be pre-initialised. The first `./bin/gacc N` (or the first click on a shortcut
where you edited the number) creates everything for that account:

```
profiles/accNN/  proxy.conf  persona.conf  user.js  containers.json
runtime/accNN/   home/ config/ cache/ data/ run/
```

Firefox then adds `prefs.js`, `cookies.sqlite`, `places.sqlite` itself. The font subset is
opt-in (`--fonts`); without it the account sees all system fonts.

So `./bin/gacc 4` on a non-existent account simply creates and launches it — same for a
shortcut whose `Exec=... gacc 1 %u` you changed to `gacc 4`.

### Route a third-party app's login popup into one account

Apps running inside WSL/Linux that call "the system browser" (e.g. Google Antigravity) can be
pinned to one account:

```bash
./bin/install-shortcuts.sh --accounts 1 --as-default 1
xdg-settings get default-web-browser    # should print gacc-acc01.desktop
```

Programs running on Windows are unaffected — they use the Windows default browser.
See [docs/antigravity.md](docs/antigravity.md) for the full walkthrough (including the
`bin/agsw` multi-slot manager).

## Sandbox and the yellow bar

Firefox's content sandbox writes to `/proc/self/uid_map`. Some environments (containers, or a
terminal running inside another file sandbox) deny that write; content processes then die with
SIGSEGV and every page is blank. `gacc` probes this on every launch:

- probe passes → sandbox stays on, **no yellow bar** (verified: all content processes alive, zero crashes);
- probe fails → sandbox is disabled, pages work but the address bar shows
  "The security sandbox is disabled".

That bar cannot be silenced: `security.sandbox.warn=false` has no effect, and content levels
1/2/3 all crash too. It concerns your *local* security only — the remote side cannot see it.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Blank window | content sandbox killed the processes | check `profiles/accNN/firefox.log` for `uid_map: EACCES` / `signal 11` |
| Browser exits after a few seconds, profile has 3–4 files | `$HOME` not writable | `gacc` already redirects `HOME`/`XDG_*` into `runtime/` |
| `already running` / lock contention | two instances on one profile | `./bin/gacc N --stop` |
| Browser dies with the terminal | process reaped with the session | already detached via `setsid --fork` |
| CJK renders as boxes | no CJK font | `sudo apt install fonts-noto-cjk` |
| `.lnk` does nothing | gacc path moved | re-run `install-shortcuts.sh` |
| PowerShell script: mojibake or parse error | PS 5.1 needs a UTF-8 BOM | shipped `gacc.ps1` already has one |

## Uninstall

```bash
for n in 1 2 3 4; do ./bin/gacc $n --stop; done      # quit all accounts first
rm -f ~/.local/share/applications/gacc-acc*.desktop   # Start-Menu entries
```

Delete the `Firefox account NN.lnk` files on your Windows desktop, then remove the install
directory. `profiles/` holds real login state — to drop a single account use
`rm -rf profiles/accNN`.

## Security

- `profiles/` holds real login state. `.gitignore` excludes `profiles/`, `runtime/`,
  `firefox/`, `libs/`, `download/` and explicitly lists `cookies.sqlite`, `logins.json`,
  `key4.db`.
- No network calls, no telemetry; Firefox telemetry and Mozilla account sync are disabled
  through `policies.json`.
- `deploy-gacc.sh` verifies Mozilla's official `SHA256SUMS` and aborts on mismatch.

## Verified / unverified

**Verified on Linux + WSLg:** portable Firefox launch and rendering, concurrent instances,
all four persona dimensions reaching the JS layer, font subset behaviour, per-profile proxy,
forced MAC install, session restore, sandbox probe and graceful downgrade, shortcut
generation, `deploy-gacc.sh` end-to-end incl. SHA256, `windows/gacc.ps1` parses cleanly.

**Not verified:** runtime behaviour of `windows/gacc.ps1` (no Windows machine available here);
subset spread with a much larger font pool.

## FAQ

**Blank pages after launch?**
The content sandbox is blocked by the environment — see "Sandbox and the yellow bar".
Check `profiles/accNN/firefox.log` for `uid_map: EACCES`.

**It complains about a missing `libasound.so.2`?**
`sudo apt install libdbus-glib-1-2 libasound2 libstartup-notification0`, or let
`deploy-gacc.sh` fetch them without root.

**How do I know the proxy is really in use?**
`./bin/gacc N --doctor` prints the profile's proxy and probes it; or open
`https://www.gstatic.com/generate_204` inside the window — HTTP 204 means it works.

**A new account number does not show up in `./bin/gacc list`.**
Account directories are created on **first launch** — run `./bin/gacc N` once.

**Can two instances share one account?**
No, one profile = one instance. `--stop` first.

**Can I use the Firefox I installed with `apt` / `snap` instead of the bundled portable build?**
Yes: `GACC_FIREFOX=/snap/bin/firefox ./bin/gacc 1`.
Mind that on Ubuntu 22.04 the `firefox` package is a snap transitional package, and snaps
**auto-update** — every update changes the UA / TLS / rendering fingerprint, which defeats the
point of a stable persona. If you go this route run `sudo snap refresh --hold firefox` first.
Enterprise policies for a snap build also live in `/etc/firefox/policies/` (root required),
whereas the portable build reads them from its own install directory.

**An instance is already running — what happens if I ask it to open a link?**
Firefox will not hand a URL to an already running instance (tested with every launch variant).
`gacc` therefore does not start a second instance (that would just fight over the profile lock);
it tells you to either `--stop` first, or install `xclip` and paste from the clipboard.

**I installed more fonts, now what?**
Re-run `./bin/gen-fonts.sh N` to rebuild the subset from the new pool.

## Scope

This is a **local browser configuration tool**. It contains no anti-bot evasion, bulk
registration or automated login. Multi-accounting may or may not be permitted by the service
you use — that is your call and your responsibility. It does not hide your IP and does not
fake hardware.

## License

[MIT](LICENSE)
