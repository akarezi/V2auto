#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  V2auto Installer  |  https://github.com/akarezi/V2auto
#  Platforms : Termux (Android)  ·  Ubuntu / Debian (server)
#  Usage     : bash install.sh
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── ANSI colors ───────────────────────────────────────────────────────────────
# $'...' syntax ensures escape codes work in both echo -e AND printf/read
R=$'\033[0m'
BD=$'\033[1m'
CY=$'\033[0;36m'
GN=$'\033[0;32m'
YL=$'\033[0;33m'
RD=$'\033[0;31m'
DM=$'\033[2m'

# ── Detect platform ───────────────────────────────────────────────────────────
IS_TERMUX=false
if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d /data/data/com.termux ]]; then
    IS_TERMUX=true
fi

# ── Install directory ─────────────────────────────────────────────────────────
if $IS_TERMUX; then
    INSTALL_DIR="$HOME/v2auto"
else
    REAL_USER="${SUDO_USER:-$(whoami)}"
    REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 \
                || eval echo "~$REAL_USER")
    INSTALL_DIR="$REAL_HOME/v2auto"
fi

# ── Helper functions ──────────────────────────────────────────────────────────
_info()  { echo -e "  ${CY}→${R} $*"; }
_ok()    { echo -e "  ${GN}✓${R} $*"; }
_warn()  { echo -e "  ${YL}⚠${R} $*"; }
_err()   { echo -e "  ${RD}✗${R} $*" >&2; }
_step()  { echo -e "\n${BD}${CY}┌─ $* ─────────────────────────────────────────${R}"; }
_line()  { echo -e "${DM}──────────────────────────────────────────────────────────────${R}"; }

_ask() {
    # _ask "Question" default(y/n) → returns 0=yes / 1=no
    # Uses printf so ANSI codes render correctly (read -p is inconsistent)
    local q="$1" def="${2:-y}"
    local hint
    [[ "$def" == "y" ]] && hint="${BD}Y${R}/n" || hint="y/${BD}N${R}"
    printf "  %b?%b %s [%b] " "$YL" "$R" "$q" "$hint" >/dev/tty
    local ans
    read -r ans </dev/tty
    ans="${ans:-$def}"
    [[ "${ans,,}" == "y" ]]
}

_dl() {
    # _dl <url> <dest>
    # Large files: show progress bar to /dev/tty so it doesn't corrupt stdout
    local url="$1" dest="$2"
    local tmp="${dest}.tmp"
    if command -v curl &>/dev/null; then
        # -L = follow redirects, -f = fail on HTTP error
        # -# = ASCII progress bar (to stderr/tty)
        # Do NOT combine -s with -# (they cancel each other)
        curl -L -f --retry 3 --retry-delay 2 -# \
             -o "$tmp" "$url" 2>/dev/tty \
            && mv "$tmp" "$dest" \
            && return 0
    fi
    if command -v wget &>/dev/null; then
        wget --tries=3 -O "$tmp" "$url" 2>/dev/tty \
            && mv "$tmp" "$dest" \
            && return 0
    fi
    _err "Neither curl nor wget found."; exit 1
}

_dl_q() {
    # _dl_q <url> <dest>
    # Quiet download for small files (API JSON, .py scripts)
    local url="$1" dest="$2"
    local tmp="${dest}.tmp"
    if command -v curl &>/dev/null; then
        curl -L -f -s --retry 3 --retry-delay 2 \
             -o "$tmp" "$url" \
            && mv "$tmp" "$dest" \
            && return 0
    fi
    if command -v wget &>/dev/null; then
        wget -q --tries=3 -O "$tmp" "$url" \
            && mv "$tmp" "$dest" \
            && return 0
    fi
    _err "Neither curl nor wget found."; exit 1
}

# ── Banner ────────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
printf "\n%b" "$CY$BD"
echo "  ██╗   ██╗██████╗  █████╗ ██╗   ██╗████████╗ ██████╗ "
echo "  ██║   ██║╚════██╗██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗"
echo "  ██║   ██║ █████╔╝███████║██║   ██║   ██║   ██║   ██║"
echo "  ╚██╗ ██╔╝██╔═══╝ ██╔══██║██║   ██║   ██║   ██║   ██║"
echo "   ╚████╔╝ ███████╗██║  ██║╚██████╔╝   ██║   ╚██████╔╝"
echo "    ╚═══╝  ╚══════╝╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ "
printf "%b\n" "$R"
echo -e "  ${DM}Auto v2ray config tester & proxy manager${R}"
echo -e "  ${DM}https://github.com/akarezi/V2auto${R}"
echo ""
_line
if $IS_TERMUX; then
    echo -e "  Platform  : Termux (Android)  arch=$(uname -m)"
else
    echo -e "  Platform  : Linux ($(uname -m))  user=${REAL_USER:-$(whoami)}"
fi
echo -e "  Directory : ${BD}$INSTALL_DIR${R}"
_line
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — System packages
# ══════════════════════════════════════════════════════════════════════════════
_step "System packages"

if $IS_TERMUX; then
    _info "Updating Termux package list..."
    pkg update -y -q 2>/dev/null || true
    for _p in python python-pip curl wget unzip; do
        if command -v "${_p%%-*}" &>/dev/null; then
            _ok "$_p"
        else
            _info "Installing $_p..."
            pkg install -y -q "$_p" 2>/dev/null || _warn "Could not install $_p"
        fi
    done
else
    if command -v apt-get &>/dev/null; then
        _info "Updating apt cache..."
        apt-get update -qq 2>/dev/null || true
        for _p in python3 python3-pip curl wget unzip; do
            if dpkg -s "$_p" &>/dev/null 2>&1; then
                _ok "$_p"
            else
                _info "Installing $_p..."
                apt-get install -y -q "$_p" 2>/dev/null || _warn "Could not install $_p"
            fi
        done
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Python packages
# ══════════════════════════════════════════════════════════════════════════════
_step "Python packages"

PIP=""
for _c in pip3 pip; do
    command -v "$_c" &>/dev/null && PIP="$_c" && break
done
[[ -z "$PIP" ]] && { _err "pip not found."; exit 1; }

PIP_EXTRA=""
if ! $IS_TERMUX; then
    python3 -c "import sys; exit(0 if sys.version_info>=(3,11) else 1)" 2>/dev/null \
        && PIP_EXTRA="--break-system-packages" || true
fi

for _pkg in flask aiohttp requests rich questionary; do
    if python3 -c "import ${_pkg//-/_}" 2>/dev/null; then
        _ok "$_pkg"
    else
        _info "Installing $_pkg..."
        # shellcheck disable=SC2086
        $PIP install -q $PIP_EXTRA "$_pkg" \
            && _ok "$_pkg" \
            || _warn "Could not install $_pkg"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Create install directory
# ══════════════════════════════════════════════════════════════════════════════
_step "Creating install directory"

mkdir -p "$INSTALL_DIR"
_ok "$INSTALL_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Download project files  (always replace)
# ══════════════════════════════════════════════════════════════════════════════
_step "Downloading project files (always updated)"

RAW="https://raw.githubusercontent.com/akarezi/V2auto/main"

for _f in v2auto.py v2web.py; do
    _info "Downloading $_f..."
    _dl_q "$RAW/$_f" "$INSTALL_DIR/$_f"
    _ok "$_f  ${DM}($(du -h "$INSTALL_DIR/$_f" | cut -f1))${R}"
done

if _dl_q "$RAW/v2auto_dashboard.html" "$INSTALL_DIR/v2auto_dashboard.html" 2>/dev/null; then
    _ok "v2auto_dashboard.html  ${DM}($(du -h "$INSTALL_DIR/v2auto_dashboard.html" | cut -f1))${R}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — xray binary
# ══════════════════════════════════════════════════════════════════════════════
_step "xray binary"

XRAY="$INSTALL_DIR/xray"
_INSTALL_XRAY=false

if [[ -x "$XRAY" ]]; then
    _CUR=$("$XRAY" version 2>/dev/null | head -1 \
           | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
    _ok "xray already installed  ${DM}(v${_CUR})${R}"
    _ask "Update xray to the latest version?" "n" && _INSTALL_XRAY=true || true
else
    _info "xray not found — will download."
    _INSTALL_XRAY=true
fi

if $_INSTALL_XRAY; then
    _info "Fetching latest xray release info..."
    _VER_JSON="$INSTALL_DIR/.xray_ver.json"
    _dl_q "https://api.github.com/repos/XTLS/Xray-core/releases/latest" "$_VER_JSON"
    XRAY_VER=$(python3 -c \
        "import json; d=json.load(open('$_VER_JSON')); print(d['tag_name'])" \
        2>/dev/null || echo "v25.3.6")
    rm -f "$_VER_JSON"
    _info "Latest version: $XRAY_VER"

    # Build asset filename per platform+arch
    if $IS_TERMUX; then
        case "$(uname -m)" in
            aarch64|arm64) XRAY_ZIP="Xray-android-arm64-v8a.zip" ;;
            armv7l|armv8l) XRAY_ZIP="Xray-android-arm32-v7a.zip" ;;
            *)             XRAY_ZIP="Xray-android-arm64-v8a.zip" ;;
        esac
    else
        case "$(uname -m)" in
            aarch64|arm64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
            armv7l|armv8l) XRAY_ZIP="Xray-linux-arm32-v7a.zip" ;;
            x86_64)        XRAY_ZIP="Xray-linux-64.zip"        ;;
            i386|i686)     XRAY_ZIP="Xray-linux-32.zip"        ;;
            *)             XRAY_ZIP="Xray-linux-64.zip"        ;;
        esac
    fi

    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ZIP}"
    XRAY_TMP="/tmp/${XRAY_ZIP}"
    _info "Downloading ${XRAY_ZIP}..."
    _dl "$XRAY_URL" "$XRAY_TMP"

    _info "Extracting..."
    _TMP_X=$(mktemp -d)
    unzip -o -q "$XRAY_TMP" -d "$_TMP_X"

    _BIN=$(find "$_TMP_X" -maxdepth 3 -type f -name "xray" ! -name "*.json" | head -1)
    [[ -z "$_BIN" ]] && \
        _BIN=$(find "$_TMP_X" -maxdepth 3 -type f -perm /111 ! -name "*.sh" | head -1)

    if [[ -n "$_BIN" ]]; then
        cp "$_BIN" "$XRAY"
        chmod +x "$XRAY"
        _ok "xray installed  ${DM}(${XRAY_VER})${R}"
    else
        _err "Could not find xray binary in archive."
        _err "Manual download: $XRAY_URL"
    fi
    rm -rf "$_TMP_X" "$XRAY_TMP"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Geo data files
# ══════════════════════════════════════════════════════════════════════════════
_step "Geo data files  (geoip.dat / geosite.dat)"

GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"

for _gf in geoip.dat geosite.dat; do
    _DEST="$INSTALL_DIR/$_gf"
    if [[ -f "$_DEST" ]]; then
        _ok "$_gf  ${DM}($(du -h "$_DEST" | cut -f1) — already exists)${R}"
        _ask "Re-download $_gf?" "n" || continue
    else
        _info "$_gf not found — downloading..."
    fi
    _dl "$GEO_BASE/$_gf" "$_DEST"
    _ok "$_gf  ${DM}($(du -h "$_DEST" | cut -f1))${R}"
done

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — 'v' command  (alias + standalone script)
# ══════════════════════════════════════════════════════════════════════════════
_step "Setting up 'v' command"

RC_FILES=()
if $IS_TERMUX; then
    RC_FILES+=("$HOME/.bashrc")
    [[ -f "$HOME/.bash_profile" ]] && RC_FILES+=("$HOME/.bash_profile")
else
    RC_FILES+=("$REAL_HOME/.bashrc")
    [[ -f "$REAL_HOME/.zshrc"        ]] && RC_FILES+=("$REAL_HOME/.zshrc")
    [[ -f "$REAL_HOME/.bash_profile" ]] && RC_FILES+=("$REAL_HOME/.bash_profile")
fi

ALIAS_LINE="alias v='cd \"$INSTALL_DIR\" && python3 v2web.py'"
ALIAS_BLOCK="
# >>> v2auto <<<
$ALIAS_LINE
# <<< v2auto <<<"

for _rc in "${RC_FILES[@]}"; do
    sed -i '/# >>> v2auto <<</,/# <<< v2auto <<</d' "$_rc" 2>/dev/null || true
    touch "$_rc"
    printf '%s\n' "$ALIAS_BLOCK" >> "$_rc"
    _ok "alias added → $_rc"
done

# Standalone executable so 'v' works without sourcing rc
if $IS_TERMUX; then
    _BIN_DIR="$PREFIX/bin"
else
    _BIN_DIR="/usr/local/bin"
fi
mkdir -p "$_BIN_DIR" 2>/dev/null || true

cat > "$_BIN_DIR/v" << SCRIPT_EOF
#!/usr/bin/env bash
cd "$INSTALL_DIR" || exit 1
exec python3 v2web.py "\$@"
SCRIPT_EOF
chmod +x "$_BIN_DIR/v"
_ok "'v' installed → $_BIN_DIR/v"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Termux: auto-start option
# ══════════════════════════════════════════════════════════════════════════════
if $IS_TERMUX; then
    _step "Termux auto-start"
    echo ""
    echo -e "  ${DM}When enabled, V2auto launches in the background${R}"
    echo -e "  ${DM}every time you open a new Termux session.${R}"
    echo ""

    if _ask "Auto-start V2auto when Termux opens?" "n"; then
        _RC="$HOME/.bashrc"
        sed -i '/# >>> v2auto-autostart <<</,/# <<< v2auto-autostart <<</d' "$_RC" 2>/dev/null || true
        cat >> "$_RC" << AUTOEOF

# >>> v2auto-autostart <<<
if [[ \$- == *i* ]] && [[ -z "\${V2AUTO_STARTED:-}" ]]; then
    export V2AUTO_STARTED=1
    (cd "$INSTALL_DIR" && python3 v2web.py > /tmp/v2auto.log 2>&1 &)
    echo -e "\033[0;36m⚡ V2auto started → http://127.0.0.1:8080\033[0m"
fi
# <<< v2auto-autostart <<<
AUTOEOF
        _ok "Auto-start enabled"
    else
        _info "Auto-start skipped."
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — systemd service  (Linux only)
# ══════════════════════════════════════════════════════════════════════════════
if ! $IS_TERMUX; then
    _step "systemd service  (optional — Linux only)"
    echo ""
    echo -e "  ${DM}Runs V2auto on system boot and restarts it on crash.${R}"
    echo ""

    if ! command -v systemctl &>/dev/null; then
        _warn "systemd not available — skipping."
    elif _ask "Install V2auto as a systemd service?" "n"; then
        SVC="v2auto"
        SVC_FILE="/etc/systemd/system/${SVC}.service"
        PY3=$(command -v python3)

        cat > "$SVC_FILE" << SVC_EOF
[Unit]
Description=V2auto — Proxy Manager & Config Tester
Documentation=https://github.com/akarezi/V2auto
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${REAL_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PY3} ${INSTALL_DIR}/v2web.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SVC_EOF

        systemctl daemon-reload
        systemctl enable "$SVC"
        systemctl restart "$SVC"
        sleep 2

        if systemctl is-active --quiet "$SVC"; then
            _ok "Service '${SVC}' is running"
        else
            _warn "Service may not be up yet — check: systemctl status $SVC"
        fi
        echo ""
        echo -e "  ${DM}Manage: systemctl {status|stop|restart} $SVC${R}"
        echo -e "  ${DM}  Logs: journalctl -u $SVC -f${R}"
    else
        _info "Service setup skipped."
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — Final verification
# ══════════════════════════════════════════════════════════════════════════════
_step "Verifying installation"
echo ""

PASS=0
FAIL=0

_check() {
    local label="$1" path="$2" required="${3:-true}"
    if [[ -e "$path" ]]; then
        _ok "$label  ${DM}($(du -h "$path" | cut -f1))${R}"
        PASS=$((PASS + 1))
    else
        if [[ "$required" == "true" ]]; then
            _err "$label — NOT FOUND"
            FAIL=$((FAIL + 1))
        else
            _warn "$label — not found  ${DM}(optional)${R}"
        fi
    fi
}

_check "v2auto.py"   "$INSTALL_DIR/v2auto.py"
_check "v2web.py"    "$INSTALL_DIR/v2web.py"
_check "xray"        "$INSTALL_DIR/xray"
_check "geoip.dat"   "$INSTALL_DIR/geoip.dat"   false
_check "geosite.dat" "$INSTALL_DIR/geosite.dat"  false
_check "'v' command" "$_BIN_DIR/v"

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo ""
_line
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GN}${BD}Installation complete!  (${PASS} files OK)${R}"
else
    echo -e "  ${YL}${BD}Finished with ${FAIL} issue(s) — see above.${R}"
fi
echo ""
echo -e "  ${BD}Quick start:${R}"
echo ""
echo -e "    ${CY}${BD}v${R}   — launch V2auto dashboard"
echo -e "    ${DM}or:  cd $INSTALL_DIR && python3 v2web.py${R}"
echo ""
echo -e "    Open in browser:  ${BD}http://localhost:8080${R}"
echo ""
echo -e "  ${DM}Apply alias in this session:${R}"
echo -e "    ${CY}source ${RC_FILES[0]:-$HOME/.bashrc}${R}"
echo ""
_line
echo ""

# Apply alias in the current shell immediately
# shellcheck disable=SC1090
source "${RC_FILES[0]:-$HOME/.bashrc}" 2>/dev/null || true
