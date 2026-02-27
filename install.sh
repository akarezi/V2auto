#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  V2auto Installer  |  https://github.com/akarezi/V2auto
#  Platforms : Termux (Android)  ·  Ubuntu / Debian (server)
#  Usage     : bash install.sh
# ══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── ANSI colors ───────────────────────────────────────────────────────────────
R=$'\033[0m'
BD=$'\033[1m'
CY=$'\033[0;36m'
GN=$'\033[0;32m'
YL=$'\033[0;33m'
RD=$'\033[0;31m'
DM=$'\033[2m'
BG_RD=$'\033[41m'
BG_CY=$'\033[46m'

# ── Detect platform ───────────────────────────────────────────────────────────
IS_TERMUX=false
_OS_NAME=$(uname -o 2>/dev/null || uname -s)
if [[ -n "${TERMUX_VERSION:-}" ]] || [[ "$_OS_NAME" == "Android" ]]; then
    IS_TERMUX=true
fi

SVC="v2auto"
SVC_FILE="/etc/systemd/system/${SVC}.service"

# ── Install directory ─────────────────────────────────────────────────────────
if $IS_TERMUX; then
    INSTALL_DIR="$HOME/v2auto"
    _BIN_DIR="$PREFIX/bin"
else
    REAL_USER="${SUDO_USER:-$(whoami)}"
    if command -v getent &>/dev/null; then
        REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)
    fi
    [[ -z "${REAL_HOME:-}" ]] && REAL_HOME=$(eval echo "~$REAL_USER")
    INSTALL_DIR="$REAL_HOME/v2auto"
    _BIN_DIR="/usr/local/bin"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
_info()  { echo -e "  ${CY}→${R} $*"; }
_ok()    { echo -e "  ${GN}✓${R} $*"; }
_warn()  { echo -e "  ${YL}⚠${R} $*"; }
_err()   { echo -e "  ${RD}✗${R} $*" >&2; }
_step()  { echo -e "\n${BD}${CY}┌─ $* ─────────────────────────────────────────${R}"; }
_line()  { echo -e "${DM}──────────────────────────────────────────────────────────────${R}"; }

_ask() {
    local q="$1" def="${2:-y}"
    local hint
    [[ "$def" == "y" ]] && hint="${BD}Y${R}/n" || hint="y/${BD}N${R}"
    printf "  %b?%b %s [%b] " "$YL" "$R" "$q" "$hint" >/dev/tty
    local ans; read -r ans </dev/tty
    ans="${ans:-$def}"
    [[ "${ans,,}" == "y" ]]
}

# choice menu: _choice "title" "opt1" "opt2" ... → sets $CHOICE (1-based)
_choice() {
    local title="$1"; shift
    local opts=("$@")
    echo "" >/dev/tty
    printf "  %b%s%b\n" "$BD" "$title" "$R" >/dev/tty
    echo "" >/dev/tty
    local i=1
    for opt in "${opts[@]}"; do
        printf "    %b[%d]%b  %s\n" "$CY$BD" "$i" "$R" "$opt" >/dev/tty
        ((i++))
    done
    echo "" >/dev/tty
    while true; do
        printf "  %b→%b Choose [1-%d]: " "$YL" "$R" "${#opts[@]}" >/dev/tty
        local ans; read -r ans </dev/tty
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
            CHOICE=$ans
            return 0
        fi
        printf "  %bInvalid choice — enter a number between 1 and %d%b\n" \
               "$YL" "${#opts[@]}" "$R" >/dev/tty
    done
}

_dl() {
    local url="$1" dest="$2"
    local tmp="${dest}.tmp"; local _rc=1
    rm -f "$tmp"
    if command -v curl &>/dev/null; then
        curl -L -f --retry 3 --retry-delay 2 -# -o "$tmp" "$url" 2>/dev/tty
        _rc=$?
    elif command -v wget &>/dev/null; then
        wget --tries=3 -O "$tmp" "$url" 2>/dev/tty; _rc=$?
    else
        _err "Neither curl nor wget found."; return 1
    fi
    if [[ $_rc -eq 0 ]] && [[ -s "$tmp" ]]; then mv "$tmp" "$dest"; return 0; fi
    rm -f "$tmp"; _err "Download failed: $url"; return 1
}

_dl_q() {
    local url="$1" dest="$2"
    local tmp="${dest}.tmp"; local _rc=1
    rm -f "$tmp"
    if command -v curl &>/dev/null; then
        curl -L -f -s --retry 2 --retry-delay 1 -o "$tmp" "$url" 2>/dev/null; _rc=$?
    elif command -v wget &>/dev/null; then
        wget -q --tries=2 -O "$tmp" "$url" 2>/dev/null; _rc=$?
    else
        _err "Neither curl nor wget found."; return 1
    fi
    if [[ $_rc -eq 0 ]] && [[ -s "$tmp" ]]; then mv "$tmp" "$dest"; return 0; fi
    rm -f "$tmp"; return 1
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

# ══════════════════════════════════════════════════════════════════════════════
# PRE-FLIGHT — Detect existing installation
# ══════════════════════════════════════════════════════════════════════════════

MODE="install"   # install | update | uninstall

_detect_existing() {
    local found=false
    local svc_running=false
    local svc_enabled=false
    local files_exist=false
    local autostart_exist=false

    # Check systemd service (Linux only)
    if ! $IS_TERMUX && command -v systemctl &>/dev/null; then
        if [[ -f "$SVC_FILE" ]]; then
            found=true
            systemctl is-active  --quiet "$SVC" 2>/dev/null && svc_running=true || true
            systemctl is-enabled --quiet "$SVC" 2>/dev/null && svc_enabled=true || true
        fi
    fi

    # Check Termux autostart block
    if $IS_TERMUX && grep -q "v2auto-autostart" "$HOME/.bashrc" 2>/dev/null; then
        found=true
        autostart_exist=true
    fi

    # Check install directory
    if [[ -f "$INSTALL_DIR/v2auto.py" ]] || [[ -f "$INSTALL_DIR/v2web.py" ]]; then
        found=true
        files_exist=true
    fi

    $found || return 1

    # ── Show existing install status ──────────────────────────────────────────
    echo ""
    echo -e "  ${YL}${BD}⚠  Existing V2auto installation detected!${R}"
    echo ""

    if [[ -f "$INSTALL_DIR/v2auto.py" ]]; then
        local ver
        ver=$(grep -m1 'version\s*=' "$INSTALL_DIR/v2auto.py" 2>/dev/null \
              | grep -oE '"[^"]+"' | tr -d '"' || echo "unknown")
        echo -e "  ${DM}Files    :${R} $INSTALL_DIR"
    fi

    if ! $IS_TERMUX && [[ -f "$SVC_FILE" ]]; then
        if $svc_running; then
            echo -e "  ${DM}Service  :${R} ${GN}● running${R}  (${SVC})"
        else
            echo -e "  ${DM}Service  :${R} ${RD}● stopped${R}  (${SVC})"
        fi
        $svc_enabled && \
            echo -e "  ${DM}On boot  :${R} ${GN}enabled${R}" || \
            echo -e "  ${DM}On boot  :${R} ${YL}disabled${R}"
    fi

    if $IS_TERMUX && $autostart_exist; then
        echo -e "  ${DM}Auto-start:${R} ${GN}enabled${R}"
    fi

    if [[ -x "$INSTALL_DIR/xray" ]]; then
        local xver
        xver=$("$INSTALL_DIR/xray" version 2>/dev/null | head -1 \
               | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
        echo -e "  ${DM}xray     :${R} v${xver}"
    fi

    echo ""
    _line

    # ── Ask what to do ────────────────────────────────────────────────────────
    _choice "What would you like to do?" \
        "Update  — keep data, update scripts & optionally xray" \
        "Reinstall — clean install (removes all files, keeps geo data)" \
        "Uninstall — remove everything and exit"

    case $CHOICE in
        1) MODE="update"    ;;
        2) MODE="reinstall" ;;
        3) MODE="uninstall" ;;
    esac

    return 0
}

_do_uninstall() {
    echo ""
    echo -e "  ${RD}${BD}This will remove V2auto completely.${R}"
    echo -e "  ${DM}The following will be deleted:${R}"
    echo -e "  ${DM}  • $INSTALL_DIR  (all files)${R}"
    ! $IS_TERMUX && [[ -f "$SVC_FILE" ]] && \
        echo -e "  ${DM}  • systemd service ($SVC_FILE)${R}"
    [[ -f "$_BIN_DIR/v" ]] && \
        echo -e "  ${DM}  • $_BIN_DIR/v${R}"
    echo ""

    if ! _ask "Are you sure you want to uninstall?" "n"; then
        echo ""
        _info "Uninstall cancelled."
        exit 0
    fi

    _step "Uninstalling V2auto"

    # Stop & disable service
    if ! $IS_TERMUX && command -v systemctl &>/dev/null; then
        if [[ -f "$SVC_FILE" ]]; then
            _info "Stopping service..."
            systemctl stop    "$SVC" 2>/dev/null || true
            systemctl disable "$SVC" 2>/dev/null || true
            rm -f "$SVC_FILE"
            systemctl daemon-reload 2>/dev/null || true
            _ok "systemd service removed"
        fi
    fi

    # Remove Termux autostart block
    if $IS_TERMUX; then
        sed -i '/# >>> v2auto-autostart <<</,/# <<< v2auto-autostart <<</d' \
            "$HOME/.bashrc" 2>/dev/null || true
        _ok "Auto-start removed"
    fi

    # Remove alias from shell rc files
    for _rc in "$HOME/.bashrc" "$HOME/.bash_profile" \
               "${REAL_HOME:-$HOME}/.zshrc" "${REAL_HOME:-$HOME}/.profile"; do
        [[ -f "$_rc" ]] && \
            sed -i '/# >>> v2auto <<</,/# <<< v2auto <<</d' "$_rc" 2>/dev/null || true
    done
    _ok "Shell aliases removed"

    # Remove 'v' command
    if [[ -f "$_BIN_DIR/v" ]]; then
        rm -f "$_BIN_DIR/v"
        _ok "'v' command removed"
    fi

    # Remove install directory
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        _ok "Directory removed: $INSTALL_DIR"
    fi

    echo ""
    _line
    echo ""
    echo -e "  ${GN}${BD}V2auto has been uninstalled successfully.${R}"
    echo ""
    _line
    echo ""
    exit 0
}

_do_stop_service() {
    # Stop running service/process before update/reinstall
    if ! $IS_TERMUX && command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet "$SVC" 2>/dev/null; then
            _info "Stopping service..."
            systemctl stop "$SVC" 2>/dev/null || true
            _ok "Service stopped"
        fi
    fi
}

_do_clean_files() {
    # Reinstall mode: remove all files except geo data
    _info "Removing existing files..."
    local keep_geo=()
    [[ -f "$INSTALL_DIR/geoip.dat"   ]] && keep_geo+=("$INSTALL_DIR/geoip.dat")
    [[ -f "$INSTALL_DIR/geosite.dat" ]] && keep_geo+=("$INSTALL_DIR/geosite.dat")
    [[ -f "$INSTALL_DIR/v2auto_uuid.txt" ]] && keep_geo+=("$INSTALL_DIR/v2auto_uuid.txt")

    # Move geo files out temporarily
    local _tmp_geo
    _tmp_geo=$(mktemp -d)
    for f in "${keep_geo[@]}"; do
        cp "$f" "$_tmp_geo/" 2>/dev/null || true
    done

    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    # Restore geo files
    for f in "${keep_geo[@]}"; do
        local bn
        bn=$(basename "$f")
        [[ -f "$_tmp_geo/$bn" ]] && cp "$_tmp_geo/$bn" "$INSTALL_DIR/" && \
            _ok "Kept: $bn"
    done
    rm -rf "$_tmp_geo"
    _ok "Clean slate ready"
}

# ── Run pre-flight check ──────────────────────────────────────────────────────
if _detect_existing; then
    case "$MODE" in
        uninstall)
            _do_uninstall
            ;;
        reinstall)
            echo ""
            _step "Preparing clean reinstall"
            _do_stop_service
            _do_clean_files
            ;;
        update)
            echo ""
            _step "Preparing update"
            _do_stop_service
            ;;
    esac
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — System packages
# ══════════════════════════════════════════════════════════════════════════════
_step "System packages"

if $IS_TERMUX; then
    _info "Updating Termux package list..."
    pkg update -y -q 2>/dev/null || true
    for _p in python python-pip curl wget unzip; do
        if command -v "${_p%%-*}" &>/dev/null; then _ok "$_p"
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
            if dpkg -s "$_p" &>/dev/null 2>&1; then _ok "$_p"
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
for _c in pip3 pip; do command -v "$_c" &>/dev/null && PIP="$_c" && break; done
[[ -z "$PIP" ]] && { _err "pip not found."; exit 1; }

PIP_EXTRA=""
if ! $IS_TERMUX; then
    if python3 -c "import sys; exit(0 if sys.version_info>=(3,11) else 1)" 2>/dev/null; then
        PIP_EXTRA="--break-system-packages"
    fi
fi

for _pkg in flask aiohttp requests rich questionary; do
    if python3 -c "import ${_pkg//-/_}" 2>/dev/null; then _ok "$_pkg"
    else
        _info "Installing $_pkg..."
        # shellcheck disable=SC2086
        $PIP install -q $PIP_EXTRA "$_pkg" && _ok "$_pkg" || _warn "Could not install $_pkg"
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Create install directory
# ══════════════════════════════════════════════════════════════════════════════
_step "Install directory"

mkdir -p "$INSTALL_DIR"
_ok "$INSTALL_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Download project files  (always replace)
# ══════════════════════════════════════════════════════════════════════════════
_step "Downloading project files"

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
    _XRAY_VER_OUT=$("$XRAY" version 2>&1 | head -1 || true)
    if echo "$_XRAY_VER_OUT" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
        _CUR=$(echo "$_XRAY_VER_OUT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        _ok "xray already installed  ${DM}(v${_CUR})${R}"
    else
        _warn "xray exists but may not work: $( file "$XRAY" 2>/dev/null | cut -d: -f2 | xargs )"
        _INSTALL_XRAY=true
    fi
    [[ "$MODE" == "update" || "$MODE" == "reinstall" ]] && \
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
    XRAY_TMP="${TMPDIR:-/tmp}/${XRAY_ZIP}"
    _info "Downloading ${XRAY_ZIP}..."
    _dl "$XRAY_URL" "$XRAY_TMP"

    _info "Extracting..."
    _TMP_X=$(mktemp -d)
    unzip -o -q "$XRAY_TMP" -d "$_TMP_X"
    _BIN=$(find "$_TMP_X" -maxdepth 3 -type f -name "xray" ! -name "*.json" | head -1)
    [[ -z "$_BIN" ]] && \
        _BIN=$(find "$_TMP_X" -maxdepth 3 -type f -perm /111 ! -name "*.sh" | head -1)

    if [[ -n "$_BIN" ]]; then
        cp "$_BIN" "$XRAY"; chmod +x "$XRAY"
        _ok "xray installed  ${DM}(${XRAY_VER})${R}"
    else
        _err "Could not find xray binary in archive."
        _err "Manual: $XRAY_URL"
    fi
    rm -rf "$_TMP_X" "$XRAY_TMP"
fi

# ── Verify xray runs ──────────────────────────────────────────────────────────
if [[ -x "$XRAY" ]]; then
    _XRAY_TEST=$("$XRAY" version 2>&1 || true)
    _XRAY_FIRST=$(echo "$_XRAY_TEST" | head -1)
    if echo "$_XRAY_FIRST" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
        _ok "xray verified  ${DM}(${_XRAY_FIRST})${R}"
    else
        _warn "xray binary may not be compatible!"
        echo ""
        file "$XRAY" 2>/dev/null | sed 's/^/    /'
        echo -e "  ${DM}System: $(uname -m) / $(uname -s)${R}"
        if command -v ldd &>/dev/null; then
            ldd "$XRAY" 2>/dev/null | grep "not found" | sed 's/^/    /' || true
        fi
        _warn "Download correct build: https://github.com/XTLS/Xray-core/releases"
    fi
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
# STEP 7 — 'v' command
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

ALIAS_BLOCK="
# >>> v2auto <<<
alias v='cd \"$INSTALL_DIR\" && python3 v2web.py'
# <<< v2auto <<<"

for _rc in "${RC_FILES[@]}"; do
    sed -i '/# >>> v2auto <<</,/# <<< v2auto <<</d' "$_rc" 2>/dev/null || true
    touch "$_rc"
    printf '%s\n' "$ALIAS_BLOCK" >> "$_rc"
    _ok "alias → $_rc"
done

mkdir -p "$_BIN_DIR" 2>/dev/null || true
cat > "$_BIN_DIR/v" << SCRIPT_EOF
#!/usr/bin/env bash
cd "$INSTALL_DIR" || exit 1
exec python3 v2web.py "\$@"
SCRIPT_EOF
chmod +x "$_BIN_DIR/v"
_ok "'v' command → $_BIN_DIR/v"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Termux auto-start
# ══════════════════════════════════════════════════════════════════════════════
if $IS_TERMUX; then
    _step "Termux auto-start"
    echo ""
    # Remove old block first (clean slate on update/reinstall)
    sed -i '/# >>> v2auto-autostart <<</,/# <<< v2auto-autostart <<</d' \
        "$HOME/.bashrc" 2>/dev/null || true

    if _ask "Auto-start V2auto when Termux opens?" "n"; then
        cat >> "$HOME/.bashrc" << AUTOEOF

# >>> v2auto-autostart <<<
if [[ \$- == *i* ]] && [[ -z "\${V2AUTO_STARTED:-}" ]]; then
    export V2AUTO_STARTED=1
    (cd "$INSTALL_DIR" && python3 v2web.py > "${TMPDIR:-/tmp}/v2auto.log" 2>&1 &)
    echo -e "\033[0;36m[*] V2auto started -> http://127.0.0.1:8080\033[0m"
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
    _step "systemd service  (Linux only)"
    echo ""

    if ! command -v systemctl &>/dev/null; then
        _warn "systemd not available — skipping."
    else
        # On update: service file already exists → just restart
        if [[ "$MODE" == "update" ]] && [[ -f "$SVC_FILE" ]]; then
            _info "Restarting existing service..."
            systemctl daemon-reload
            systemctl restart "$SVC"
            sleep 2
            if systemctl is-active --quiet "$SVC"; then
                _ok "Service restarted and running"
            else
                _warn "Service may not have started — check: systemctl status $SVC"
            fi
        else
            # Fresh install or reinstall
            echo -e "  ${DM}Runs V2auto on system boot and restarts it on crash.${R}"
            echo ""
            if _ask "Install V2auto as a systemd service?" "n"; then
                PY3=$(command -v python3)
                cat > "$SVC_FILE" << SVC_EOF
[Unit]
Description=V2auto - Proxy Manager & Config Tester
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
                s                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           