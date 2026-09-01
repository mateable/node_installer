# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Fixed
- `Sync:` line no longer flip-flops between real block-download progress and an unrelated
  header-sync percentage from one status check to the next — the display now sticks to a
  single progress axis, using the last known block count if a check's RPC call times out.
- `Network tip:` no longer disappears on a status check where RPC happened to time out; it
  now falls back to the last known block count the same way `Sync:` does.
- Sync percentage is now computed against the real network tip instead of locally-known
  headers, which climb gradually during header sync and previously made the percentage
  compare against a moving, incomplete target.
- Removed raw internal `debug.log` text (hashes, algo, log2_work, etc.) ever leaking into
  status output on an RPC timeout — only ever shows a clean, purpose-built message now.
- Spinner during `wait_for_rpc`/`check_reachability` now animates once per second instead of
  once per (much slower) poll interval, so it visibly spins instead of appearing to freeze.

### Added
- `.gitattributes` pinning `*.sh` (and text files generally) to LF line endings, regardless
  of a contributor's local `core.autocrlf` setting.

## [1.0.0] - 2026-08-31

Full rewrite of the installer.

### Added
- Real systemd service (`mateabled`) with auto-restart on crash/reboot and crash-loop
  protection (`StartLimitBurst`/`StartLimitIntervalSec`).
- Checksum-verified prebuilt binary downloads (SHA-256 against the GitHub release), with a
  build-from-source fallback.
- Dynamic "latest release" resolution and version pinning (`-v`).
- RAM-aware block cache sizing.
- UPnP plus automatic local firewall configuration (ufw/firewalld), with a post-install
  reachability check and IPv6-aware diagnosis.
- Fallback bootstrap peers (`addnode=`) in case DNS seeding is unavailable.
- Wallet support (`-w`): descriptor (default) or legacy (`-l`) wallets, address type
  selection (`-a`), backup helper (`-e`), optional encryption.
- Staking (`-k`), including the wallet-unlock tradeoff explained up front.
- Status summary (`-s`) and live dashboard (`-d`): sync %, peers, network-tip comparison,
  per-component disk usage, reachability.
- Update mode (`-c`) that swaps binaries in place without touching blockchain data.
- Failure webhook notifications (`-n`) if the service crash-loops and gives up.
- Log rotation for `debug.log`.
- Interactive install wizard for a no-flags run, safe under `curl | sh` (reads prompts from
  `/dev/tty`, not the script's own stdin).
- Uninstall (`-u`).
