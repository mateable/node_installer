#!/bin/sh
#
# install-full-node.sh
#
# Install script for a MateableCoin full node based on MateableCoin Core.
#
# Usage:
#   curl -fsSL https://coin.mateable.com/install-full-node.sh | sh
#
# By default this installs the official prebuilt MateableCoin Core binary
# for your platform (verified against the SHA-256 digest published with the
# GitHub release) and runs it as a real systemd service that restarts
# automatically on crash or reboot. If no prebuilt binary is available for
# your platform, the script falls back to building from source.
#
# Wallet functionality is disabled by default (pure relay/validation node,
# no funds at risk). Pass -w to enable the wallet.
#
# All files are installed under $TARGET_DIR (default: $HOME/mateable-core):
#   bin/            -- mateabled, mateable-cli
#   .mateable/       -- config, blockchain data
#
###############################################################################

REPO="mateable/mateablecoin-24.x"
VERSION="latest"
TARGET_DIR="$HOME/mateable-core"
PORT=6969
VERSION_PINNED=0
WALLET=0
LEGACY_WALLET=0
ADDRESS_TYPE="bech32"
STAKING=0
UNINSTALL=0
FORCE_BUILD=0
UPDATE_CHECK=0
STATUS_CHECK=0
DASHBOARD=0
BACKUP=0
ASSUME_YES=0
NOTIFY_WEBHOOK=""
EXPLICIT_WALLET_FLAG=0

SYSTEM=$(uname -s)
ARCH=$(uname -m)
MAKE="make"
[ "$SYSTEM" = "FreeBSD" ] && MAKE="gmake"
SUDO=""

PURPLE=$(tput setaf 5 2>/dev/null)
BLUE=$(tput setaf 4 2>/dev/null)
GREEN=$(tput setaf 2 2>/dev/null)
YELLOW=$(tput setaf 3 2>/dev/null)
RED=$(tput setaf 1 2>/dev/null)
RESET=$(tput sgr0 2>/dev/null)

usage() {
    cat <<EOF
Usage: $0 [-h] [-v <version>] [-t <target_directory>] [-p <port>] [-w] [-l] [-a <type>] [-k] [-b] [-c] [-s] [-d] [-e] [-n <webhook_url>] [-y] [-u]
  -h                  Print usage.
  -v <version>        MateableCoin Core version to install. Default: latest release.
  -t <target_dir>     Target directory. Default: $TARGET_DIR
  -p <port>           P2P listening port. Default: $PORT
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
EOF
}

print_info()    { printf "%s%s%s\n" "$BLUE" "$1" "$RESET"; }
print_success() { printf "%s%s%s\n" "$GREEN" "$1" "$RESET"; }
print_warning() { printf "%s%s%s\n" "$YELLOW" "$1" "$RESET"; }
print_error()   { printf "%s%s%s\n" "$RED" "$1" "$RESET"; }

print_banner() {
    printf "%s" "$PURPLE"
    cat <<'BANNER'

    __  __       _             _     _        _____      _
   |  \/  |     | |           | |   | |      / ____|    (_)
   | \  / | __ _| |_ ___  __ _| |__ | | ___  | |     ___  _ _ __
   | |\/| |/ _` | __/ _ \/ _` | '_ \| |/ _ \ | |    / _ \| | '_ \
   | |  | | (_| | ||  __/ (_| | |_) | |  __/ | |___| (_) | | | | |
   |_|  |_|\__,_|\__\___|\__,_|_.__/|_|\___|  \_____\___/|_|_| |_|

BANNER
    printf "%s" "$RESET"
    print_info "Full node installer -- coin.mateable.com"
    echo
}

program_exists() { command -v "$1" >/dev/null 2>&1; }

SPIN_CHARS='|/-\'
SPIN_POS=0
spin_tick() {
    # Prints one frame of a spinner in place (no newline) so a "this may
    # take a minute" wait doesn't look like the script has frozen.
    SPIN_POS=$(( (SPIN_POS + 1) % 4 ))
    char=$(printf '%s' "$SPIN_CHARS" | cut -c$((SPIN_POS + 1)))
    printf "\r%s %s%s " "$BLUE" "$char" "$RESET"
}
spin_clear() {
    # Avoid printf's "%*s" dynamic-width form -- not reliably portable
    # across printf implementations (dash builtin, busybox, etc.).
    printf "\r                                        \r"
}

RPC_TIMEOUT_PREFIX=""
program_exists timeout && RPC_TIMEOUT_PREFIX="timeout 8 "

have_tty() {
    # A real controlling terminal is available even when this script's own
    # stdin is a pipe (e.g. curl ... | sh) -- /dev/tty still reaches the
    # user's actual keyboard in that case, [ -t 0 ] alone does not.
    [ -r /dev/tty ] && [ -w /dev/tty ]
}

fetch() {
    # fetch <url> <output_file>
    # A hung request here with no bound would block the whole script (and,
    # inside the dashboard's refresh loop, block it indefinitely) -- always
    # cap connect + total time.
    if program_exists curl; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$1" -o "$2"
    elif program_exists wget; then
        wget -q --timeout=30 "$1" -O "$2"
    else
        print_error "curl or wget is required. Please install one and re-run."
        exit 1
    fi
}

fetch_stdout() {
    if program_exists curl; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$1"
    elif program_exists wget; then
        wget -qO- --timeout=30 "$1"
    else
        print_error "curl or wget is required. Please install one and re-run."
        exit 1
    fi
}

resolve_version() {
    # Turns "latest" into a real tag name (e.g. v24.1.1) by asking GitHub.
    if [ "$VERSION" != "latest" ]; then
        return
    fi
    print_info "Checking GitHub for the latest MateableCoin Core release..."
    latest_json=$(fetch_stdout "https://api.github.com/repos/$REPO/releases/latest")
    tag=$(echo "$latest_json" | python3 -c "import json,sys; print(json.load(sys.stdin, strict=False).get('tag_name',''))" 2>/dev/null)
    if [ -z "$tag" ]; then
        print_error "Could not determine the latest release from GitHub. Pass -v <version> to pin one manually."
        exit 1
    fi
    VERSION="$tag"
    print_info "Latest release is $VERSION."
}

installed_version() {
    if [ -x "$TARGET_DIR/bin/mateabled" ]; then
        "$TARGET_DIR/bin/mateabled" --version 2>/dev/null | head -1 | awk '{print $NF}'
    fi
}

check_for_update() {
    if [ ! -x "$TARGET_DIR/bin/mateabled" ]; then
        print_error "No existing install found at $TARGET_DIR. Run without -c to install."
        exit 1
    fi

    current=$(installed_version)
    print_info "Currently installed: ${current:-unknown}"

    if [ "$VERSION_PINNED" -ne 1 ]; then
        VERSION="latest"
    fi
    resolve_version
    latest="$VERSION"

    if [ "$current" = "$latest" ]; then
        print_success "Already up to date ($current)."
        exit 0
    fi

    print_info "Update available: ${current:-unknown} -> $latest"
    if [ "$ASSUME_YES" -ne 1 ]; then
        printf "%sUpdate now? Your blockchain data will be kept. (y/n)%s " "$BLUE" "$RESET"
        read -r answer < /dev/tty
        if [ "$answer" != "y" ]; then
            print_info "Skipped."
            exit 0
        fi
    fi

    running=0
    if program_exists systemctl && systemctl is-active --quiet mateabled 2>/dev/null; then
        running=1
        init_sudo
        print_info "Stopping mateabled for the update..."
        $SUDO systemctl stop mateabled
    fi

    if [ "$FORCE_BUILD" -eq 1 ] || ! install_prebuilt_binary; then
        build_from_source
    fi

    if [ "$running" -eq 1 ]; then
        print_info "Starting mateabled..."
        $SUDO systemctl start mateabled
    fi

    print_success "Updated to $latest. Your blockchain data was not touched -- no reindex needed."
    exit 0
}

init_sudo() {
    if [ "$(id -u)" -ne 0 ]; then
        if program_exists sudo; then
            SUDO="sudo"
        else
            print_error "This step requires root. Please install sudo, or run as root."
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Prebuilt binary install path
# ---------------------------------------------------------------------------

release_asset_name() {
    case "$SYSTEM" in
        Linux)
            case "$ARCH" in
                x86_64) echo "mateable-24.x-linux-x86_64.tar.gz" ;;
                aarch64|arm64) echo "mateable-24.x-linux-arm64.tar.gz" ;;
                *) echo "" ;;
            esac
            ;;
        Darwin)
            case "$ARCH" in
                x86_64) echo "mateable-24.x-macos-x86_64.tar.gz" ;;
                arm64) echo "mateable-24.x-macos-arm64.tar.gz" ;;
                *) echo "" ;;
            esac
            ;;
        *) echo "" ;;
    esac
}

install_prebuilt_binary() {
    asset=$(release_asset_name)
    if [ -z "$asset" ]; then
        print_warning "No prebuilt binary available for $SYSTEM/$ARCH."
        return 1
    fi

    if ! program_exists python3; then
        print_warning "python3 not found (needed to parse the release manifest); falling back to build from source."
        return 1
    fi

    print_info "Fetching release info for $VERSION..."
    release_json=$(fetch_stdout "https://api.github.com/repos/$REPO/releases/tags/$VERSION")
    if [ -z "$release_json" ]; then
        print_warning "Could not reach GitHub releases API; falling back to build from source."
        return 1
    fi

    download_url=$(echo "$release_json" | python3 -c "
import json, sys
d = json.load(sys.stdin, strict=False)
for a in d.get('assets', []):
    if a['name'] == '$asset':
        print(a['browser_download_url'])
        break
")
    expected_digest=$(echo "$release_json" | python3 -c "
import json, sys
d = json.load(sys.stdin, strict=False)
for a in d.get('assets', []):
    if a['name'] == '$asset':
        print(a.get('digest', '').replace('sha256:', ''))
        break
")

    if [ -z "$download_url" ]; then
        print_warning "Asset $asset not found in release $VERSION; falling back to build from source."
        return 1
    fi

    work_dir=$(mktemp -d)
    print_info "Downloading $asset..."
    fetch "$download_url" "$work_dir/$asset"

    if [ -n "$expected_digest" ]; then
        print_info "Verifying checksum..."
        if program_exists sha256sum; then
            actual_digest=$(sha256sum "$work_dir/$asset" | awk '{print $1}')
        elif program_exists shasum; then
            actual_digest=$(shasum -a 256 "$work_dir/$asset" | awk '{print $1}')
        else
            print_warning "No sha256sum/shasum available; skipping checksum verification."
            actual_digest=""
        fi
        if [ -n "$actual_digest" ]; then
            if [ "$actual_digest" != "$expected_digest" ]; then
                print_error "Checksum mismatch for $asset."
                print_error "  expected: $expected_digest"
                print_error "  actual:   $actual_digest"
                rm -rf "$work_dir"
                exit 1
            fi
            print_success "Checksum verified ($actual_digest)."
        fi
    else
        print_warning "No published checksum found for this asset; continuing without verification."
    fi

    mkdir -p "$TARGET_DIR/bin"
    tar xzf "$work_dir/$asset" -C "$work_dir"
    cp "$work_dir/mateabled" "$TARGET_DIR/bin/mateabled"
    cp "$work_dir/mateable-cli" "$TARGET_DIR/bin/mateable-cli"
    chmod +x "$TARGET_DIR/bin/mateabled" "$TARGET_DIR/bin/mateable-cli"
    rm -rf "$work_dir"

    print_success "Installed prebuilt MateableCoin Core $VERSION ($asset)."
    return 0
}

# ---------------------------------------------------------------------------
# Build-from-source fallback
# ---------------------------------------------------------------------------

install_debian_build_dependencies() {
    $SUDO apt-get update
    $SUDO apt-get install -y automake autotools-dev build-essential curl bison \
        git libboost-all-dev libevent-dev libminiupnpc-dev libssl-dev libtool pkg-config
}

install_fedora_build_dependencies() {
    $SUDO dnf install -y automake boost-devel curl gcc-c++ bison git \
        libevent-devel libtool miniupnpc-devel openssl-devel
}

install_archlinux_build_dependencies() {
    $SUDO pacman -S --noconfirm automake boost curl bison git libevent libtool miniupnpc openssl
}

install_mac_build_dependencies() {
    program_exists gcc || xcode-select --install
    program_exists brew || /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
    brew install automake boost libevent libtool miniupnpc openssl pkg-config
}

install_build_dependencies() {
    init_sudo
    case "$SYSTEM" in
        Linux)
            if program_exists apt-get; then install_debian_build_dependencies
            elif program_exists dnf; then install_fedora_build_dependencies
            elif program_exists pacman; then install_archlinux_build_dependencies
            else
                print_error "Unsupported Linux distribution for automatic dependency install."
                print_error "Install build-essential/boost/libevent/openssl/etc. manually and re-run with -b."
                exit 1
            fi
            ;;
        Darwin) install_mac_build_dependencies ;;
        *)
            print_error "Unsupported platform for build-from-source: $SYSTEM"
            exit 1
            ;;
    esac
}

build_from_source() {
    install_build_dependencies

    src_dir="$TARGET_DIR/mateablecoin-src"
    if [ ! -d "$src_dir" ]; then
        print_info "Cloning MateableCoin Core source ($VERSION)..."
        git clone --quiet --branch "$VERSION" "https://github.com/$REPO.git" "$src_dir"
    fi

    print_info "Building MateableCoin Core $VERSION -- this will take a while..."
    build_log="$src_dir/build.log"
    (
        set -e
        cd "$src_dir"
        cd depends
        $MAKE "HOST=$(uname -m)-pc-linux-gnu" -j"$(nproc 2>/dev/null || echo 2)"
        cd ..
        ./autogen.sh
        CONFIG_SITE="$src_dir/depends/$(uname -m)-pc-linux-gnu/share/config.site" ./configure
        $MAKE -j"$(nproc 2>/dev/null || echo 2)"
    ) > "$build_log" 2>&1

    if [ ! -f "$src_dir/src/mateabled" ]; then
        print_error "Build failed. See $build_log"
        exit 1
    fi

    mkdir -p "$TARGET_DIR/bin"
    cp "$src_dir/src/mateabled" "$TARGET_DIR/bin/mateabled"
    cp "$src_dir/src/mateable-cli" "$TARGET_DIR/bin/mateable-cli"
    print_success "Built and installed MateableCoin Core $VERSION from source."
}

# ---------------------------------------------------------------------------
# Config + systemd service
# ---------------------------------------------------------------------------

detect_mem_mb() {
    # Sets the global MEM_MB. Not a subshell -- callers need the value after return.
    MEM_MB=450
    if [ -r /proc/meminfo ]; then
        mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        MEM_MB=$((mem_kb / 1024))
    elif [ "$SYSTEM" = "Darwin" ]; then
        mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        MEM_MB=$((mem_bytes / 1024 / 1024))
    fi
}

detect_dbcache() {
    # Pick a dbcache (MB) sized to leave plenty of headroom for the OS,
    # mongod/explorer if colocated, and mateabled's own non-cache memory use.
    # Undersizing this was directly responsible for the worst sync failures
    # we hit tuning this fleet -- default conservatively.
    if [ "$MEM_MB" -ge 8000 ]; then
        echo 900
    elif [ "$MEM_MB" -ge 4000 ]; then
        echo 450
    elif [ "$MEM_MB" -ge 2000 ]; then
        echo 200
    else
        echo 64
    fi
}

write_config() {
    mkdir -p "$TARGET_DIR/.mateable"
    disablewallet_line="disablewallet=1"
    fallbackfee_line="# fallbackfee not needed -- wallet disabled"
    debug_pos_line="# debug=pos not needed -- staking disabled"
    if [ "$WALLET" -eq 1 ]; then
        disablewallet_line="# wallet enabled"
        # Without this, sending a transaction can fail outright with a fee
        # estimation error on a freshly-synced wallet that hasn't seen enough
        # mempool history yet to estimate a fee on its own. Value matches
        # what's actually running on the exchange's own production wallet.
        fallbackfee_line="fallbackfee=0.00005"
    fi
    if [ "$STAKING" -eq 1 ]; then
        # Verbose staking diagnostics -- without this, most of what the
        # staking thread does is silent, matching production practice.
        debug_pos_line="debug=pos"
    fi
    detect_mem_mb
    dbcache=$(detect_dbcache)

    cat > "$TARGET_DIR/.mateable/mateable.conf" <<EOF
server=1
listen=1
upnp=1
txindex=1
maxconnections=40
dbcache=$dbcache
port=$PORT
rpcport=6966
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
# Known-stable public nodes, used as a fallback if DNS seeding is ever down.
addnode=75.146.49.209
addnode=50.116.31.124
$disablewallet_line
$fallbackfee_line
$debug_pos_line
EOF
    chmod 600 "$TARGET_DIR/.mateable/mateable.conf"
    print_info "dbcache set to ${dbcache}MB based on ${MEM_MB}MB system RAM."
}

get_wallet_address() {
    cli="${RPC_TIMEOUT_PREFIX}$TARGET_DIR/bin/mateable-cli -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable"
    program_exists python3 || return
    $cli getaddressesbylabel "" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin, strict=False)
    if d:
        print(sorted(d.keys())[0])
except Exception:
    pass
" 2>/dev/null
}

wait_for_rpc() {
    cli="${RPC_TIMEOUT_PREFIX}$TARGET_DIR/bin/mateable-cli -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable"
    i=0
    while [ "$i" -lt 30 ]; do
        if $cli getblockcount >/dev/null 2>&1; then
            spin_clear
            return 0
        fi
        spin_tick
        i=$((i + 1))
        sleep 2
    done
    spin_clear
    return 1
}

setup_wallet() {
    [ "$WALLET" -eq 1 ] || return
    cli="${RPC_TIMEOUT_PREFIX}$TARGET_DIR/bin/mateable-cli -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable"

    print_info "Waiting for mateabled to be ready to create your wallet..."
    if ! wait_for_rpc; then
        print_warning "Node didn't come up in time -- create your wallet manually once it's running:"
        print_warning "  $cli createwallet wallet"
        return
    fi

    case "$ADDRESS_TYPE" in
        legacy|p2sh-segwit|bech32|bech32m) ;;
        *)
            print_warning "Unknown address type '$ADDRESS_TYPE', defaulting to bech32."
            ADDRESS_TYPE="bech32"
            ;;
    esac

    encrypted=0
    if [ "$LEGACY_WALLET" -eq 1 ]; then
        print_info "Creating a legacy wallet ($ADDRESS_TYPE addresses, compatibility mode)..."
        if ! $cli createwallet "wallet" false false "" false false >/dev/null 2>&1; then
            print_warning "Wallet creation failed or a wallet already exists. Skipping."
            return
        fi
    else
        # Modern descriptor wallet -- the current best-practice default for a new wallet.
        print_info "Creating a descriptor wallet ($ADDRESS_TYPE addresses)..."
        if ! $cli createwallet "wallet" false false "" false true >/dev/null 2>&1; then
            print_warning "Wallet creation failed or a wallet already exists. Skipping."
            return
        fi
    fi
    address=$($cli getnewaddress "" "$ADDRESS_TYPE" 2>/dev/null)

    if [ -n "$address" ]; then
        print_success "Wallet created. Your first receiving address:"
        printf "%s   %s%s\n" "$GREEN" "$address" "$RESET"
    else
        print_warning "Wallet created, but couldn't generate a '$ADDRESS_TYPE' address."
        if [ "$LEGACY_WALLET" -eq 1 ] && [ "$ADDRESS_TYPE" = "bech32m" ]; then
            print_warning "Legacy wallets can't create Taproot (bech32m) addresses -- drop -l or"
            print_warning "pick a different -a type (legacy, p2sh-segwit, bech32)."
        fi
        print_warning "Get an address manually with: $cli getnewaddress"
    fi

    printf "%s" "$YELLOW"
    echo "-----------------------------------------------------------------"
    echo " IMPORTANT: this wallet holds real funds once you receive coins."
    echo " Back up $TARGET_DIR/.mateable/wallets/ now, and after any new"
    echo " address use. Losing it means losing access to any funds in it."
    echo "-----------------------------------------------------------------"
    printf "%s" "$RESET"

    if [ "$STAKING" -eq 1 ]; then
        print_info "Staking requires the wallet to be unlocked -- MateableCoin Core has no"
        print_info "stake-only unlock mode, so an unlock also permits spending."
    fi

    if have_tty; then
        default_enc="y"
        [ "$STAKING" -eq 1 ] && default_enc="n"
        printf "%sEncrypt this wallet with a passphrase now? (y/n, default %s)%s " "$BLUE" "$default_enc" "$RESET"
        read -r enc_answer < /dev/tty
        [ -z "$enc_answer" ] && enc_answer="$default_enc"
        if [ "$enc_answer" = "y" ]; then
            printf "%sEnter a passphrase (input hidden):%s " "$BLUE" "$RESET"
            stty -echo < /dev/tty 2>/dev/null
            read -r passphrase < /dev/tty
            stty echo < /dev/tty 2>/dev/null
            echo
            if [ -n "$passphrase" ]; then
                $cli encryptwallet "$passphrase" >/dev/null 2>&1
                encrypted=1
                print_success "Wallet encrypted. mateabled will restart automatically."
                print_info "You'll need to run 'walletpassphrase <phrase> <seconds>' via the CLI before sending funds."
            else
                print_warning "Empty passphrase entered -- skipped encryption."
            fi
        fi
    else
        print_info "Non-interactive session -- skipping the encryption prompt. Encrypt later with:"
        print_info "  $cli encryptwallet <passphrase>"
    fi

    if [ "$STAKING" -eq 1 ]; then
        if [ "$encrypted" -eq 1 ]; then
            print_warning "Wallet is encrypted -- staking is paused until you unlock it. Run:"
            print_warning "  $cli walletpassphrase <passphrase> <seconds>"
            print_warning "periodically (e.g. via cron) to keep staking active, or leave it"
            print_warning "unencrypted if this node's sole purpose is unattended staking and"
            print_warning "you accept that tradeoff."
            $cli setstaking true >/dev/null 2>&1
        else
            if wait_for_rpc && $cli setstaking true >/dev/null 2>&1; then
                print_success "Staking enabled. It'll activate automatically once your balance matures"
                print_success "and the node is fully synced -- check $TARGET_DIR/.mateable/debug.log for"
                print_success "\"Starting staking thread\" to confirm."
            fi
        fi
    fi
}

install_failure_notifier() {
    [ -n "$NOTIFY_WEBHOOK" ] || return
    init_sudo

    conf_file=/tmp/mateabled-notify.conf.$$
    echo "$NOTIFY_WEBHOOK" > "$conf_file"
    $SUDO mkdir -p /etc/mateabled
    $SUDO cp "$conf_file" /etc/mateabled/notify-webhook
    rm -f "$conf_file"

    script_file=/tmp/mateabled-notify.sh.$$
    cat > "$script_file" <<'EOF'
#!/bin/sh
webhook=$(cat /etc/mateabled/notify-webhook 2>/dev/null)
[ -n "$webhook" ] || exit 0
host=$(hostname)
msg="MateableCoin node on $host has crash-looped and stopped restarting. Check: journalctl -u mateabled -n 50"
curl -fsS -m 10 -H "Content-Type: application/json" -d "{\"content\":\"$msg\",\"text\":\"$msg\"}" "$webhook" >/dev/null 2>&1
EOF
    $SUDO cp "$script_file" /usr/local/bin/mateabled-notify.sh
    $SUDO chmod +x /usr/local/bin/mateabled-notify.sh
    rm -f "$script_file"

    notify_unit=/tmp/mateabled-notify.service.$$
    cat > "$notify_unit" <<'EOF'
[Unit]
Description=Notify on MateableCoin daemon failure

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mateabled-notify.sh
EOF
    $SUDO cp "$notify_unit" /etc/systemd/system/mateabled-notify.service
    rm -f "$notify_unit"
    print_info "Failure notifications configured -- will POST to your webhook if the service crash-loops."
}

install_systemd_service() {
    if ! program_exists systemctl; then
        print_warning "systemd not found -- skipping service install. Start manually with:"
        print_warning "  $TARGET_DIR/bin/mateabled -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable -printtoconsole"
        return
    fi

    init_sudo
    install_failure_notifier
    on_failure_line=""
    [ -n "$NOTIFY_WEBHOOK" ] && on_failure_line="OnFailure=mateabled-notify.service"

    service_file=/tmp/mateabled.service.$$
    cat > "$service_file" <<EOF
[Unit]
Description=MateableCoin Daemon
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5
$on_failure_line

[Service]
Type=simple
User=$(id -un)
ExecStart=$TARGET_DIR/bin/mateabled -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable -printtoconsole
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    $SUDO cp "$service_file" /etc/systemd/system/mateabled.service
    rm -f "$service_file"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable mateabled
    $SUDO systemctl start mateabled
    print_success "Installed and started mateabled as a systemd service (auto-restarts on crash/reboot)."
}

open_firewall() {
    # UPnP only opens the port on the router -- a local host firewall can
    # still silently block inbound connections even after that succeeds.
    if program_exists ufw && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
        init_sudo
        $SUDO ufw allow "$PORT/tcp" >/dev/null 2>&1
        print_info "Opened port $PORT/tcp in ufw."
    elif program_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
        init_sudo
        $SUDO firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1
        $SUDO firewall-cmd --reload >/dev/null 2>&1
        print_info "Opened port $PORT/tcp in firewalld."
    fi
}

check_reachability() {
    cli="${RPC_TIMEOUT_PREFIX}$TARGET_DIR/bin/mateable-cli -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable"
    print_info "Checking whether your node is reachable from the internet (UPnP may take a minute to negotiate)..."

    if ! wait_for_rpc; then
        print_warning "Node isn't responding to RPC yet -- skipping the reachability check. Run '$0 -s' later to check."
        return
    fi

    i=0
    reachable=""
    while [ "$i" -lt 15 ]; do
        info=$($cli getnetworkinfo 2>/dev/null)
        if [ -n "$info" ] && program_exists python3; then
            reachable=$(echo "$info" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin, strict=False)
    for a in d.get('localaddresses', []):
        if a.get('score', 0) > 0:
            print(a.get('address',''))
            break
except Exception:
    pass
" 2>/dev/null)
        fi
        [ -n "$reachable" ] && break
        spin_tick
        i=$((i + 1))
        sleep 4
    done
    spin_clear

    if [ -n "$reachable" ]; then
        print_success "Your node is reachable from the internet at $reachable:$PORT."
        print_success "It will show up in the network node count at https://explorer.mateable.com/nodes"
        return
    fi

    print_warning "Your node doesn't look reachable from the internet yet."

    # IPv6 being silently disabled at the OS level cost us hours diagnosing a
    # container tonight -- check for it explicitly instead of leaving people
    # to rediscover the same thing the hard way.
    if [ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "1" ]; then
        print_warning "IPv6 is disabled at the OS level on this machine (net.ipv6.conf.all.disable_ipv6=1)."
        print_warning "That alone can make you unreachable to IPv6-only peers even with everything"
        print_warning "else configured correctly. Re-enable it with:"
        print_warning "  sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0"
    fi

    print_warning "UPnP is enabled (upnp=1) and may still be negotiating with your router, or your"
    print_warning "router may not support UPnP. If this doesn't resolve on its own, forward TCP"
    print_warning "port $PORT to this machine in your router's settings."
    print_warning "Your node will still sync and work fine as an outbound-only peer either way --"
    print_warning "this only affects whether other nodes can connect to you."
}

show_status() {
    cli="${RPC_TIMEOUT_PREFIX}$TARGET_DIR/bin/mateable-cli -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable"
    if [ ! -x "$TARGET_DIR/bin/mateable-cli" ]; then
        print_error "No install found at $TARGET_DIR."
        exit 1
    fi

    print_banner
    print_info "Version:      $(installed_version)"

    if program_exists systemctl; then
        state=$(systemctl is-active mateabled 2>/dev/null)
        print_info "Service:      ${state:-not installed}"
        if [ "$state" = "failed" ]; then
            print_error "The service is in a failed state -- it likely crash-looped and hit its"
            print_error "restart limit. Check: journalctl -u mateabled -n 50"
            print_error "Once you've found the cause, clear it with: sudo systemctl reset-failed mateabled"
        fi
    fi

    info=$($cli getblockchaininfo 2>/dev/null)
    conns=$($cli getconnectioncount 2>/dev/null)
    local_blocks=""
    if [ -n "$info" ] && program_exists python3; then
        local_blocks=$(echo "$info" | python3 -c "
import json, sys
d = json.load(sys.stdin, strict=False)
blocks = d.get('blocks', 0)
headers = d.get('headers', 0)
pct = (blocks / headers * 100) if headers else 0
ibd = d.get('initialblockdownload', True)
print('Sync:         %s / %s blocks (%.1f%%)%s' % (blocks, headers, pct, '' if not ibd else '  [still catching up]'))
print(blocks)
" 2>/dev/null)
        echo "$local_blocks" | head -1
        local_blocks=$(echo "$local_blocks" | tail -1)
    else
        print_warning "Sync:         node not responding to RPC yet"
    fi
    [ -n "$conns" ] && print_info "Peers:        $conns"

    wallet_addr=$(get_wallet_address)
    [ -n "$wallet_addr" ] && print_info "Wallet:       $wallet_addr"

    # Compare against the live public explorer -- this is the actual
    # ground-truth check we kept having to do by hand tonight to tell
    # "genuinely stuck" apart from "still catching up."
    if [ -n "$local_blocks" ]; then
        network_tip=$(fetch_stdout "https://explorer.mateable.com/api/getblockcount" 2>/dev/null)
        case "$network_tip" in
            ''|*[!0-9]*) ;;
            *)
                behind=$((network_tip - local_blocks))
                if [ "$behind" -le 2 ]; then
                    print_success "Network tip:  $network_tip (you're caught up)"
                else
                    print_warning "Network tip:  $network_tip ($behind blocks behind)"
                fi
                ;;
        esac
    fi

    if [ -d "$TARGET_DIR/.mateable" ]; then
        size=$(du -sh "$TARGET_DIR/.mateable" 2>/dev/null | awk '{print $1}')
        print_info "Disk used:    ${size:-unknown} total"
        # Broken down by component -- chainworkdb (MTBC-specific chainwork
        # tracking for the 5-algo + PoS system) is easy to overlook and was
        # a real source of confusion diagnosing slow syncs tonight.
        for d in blocks chainstate chainworkdb indexes; do
            if [ -d "$TARGET_DIR/.mateable/$d" ]; then
                dsize=$(du -sh "$TARGET_DIR/.mateable/$d" 2>/dev/null | awk '{print $1}')
                print_info "  $d: ${dsize:-0}"
            fi
        done
    fi

    info2=$($cli getnetworkinfo 2>/dev/null)
    if [ -n "$info2" ] && program_exists python3; then
        reach=$(echo "$info2" | python3 -c "
import json, sys
d = json.load(sys.stdin, strict=False)
for a in d.get('localaddresses', []):
    if a.get('score', 0) > 0:
        print(a.get('address',''))
        break
" 2>/dev/null)
        if [ -n "$reach" ]; then
            print_success "Reachable:    yes ($reach:$PORT)"
        else
            print_warning "Reachable:    no (outbound-only -- see -h for port forwarding notes)"
        fi
    fi
}

print_status() {
    show_status
    exit 0
}

run_dashboard() {
    if [ ! -x "$TARGET_DIR/bin/mateable-cli" ]; then
        print_error "No install found at $TARGET_DIR."
        exit 1
    fi
    trap 'printf "%s\n" "$RESET"; exit 0' INT TERM

    # Redraw in place instead of clearing the whole screen each cycle --
    # move the cursor back up by exactly as many lines as the previous
    # frame printed, erase from there down, then print the new frame.
    # Labels stay put; only the values actually flicker/update.
    prev_lines=0
    while true; do
        frame=$(show_status; echo; printf "%sRefreshing every 3s -- Ctrl+C to exit%s" "$PURPLE" "$RESET")
        if [ "$prev_lines" -gt 0 ]; then
            printf '\033[%dA\033[J' "$prev_lines"
        fi
        printf '%s\n' "$frame"
        prev_lines=$(printf '%s\n' "$frame" | wc -l)
        sleep 3
    done
}

install_logrotate() {
    program_exists logrotate || return
    init_sudo
    logrotate_file=/tmp/mateabled-logrotate.$$
    cat > "$logrotate_file" <<EOF
$TARGET_DIR/.mateable/debug.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    $SUDO cp "$logrotate_file" /etc/logrotate.d/mateabled
    rm -f "$logrotate_file"
}

backup_wallet() {
    dest="$1"
    cli="${RPC_TIMEOUT_PREFIX}$TARGET_DIR/bin/mateable-cli -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable"
    if [ ! -x "$TARGET_DIR/bin/mateable-cli" ]; then
        print_error "No install found at $TARGET_DIR."
        exit 1
    fi
    if [ -z "$dest" ]; then
        dest="$TARGET_DIR/wallet-backup-$(date +%Y%m%d-%H%M%S).dat"
    fi
    if $cli backupwallet "$dest" >/dev/null 2>&1; then
        print_success "Wallet backed up to $dest"
        print_warning "Store a copy of this somewhere off this machine -- it's your only way back in"
        print_warning "if this disk fails."
    else
        print_error "Backup failed. Is the node running with a wallet loaded? Check with: $0 -s"
        exit 1
    fi
    exit 0
}

uninstall() {
    if program_exists systemctl && [ -f /etc/systemd/system/mateabled.service ]; then
        init_sudo
        print_info "Stopping and removing the mateabled systemd service..."
        $SUDO systemctl stop mateabled 2>/dev/null
        $SUDO systemctl disable mateabled 2>/dev/null
        $SUDO rm -f /etc/systemd/system/mateabled.service
        $SUDO rm -f /etc/systemd/system/mateabled-notify.service
        $SUDO rm -rf /etc/mateabled
        $SUDO rm -f /usr/local/bin/mateabled-notify.sh
        $SUDO rm -f /etc/logrotate.d/mateabled
        $SUDO systemctl daemon-reload
    fi
    if [ -d "$TARGET_DIR" ]; then
        rm -rf "$TARGET_DIR"
        print_success "Removed $TARGET_DIR."
    fi
    print_success "MateableCoin Core uninstalled."
}

run_wizard() {
    # Only kicks in for a fresh interactive install where the user hasn't
    # already told us what they want via flags -- simple y/n questions
    # instead of requiring anyone to know the right flags up front. Reads
    # from /dev/tty directly so this still works piped through curl | sh,
    # where this script's own stdin is the pipe delivering the script text,
    # not the keyboard.
    have_tty || return
    [ "$EXPLICIT_WALLET_FLAG" -eq 0 ] || return

    printf "%sA few quick questions -- press Enter to accept the default shown.%s\n" "$PURPLE" "$RESET"
    echo

    printf "%sRun this as a plain relay node only, no wallet? (y/n, default y)%s " "$BLUE" "$RESET"
    read -r ans < /dev/tty
    if [ "$ans" = "n" ]; then
        WALLET=1
        printf "%sUse a legacy wallet instead of the recommended descriptor wallet? (y/n, default n)%s " "$BLUE" "$RESET"
        read -r ans < /dev/tty
        [ "$ans" = "y" ] && LEGACY_WALLET=1

        printf "%sEnable staking once the wallet is set up? (y/n, default n)%s " "$BLUE" "$RESET"
        read -r ans < /dev/tty
        [ "$ans" = "y" ] && STAKING=1
    fi
    echo
}

print_readme() {
    printf "%s" "$GREEN"
    echo "-----------------------------------------------------------------"
    printf "%s" "$RESET"
    echo " Your MateableCoin node is running."
    echo
    if [ "$WALLET" -eq 1 ]; then
        wallet_addr=$(get_wallet_address)
        if [ -n "$wallet_addr" ]; then
            printf "%s   Your wallet address: %s%s\n" "$GREEN" "$wallet_addr" "$RESET"
            echo "   (also shown anytime with: $0 -t $TARGET_DIR -s)"
            echo
        fi
    fi
    echo "   Live dashboard: $0 -t $TARGET_DIR -d"
    echo "   Status:       systemctl status mateabled"
    echo "   Logs:         journalctl -u mateabled -f"
    echo "   Stop:         sudo systemctl stop mateabled"
    echo "   Start:        sudo systemctl start mateabled"
    echo "   CLI:          $TARGET_DIR/bin/mateable-cli -conf=$TARGET_DIR/.mateable/mateable.conf -datadir=$TARGET_DIR/.mateable getblockchaininfo"
    echo "   Update:       $0 -c"
    echo "   Uninstall:    $0 -u"
    echo
    echo " It may take a while for your node to catch up to the current chain tip."
    echo " Track your sync progress from the explorer: https://explorer.mateable.com/nodes"
    printf "%s" "$GREEN"
    echo "-----------------------------------------------------------------"
    printf "%s" "$RESET"
}

# ---------------------------------------------------------------------------
# Argument parsing + main
# ---------------------------------------------------------------------------

while getopts ":v:t:p:a:n:wlkbcsdeyuh" opt; do
    case "$opt" in
        v) VERSION=$OPTARG; VERSION_PINNED=1 ;;
        t) TARGET_DIR=$OPTARG ;;
        p) PORT=$OPTARG ;;
        a) WALLET=1; ADDRESS_TYPE=$OPTARG; EXPLICIT_WALLET_FLAG=1 ;;
        n) NOTIFY_WEBHOOK=$OPTARG ;;
        w) WALLET=1; EXPLICIT_WALLET_FLAG=1 ;;
        l) WALLET=1; LEGACY_WALLET=1; EXPLICIT_WALLET_FLAG=1 ;;
        k) WALLET=1; STAKING=1; EXPLICIT_WALLET_FLAG=1 ;;
        b) FORCE_BUILD=1 ;;
        c) UPDATE_CHECK=1 ;;
        s) STATUS_CHECK=1 ;;
        d) DASHBOARD=1 ;;
        e) BACKUP=1 ;;
        y) ASSUME_YES=1 ;;
        u) UNINSTALL=1 ;;
        h) usage; exit 0 ;;
        ?) usage >&2; exit 1 ;;
    esac
done

if [ "$DASHBOARD" -eq 1 ]; then
    run_dashboard
fi

if [ "$STATUS_CHECK" -eq 1 ]; then
    print_status
fi

if [ "$BACKUP" -eq 1 ]; then
    backup_wallet
fi

if [ "$UNINSTALL" -eq 1 ]; then
    if [ "$ASSUME_YES" -ne 1 ]; then
        printf "%sThis will stop MateableCoin Core and remove %s. Continue? (y/n)%s " "$RED" "$TARGET_DIR" "$RESET"
        read -r answer < /dev/tty
        [ "$answer" != "y" ] && exit 0
    fi
    uninstall
    exit 0
fi

if [ "$UPDATE_CHECK" -eq 1 ]; then
    print_banner
    check_for_update
fi

print_banner
run_wizard
resolve_version
print_info "Installing MateableCoin Core $VERSION into $TARGET_DIR"
[ "$WALLET" -eq 1 ] && print_info "Wallet: enabled" || print_info "Wallet: disabled (relay node)"

mkdir -p "$TARGET_DIR"

if [ "$FORCE_BUILD" -eq 1 ] || ! install_prebuilt_binary; then
    build_from_source
fi

write_config
install_systemd_service
install_logrotate
open_firewall
setup_wallet
check_reachability
print_readme
print_success "Installation complete."
