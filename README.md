<h1 align="center">
MateableCoin Node Installer
<br/><br/>
<img src="https://64.media.tumblr.com/230b42ccd0bbc026d5b1258bb8a8f92c/4fe9f521c4196e49-e7/s540x810/4e419bef2010b24459e969c46eaa4b9e20e710fd.pnj" alt="mateablecoin" width="220"/>
</h1>

<div align="center">

**One command. A real, running MateableCoin node.**

[![mateablecoinBadge](https://img.shields.io/badge/Mateable-coin-blueviolet.svg)](https://coin.mateable.com)
[![Latest release](https://img.shields.io/github/v/release/mateable/node_installer?label=release&color=blueviolet)](https://github.com/mateable/node_installer/releases/latest)
[![Shell](https://img.shields.io/badge/shell-POSIX%20sh-blueviolet.svg)](install-full-node.sh)
[![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS-blueviolet.svg)](#-requirements)
[![Install](https://img.shields.io/badge/install-curl%20%7C%20sh-blueviolet.svg)](#-quick-start)

</div>

---

Downloads the official [MateableCoin](https://coin.mateable.com) Core release binary
(checksum-verified), installs it as a real **systemd service** that survives crashes and
reboots, tunes itself to your machine, and gets out of your way.

## 🚀 Quick start

```
curl -fsSL https://coin.mateable.com/install-full-node.sh | sh
```

No flags needed. Answer a couple of yes/no questions (or just press Enter for the defaults)
and you're running a node.

> **No wallet, no funds at risk, nothing to manage** — unless you ask for one.

## ✨ What it does

| | |
|---|---|
| 📦 | Installs the latest official Core release for your platform, **SHA-256 verified** against the checksum published with the release. Falls back to building from source if no prebuilt binary exists. |
| 🛡️ | Runs it as a systemd service (`mateabled`) that **restarts automatically** on crash or reboot, with crash-loop protection. |
| 🧠 | Sizes the block cache to your machine's **actual RAM** instead of a fixed default. |
| 🌐 | Enables UPnP and opens your **local firewall** (ufw/firewalld) so your node is actually reachable, not just running invisibly. |
| 🤝 | Adds known-stable fallback peers, so you connect fast even if DNS seeding is having a bad day. |
| 💼 | Optional wallet, staking, log rotation, and failure alerts — all **opt-in**. |

## 🧪 Quick examples

| I want to... | Command |
|---|---|
| Just run a node, no wallet | `./install-full-node.sh` |
| Run a node with a wallet | `./install-full-node.sh -w` |
| Run a node and stake | `./install-full-node.sh -k` |
| Check on my node | `./install-full-node.sh -s` |
| Watch it live | `./install-full-node.sh -d` |
| Update to the latest version | `./install-full-node.sh -c` |
| Back up my wallet | `./install-full-node.sh -e` |
| Remove everything | `./install-full-node.sh -u` |

## 💰 Wallet & staking

Pass `-w` to enable a wallet. By default it creates a modern **descriptor wallet** with native
SegWit (bech32) addresses — the current best-practice default. You'll get a real receiving
address printed immediately, and a reminder to back up your wallet directory
(`.mateable/wallets/`) somewhere off the machine. `./install-full-node.sh -e` does that backup
for you.

Options:
- `-l` — use a legacy wallet instead (only needed for compatibility with older tooling)
- `-a <type>` — pick a specific address type: `legacy`, `p2sh-segwit`, `bech32` (default), or
  `bech32m` (Taproot)
- `-k` — enable staking once the wallet is set up

> **On staking and encryption:** MateableCoin Core has no "stake-only" unlock mode — an
> unlocked wallet can also spend. An *unencrypted* wallet stakes immediately with no extra
> steps. If you encrypt your wallet, staking pauses until you run `walletpassphrase` to unlock
> it (you'll need to do this periodically, e.g. via cron, to keep staking active). The
> installer explains this tradeoff and lets you choose.

## 📊 Checking on your node

`-s` prints a one-time status summary: version, service state, sync progress, peer count,
how far behind the live network tip you are, disk usage broken down by component, and whether
your node is actually reachable from the internet.

`-d` shows the same thing as a **live dashboard** that refreshes in place every few seconds —
Ctrl+C to exit.

## 🔄 Updating

```
./install-full-node.sh -c
```

Checks GitHub for the latest release and, if there's a newer one, swaps the binaries in place.
Your blockchain data is never touched — no reindex needed. Pass `-y` to skip the confirmation
prompt, or `-v <version>` to update to (or pin) a specific version instead of always jumping to
latest.

## 🔔 Failure notifications

```
./install-full-node.sh -n https://your-webhook-url
```

If the node crash-loops and systemd gives up restarting it, this POSTs a JSON alert to your
webhook (Discord/Slack-compatible payload) so you find out immediately instead of discovering
a dead node by accident.

## ⚙️ All options

```
$ ./install-full-node.sh -h

Usage: install-full-node.sh [-h] [-v <version>] [-t <target_directory>] [-p <port>] [-w] [-l] [-a <type>] [-k] [-b] [-c] [-s] [-d] [-e] [-n <webhook_url>] [-y] [-u]
  -h                  Print usage.
  -v <version>        MateableCoin Core version to install. Default: latest release.
  -t <target_dir>     Target directory. Default: $HOME/mateable-core
  -p <port>           P2P listening port. Default: 6969
  -w                  Enable wallet (disabled by default -- a pure relay node has none).
  -l                  Create a legacy wallet instead of the default descriptor wallet.
                      Only needed for compatibility with older tooling; descriptor
                      (native SegWit/bech32) is recommended for new wallets. Implies -w.
  -a <type>           Receiving address type: legacy, p2sh-segwit, bech32 (default),
                      or bech32m (Taproot). Implies -w.
  -k                  Enable staking once the wallet is created. Implies -w. Staking
                      needs the wallet unlocked -- see the notes printed after setup.
  -b                  Force building from source instead of using a prebuilt binary.
  -c                  Check for and apply an update to an existing install (keeps your
                      blockchain data -- only swaps the binaries).
  -s                  Print a status summary for an existing install (sync %, peers,
                      reachability, disk usage) and exit.
  -d                  Live dashboard -- same info as -s, auto-refreshing every 3s.
                      Ctrl+C to exit.
  -e                  Back up the wallet to a timestamped file in the install
                      directory and exit. Copy it somewhere off this machine.
  -n <webhook_url>    POST a JSON alert to this URL if the node crash-loops and the
                      service gives up (Discord/Slack-compatible payload). Without
                      this, a dead node stays silent until someone checks -s.
  -y                  Assume yes -- don't prompt for confirmation (for scripted use).
  -u                  Uninstall MateableCoin Core (stops and removes the systemd service).
```

## 📋 Requirements

- Linux (systemd) or macOS
- `curl` or `wget`, `python3` (used to parse release metadata — most systems already have this)
- `sudo` access if not running as root, for installing the systemd service

## 🔒 Security notes

- The prebuilt binary's SHA-256 checksum is verified against the one published with the
  GitHub release before it's installed — a mismatch aborts the install.
- The RPC interface binds to `127.0.0.1` only, using cookie-based authentication (no
  hardcoded credentials).
- Wallet functionality is entirely opt-in. Without `-w`, no wallet is created and there is
  nothing on the node that could hold funds.

---

<div align="center">

Part of the [MateableCoin](https://coin.mateable.com) project · [Block Explorer](https://explorer.mateable.com) · [Network Nodes](https://explorer.mateable.com/nodes)

</div>
