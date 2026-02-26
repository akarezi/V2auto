#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  V2auto Installer  |  https://github.com/akarezi/V2auto
#  Platforms : Termux (Android)  ·  Ubuntu / Debian (server)
#  Usage     : bash install.sh
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── ANSI colors ───────────────────────────────────────────────────────────────
R='\033[0m'        # reset
BD='\033[1m'       # bold
CY='\033[0;36m'    # cyan
GN='\033[0;32m'    # green
YL='\033[0;33m'    # yellow
RD='\033[0;31m'    # red
DM='\033[2m'       # dim

# ── Detect platform ───────────────────────────────────────────────────────────
IS_TERMUX=false
if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d /data/data/com.termux ]]; then
    IS_TERMUX=true
fi

# CPU architecture → xray asset name suffix
case "$(uname -m)" in
    aarch64|arm64) _ARCH="arm64-v8a" ;;
    armv7l|armv8l) _ARCH="arm32-v7a" ;;
    x86_64)        _ARCH="64"        ;;
    i386|i686)     _ARCH="32"        ;;
    *)             _ARCH="64"        ;;
esac

# ── Install directory ─────────────────────────────────────────────────────────
if $IS_TERMUX; then
    INSTALL_DIR="$HOME/v2auto"
else
    # On Linux, prefer running as the invoking user (not root's home)
    REAL_USER="${SUDO_USER:-$(whoami)}"
    REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || eval echo "~$REAL_USER")
    INSTALL_DIR="$REAL_HOME/v2auto"
fi

# ── Helper functions ──────────────────────────────────────────────────────────
_info()  { echo -e "  ${CY}→${R} $*"; }
_ok()    { echo -e "  ${GN}✓${R} $*"; }
_warn()  { echo -e "  ${YL}⚠${R} $*"; }
_err()   { echo -e "  ${RD}✗${R} $*" >&2; }
_step()  { echo -e "\n${BD}${CY}┌─ $* ─────────────────────────────────────────${R}"; }
_line()  { echo -e "${CY}${DM}──────────────────────────────────────────────────────────────${R}"; }

_ask() {
    # _ask "Question" default(y/n) → returns 0=yes 1=no
    local q="$1" def="${2:-y}" hint
    [[ "$def" == "y" ]] && hint="${BD}Y${R}/n" || hint="y/${BD}N${R}"
    local ans
    read -rp "  ${YL}?${R} $q [${hint}] " ans </dev/tty
    ans="${ans:-$def}"
    [[ "${ans,,}" == "y" ]]
}

_dl() {
    # _dl <url> <dest>
    local url="$1" dest="$2"
    local tmp="${dest}.tmp"
    if command -v curl &>/dev/null; then
        curl -fsSL --retry 3 --retry-delay 2 --progress-bar -o "$tmp" "$url" && mv "$tmp" "$dest"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress --tries=3 -O "$tmp" "$url" && mv "$tmp" "$dest"
    else
        _err "Neither curl nor wget found."
        exit 1
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${CY}${BD}"
echo "  ██╗   ██╗██████╗  █████╗ ██╗   ██╗████████╗ ██████╗ "
echo "  ██║   ██║╚════██╗██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗"
echo "  ██║   ██║ █████╔╝███████║██║   ██║   ██║   ██║   ██║"
echo "  ╚██╗ ██╔╝██╔═══╝ ██╔══██║██║   ██║   ██║   ██║   ██║"
echo "   ╚████╔╝ ███████╗██║  ██║╚██████╔╝   ██║   ╚██████╔╝"
echo "    ╚═══╝  ╚══════╝╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ "
echo -e "${R}"
echo -e "  ${DM}Auto v2ray config tester & proxy manager${R}"
echo -e "  ${DM}https://github.com/akarezi/V2auto${R}"
echo ""
_line
echo -e "  Platform : $( $IS_TERMUX && echo "Termux (Android) — arch: $(uname -m)" || echo "Linux ($(uname -m)) — user: ${REAL_USER:-$(whoami)}" )"
echo -e "  Directory: ${BD}$INSTALL_DIR${R}"
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

# Pick pip executable
PIP=""
for _c in pip3 pip; do
    command -v "$_c" &>/dev/null && PIP="$_c" && break
done
[[ -z "$PIP" ]] && { _err "pip not found."; exit 1; }

# --break-system-packages needed on Python ≥ 3.11 Debian-style installs
PIP_EXTRA=""
if ! $IS_TERMUX; then
    python3 -c "import sys; exit(0 if sys.version_info>=(3,11) else 1)" 2>/dev/null \
        && PIP_EXTRA="--break-system-packages"
fi

for _pkg in flask aiohttp requests rich questionary; do
    _mod="${_pkg//-/_}"
    if python3 -c "import $_mod" 2>/dev/null; then
        _ok "$_pkg"
    else
        _info "Installing $_pkg..."
        # shellcheck disable=SC2086
        $PIP install -q $PIP_EXTRA "$_pkg" && _ok "$_pkg" || _warn "Could not install $_pkg"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Create install directory
# ══════════════════════════════════════════════════════════════════════════════
_step "Creating install directory"

mkdir -p "$INSTALL_DIR"
_ok "$INSTALL_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Download project Python files  (always replace)
# ══════════════════════════════════════════════════════════════════════════════
_step "Downloading project files (always updated)"

RAW="https://raw.githubusercontent.com/akarezi/V2auto/main"

for _f in v2auto.py v2web.py; do
    _info "Downloading $_f..."
    _dl "$RAW/$_f" "$INSTALL_DIR/$_f"
    _ok "$_f  ${DM}($(du -h "$INSTALL_DIR/$_f" | cut -f1))${R}"
done

# Optional: dashboard HTML (not always in repo)
if _dl "$RAW/v2auto_dashboard.html" "$INSTALL_DIR/v2auto_dashboard.html" 2>/dev/null; then
    _ok "v2auto_dashboard.html"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — xray binary
# ══════════════════════════════════════════════════════════════════════════════
_step "xray binary"

XRAY="$INSTALL_DIR/xray"
_INSTALL_XRAY=false

if [[ -x "$XRAY" ]]; then
    _CUR=$("$XRAY" version 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "?")
    _ok "xray already installed  ${DM}(v$_CUR)${R}"
    _ask "Update xray to the latest version?" "n" && _INSTALL_XRAY=true || true
else
    _info "xray not found — will download."
    _INSTALL_XRAY=true
fi

if $_INSTALL_XRAY; then
    _info "Fetching latest xray release info..."
    _VER_JSON=$(mktemp)
    _dl "https://api.github.com/repos/XTLS/Xray-core/releases/latest" "$_VER_JSON"
    XRAY_VER=$(python3 -c "import json; d=json.load(open('$_VER_JSON')); print(d['tag_name'])" 2>/dev/null || echo "v25.3.6")
    rm -f "$_VER_JSON"
    _info "Latest version: $XRAY_VER"

    # Build zip name:  Xray-android-arm64-v8a.zip  /  Xray-linux-64.zip
    if $IS_TERMUX; then
        XRAY_ZIP="Xray-android-${_ARCH}.zip"
        # arm64-v8a stays; 64/32 not valid for android → fallback
        [[ "$_ARCH" == "64" ]] && XRAY_ZIP="Xray-android-arm64-v8a.zip"
        [[ "$_ARCH" == "32" ]] && XRAY_ZIP="Xray-android-arm32-v7a.zip"
    else
        XRAY_ZIP="Xray-linux-${_ARCH}.zip"
        # arm variants keep suffix as-is: arm64-v8a → Xray-linux-arm64-v8a.zip
    fi

    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/${XRAY_ZIP}"
    _info "Downloading $XRAY_ZIP..."
    _dl "$XRAY_URL" "/tmp/${XRAY_ZIP}"

    _info "Extracting..."
    _TMP_X=$(mktemp -d)
    unzip -o -q "/tmp/${XRAY_ZIP}" -d "$_TMP_X"
    # The binary may be named 'xray' or 'xray.exe'
    _BIN=$(find "$_TMP_X" -maxdepth 2 -name "xray" -not -name "*.json" | head -1)
    [[ -z "$_BIN" ]] && _BIN=$(find "$_TMP_X" -maxdepth 2 -type f -perm /111 | head -1)
    if [[ -n "$_BIN" ]]; then
        cp "$_BIN" "$XRAY"
        chmod +x "$XRAY"
        _VER_OUT=$("$XRAY" version 2>/dev/null | head -1 || echo "installed")
        _ok "xray  ${DM}($XRAY_VER)${R}"
    else
        _err "Could not find xray binary in archive. Try manual install:"
        _err "  $XRAY_URL"
    fi
    rm -rf "$_TMP_X" "/tmp/${XRAY_ZIP}"
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Geo data files
# ══════════════════════════════════════════════════════════════════════════════
_step "Geo data files  ${DM}(geoip.dat / geosite.dat)${R}"

GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"

for _gf in geoip.dat geosite.dat; do
    _DEST="$INSTALL_DIR/$_gf"
    if [[ -f "$_DEST" ]]; then
        _SZ=$(du -h "$_DEST" | cut -f1)
        _ok "$_gf  ${DM}(${_SZ} — already exists)${R}"
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

# Determine shell RC files to patch
RC_FILES=()
if $IS_TERMUX; then
    RC_FILES+=("$HOME/.bashrc")
    [[ -f "$HOME/.bash_profile" ]] && RC_FILES+=("$HOME/.bash_profile")
else
    RC_FILES+=("$REAL_HOME/.bashrc")
    [[ -f "$REAL_HOME/.zshrc"      ]] && RC_FILES+=("$REAL_HOME/.zshrc")
    [[ -f "$REAL_HOME/.bash_profile" ]] && RC_FILES+=("$REAL_HOME/.bash_profile")
fi

V_CMD="cd \"$INSTALL_DIR\" && python3 v2web.py"
ALIAS_BLOCK="
# >>> v2auto <<<
alias v='$V_CMD'
# <<< v2auto <<<"

for _rc in "${RC_FILES[@]}"; do
    # Remove any previous v2auto block
    if [[ -f "$_rc" ]]; then
        # portable sed: remove block between markers
        sed -i '/# >>> v2auto <<</,/# <<< v2auto <<</d' "$_rc" 2>/dev/null || true
    fi
    touch "$_rc"
    echo "$ALIAS_BLOCK" >> "$_rc"
    _ok "alias added to $_rc"
done

# Also install a standalone script so 'v' works even in non-interactive shells
if $IS_TERMUX; then
    _BIN_DIR="$PREFIX/bin"
else
    _BIN_DIR="/usr/local/bin"
fi

cat > "$_BIN_DIR/v" << SCRIPT_EOF
#!/usr/bin/env bash
cd "$INSTALL_DIR" || exit 1
exec python3 v2web.py "\$@"
SCRIPT_EOF
chmod +x "$_BIN_DIR/v"
_ok "'v' command installed to $_BIN_DIR/v"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Termux: auto-start option
# ══════════════════════════════════════════════════════════════════════════════
if $IS_TERMUX; then
    _step "Termux auto-start"
    echo ""
    echo -e "  ${DM}When enabled, V2auto starts automatically every time${R}"
    echo -e "  ${DM}you open Termux (runs in background).${R}"
    echo ""

    if _ask "Auto-start V2auto when Termux opens?" "n"; then
        _RC="$HOME/.bashrc"
        # Remove old autostart block
        sed -i '/# >>> v2auto-autostart <<</,/# <<< v2auto-autostart <<</d' "$_RC" 2>/dev/null || true

        cat >> "$_RC" << 'AUTOEOF'

# >>> v2auto-autostart <<<
if [[ $- == *i* ]] && [[ -z "${V2AUTO_STARTED:-}" ]]; then
    export V2AUTO_STARTED=1
    (cd "V2AUTO_DIR" && python3 v2web.py > /tmp/v2auto.log 2>&1 &)
    echo -e "\033[0;36m⚡ V2auto started → http://127.0.0.1:8080\033[0m"
fi
# <<< v2auto-autostart <<<
AUTOEOF
        # Substitute actual path
        sed -i "s|V2AUTO_DIR|$INSTALL_DIR|g" "$HOME/.bashrc"
        _ok "Auto-start enabled — V2auto will launch on every Termux open"
    else
        _info "Auto-start skipped."
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — systemd service  (Linux only)
# ══════════════════════════════════════════════════════════════════════════════
if ! $IS_TERMUX; then
    _step "systemd service  ${DM}(optional — Linux only)${R}"
    echo ""
    echo -e "  ${DM}A systemd service makes V2auto start automatically on boot${R}"
    echo -e "  ${DM}and restart if it crashes.${R}"
    echo ""

    if ! command -v systemctl &>/dev/null; then
        _warn "systemd not found — skipping service setup."
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
            _warn "Service may not have started yet — check: systemctl status $SVC"
        fi

        echo ""
        echo -e "  ${DM}Service commands:${R}"
        echo -e "  ${CY}systemctl status  $SVC${R}"
        echo -e "  ${CY}systemctl stop    $SVC${R}"
        echo -e "  ${CY}systemctl restart $SVC${R}"
        echo -e "  ${CY}journalctl -u     $SVC -f${R}"
    else
        _info "Service setup skipped."
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 10 — Final verification
# ══════════════════════════════════════════════════════════════════════════════
_step "Verifying installation"

echo ""
PASS=0; FAIL=0
_check_file() {
    local label="$1" path="$2" required="${3:-true}"
    if [[ -f "$path" ]]; then
        _ok "$label  ${DM}($(du -h "$path" | cut -f1))${R}"
        PASS=$((PASS+1))
    elif [[ -x "$path" ]]; then
        _ok "$label  ${DM}($(du -h "$path" | cut -f1))${R}"
        PASS=$((PASS+1))
    else
        if $required; then
            _err "$label — NOT FOUND  ${DM}($path)${R}"
            FAIL=$((FAIL+1))
        else
            _warn "$label — not found  ${DM}(optional, will be fetched on first run)${R}"
        fi
    fi
}

_check_file "v2auto.py"   "$INSTALL_DIR/v2auto.py"
_check_file "v2web.py"    "$INSTALL_DIR/v2web.py"
_check_file "xray"        "$INSTALL_DIR/xray"
_check_file "geoip.dat"   "$INSTALL_DIR/geoip.dat"   false
_check_file "geosite.dat" "$INSTALL_DIR/geosite.dat"  false

echo ""
_check_file "'v' command"  "$_BIN_DIR/v"

# ══════════════════════════════════════════════════════════════════════════════
# Done
# ══════════════════════════════════════════════════════════════════════════════
echo ""
_line
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GN}${BD}Installation complete!  (${PASS} files OK)${R}"
else
    echo -e "  ${YL}${BD}Installation finished with ${FAIL} issue(s).${R}"
fi
echo ""
echo -e "  ${BD}Quick start:${R}"
echo ""
echo -e "  ${CY}${BD}v${R}                         — launch V2auto"
echo -e "  ${DM}or: cd $INSTALL_DIR && python3 v2web.py${R}"
echo ""
echo -e "  ${DM}Then open in browser:  ${R}${BD}http://localhost:8080${R}"
echo ""
if [[ "${RC_FILES[0]+_}" ]]; then
    echo -e "  ${DM}Apply alias now:  source ${RC_FILES[0]}${R}"
fi
echo ""
_line
echo ""

# Apply alias in the current shell session immediately
# shellcheck disable=SC1090
source "${RC_FILES[0]:-$HOME/.bashrc}" 2>/dev/null || true
