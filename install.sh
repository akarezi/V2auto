#!/usr/bin/env bash
# =============================================================================
# V2Auto Installer v2.2
# - Removes any previous installation cleanly
# - Installs all files directly (no symlinks)
# - Downloads xray into project directory if not found
# - Configures systemd service V2auto
# - Adds /etc/x-ui to service write permissions
# Run as root: sudo bash install.sh
# =============================================================================

set -o nounset
set -o pipefail

readonly INSTALL_DIR="/opt/v2auto"
readonly SERVICE_NAME="V2auto"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Script lives inside the extracted zip folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
_r() { printf '\033[0;31m%s\033[0m\n' "$*"; }
_g() { printf '\033[0;32m%s\033[0m\n' "$*"; }
_y() { printf '\033[0;33m%s\033[0m\n' "$*"; }
_b() { printf '\033[0;34m%s\033[0m\n' "$*"; }

_info() { _g  "[INFO]  $*"; }
_warn() { _y  "[WARN]  $*"; }
_err()  { _r  "[ERROR] $*" >&2; }
_step() { _b  "\n══════  $*  ══════"; }
_die()  { _err "$*"; exit 1; }

# ─── Must run as root ──────────────────────────────────────────
[[ "${EUID}" -eq 0 ]] || _die "Run as root: sudo bash install.sh"

_step "V2Auto Installer v2.2"
echo "Install directory : ${INSTALL_DIR}"
echo "Service name      : ${SERVICE_NAME}"
echo "Source directory  : ${SCRIPT_DIR}"
echo ""

# ─── Step 1: Remove previous installation ──────────────────────
_step "Removing previous installation..."

# Stop and disable old service (any name variants)
for svc in V2auto v2auto v2auto-enterprise; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        _info "Stopping service: ${svc}"
        systemctl stop    "${svc}" 2>/dev/null || true
        systemctl disable "${svc}" 2>/dev/null || true
    fi
    if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
        rm -f "/etc/systemd/system/${svc}.service"
        _info "Removed service file: /etc/systemd/system/${svc}.service"
    fi
done

systemctl daemon-reload 2>/dev/null || true

# Remove old install directory (preserve subs.txt if exists)
if [[ -d "${INSTALL_DIR}" ]]; then
    if [[ -f "${INSTALL_DIR}/subs.txt" ]]; then
        _info "Preserving existing subs.txt"
        cp "${INSTALL_DIR}/subs.txt" "/tmp/v2auto_subs_preserve.txt"
    fi
    rm -rf "${INSTALL_DIR}"
    _info "Removed old installation: ${INSTALL_DIR}"
fi

# Remove old /usr/local/bin/v2auto symlink or binary
rm -f /usr/local/bin/v2auto 2>/dev/null || true

_info "Previous installation cleaned"

# ─── Step 2: System dependencies ───────────────────────────────
_step "Installing system dependencies..."

apt-get update -qq 2>&1 | tail -1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl wget unzip python3 python3-minimal \
    coreutils iproute2 bc procps findutils \
    grep gawk sqlite3 \
    2>/dev/null || _die "apt-get install failed"

_info "Dependencies installed"

# ─── Step 3: Create directory structure ────────────────────────
_step "Creating directory structure..."

mkdir -p \
    "${INSTALL_DIR}/core" \
    "${INSTALL_DIR}/output" \
    "${INSTALL_DIR}/backup" \
    "${INSTALL_DIR}/logs"

_info "Directories created: ${INSTALL_DIR}"

# ─── Step 4: Install files directly (no symlinks) ──────────────
_step "Installing V2Auto files..."

# Verify source files exist
[[ -f "${SCRIPT_DIR}/v2auto.sh" ]]        || _die "v2auto.sh not found in ${SCRIPT_DIR}"
[[ -d "${SCRIPT_DIR}/core" ]]              || _die "core/ directory not found in ${SCRIPT_DIR}"

REQUIRED_MODULES="logger.sh health_monitor.sh input_engine.sh parser_engine.sh test_engine.sh optimizer.sh"
for mod in ${REQUIRED_MODULES}; do
    [[ -f "${SCRIPT_DIR}/core/${mod}" ]] || _die "Missing core module: ${mod}"
done

# Copy main script
cp "${SCRIPT_DIR}/v2auto.sh" "${INSTALL_DIR}/v2auto.sh"
chmod 755 "${INSTALL_DIR}/v2auto.sh"

# Copy core modules
for mod in ${REQUIRED_MODULES}; do
    cp "${SCRIPT_DIR}/core/${mod}" "${INSTALL_DIR}/core/${mod}"
    chmod 644 "${INSTALL_DIR}/core/${mod}"
done

# Copy subs.txt example
if [[ -f "${SCRIPT_DIR}/subs.txt.example" ]]; then
    cp "${SCRIPT_DIR}/subs.txt.example" "${INSTALL_DIR}/subs.txt.example"
fi

_info "Scripts installed to ${INSTALL_DIR}"

# Restore preserved subs.txt
if [[ -f "/tmp/v2auto_subs_preserve.txt" ]]; then
    cp "/tmp/v2auto_subs_preserve.txt" "${INSTALL_DIR}/subs.txt"
    rm -f "/tmp/v2auto_subs_preserve.txt"
    _info "Restored previous subs.txt"
fi

# Create default subs.txt if none exists
if [[ ! -f "${INSTALL_DIR}/subs.txt" ]]; then
    cat > "${INSTALL_DIR}/subs.txt" << 'EOF'
# V2Auto - Subscription Sources
# =====================================================
# Add your subscription URLs or direct configs below.
# Lines starting with # are ignored.
#
# Supported formats:
#   https://your-sub.com/sub?token=YOUR_TOKEN
#   vmess://BASE64_ENCODED_JSON
#   vless://UUID@host:port?security=reality&pbk=KEY#Name
#   trojan://password@host:port?sni=example.com#Name
#   ss://BASE64_OR_METHOD:PASS@host:port#Name
# =====================================================

EOF
    _warn "Created empty subs.txt — ADD YOUR SUBSCRIPTIONS BEFORE STARTING"
fi

# ─── Step 5: Install xray ──────────────────────────────────────
_step "Ensuring xray binary is available..."

XRAY_DEST="${INSTALL_DIR}/xray"
XRAY_FOUND=""

# Check candidates in priority order
if [[ -x "${INSTALL_DIR}/xray" ]]; then
    XRAY_FOUND="${INSTALL_DIR}/xray"
    _info "xray already in project dir: ${XRAY_FOUND}"
elif [[ -x "/usr/local/x-ui/bin/xray" ]]; then
    # Copy from x-ui so v2auto owns its own binary
    cp "/usr/local/x-ui/bin/xray" "${XRAY_DEST}"
    chmod 755 "${XRAY_DEST}"
    XRAY_FOUND="${XRAY_DEST}"
    _info "Copied xray from x-ui: ${XRAY_FOUND}"
elif command -v xray >/dev/null 2>&1; then
    cp "$(command -v xray)" "${XRAY_DEST}"
    chmod 755 "${XRAY_DEST}"
    XRAY_FOUND="${XRAY_DEST}"
    _info "Copied system xray to project dir: ${XRAY_FOUND}"
else
    _warn "xray not found — downloading latest Xray-core..."

    TMPDIR_XRAY="$(mktemp -d)"
    cd "${TMPDIR_XRAY}" || _die "mktemp -d failed"

    XRAY_URL="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
    _info "Downloading: ${XRAY_URL}"

    if curl -sLo Xray-linux-64.zip "${XRAY_URL}" && \
       unzip -q Xray-linux-64.zip xray && \
       mv xray "${XRAY_DEST}" && \
       chmod 755 "${XRAY_DEST}"; then
        XRAY_FOUND="${XRAY_DEST}"
        _info "✓ xray downloaded and installed: ${XRAY_DEST}"
    else
        _err "Failed to download xray"
        _err "Please manually place xray binary at: ${XRAY_DEST}"
        XRAY_FOUND=""
    fi

    cd - > /dev/null
    rm -rf "${TMPDIR_XRAY}"
fi

if [[ -n "${XRAY_FOUND}" ]]; then
    XRAY_VER="$("${XRAY_FOUND}" version 2>/dev/null | head -1 || echo 'unknown')"
    _info "xray version: ${XRAY_VER}"
fi

# ─── Step 6: Verify x-ui database ─────────────────────────────
_step "Checking 3x-ui database..."

XUI_DB="/etc/x-ui/x-ui.db"
if [[ -f "${XUI_DB}" ]]; then
    TABLE_COUNT=$(sqlite3 "${XUI_DB}" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo "0")
    if [[ "${TABLE_COUNT}" -gt 0 ]]; then
        _info "x-ui database found and readable: ${XUI_DB} (${TABLE_COUNT} tables)"
    else
        _warn "x-ui database exists but appears empty or unreadable"
        _warn "Make sure x-ui has been started at least once before running v2auto"
    fi
else
    _warn "x-ui database not found: ${XUI_DB}"
    _warn "Install and start 3x-ui first, then re-run v2auto"
fi

# ─── Step 7: Systemd service ───────────────────────────────────
_step "Installing systemd service: ${SERVICE_NAME}..."

if ! command -v systemctl >/dev/null 2>&1; then
    _warn "systemctl not available — skipping service install"
else
    cat > "${SERVICE_FILE}" << SVCEOF
[Unit]
Description=V2Auto - Proxy Subscription Manager for 3x-ui
Documentation=file://${INSTALL_DIR}/README.md
After=network-online.target x-ui.service
Wants=network-online.target
# Wait for x-ui so the database exists

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}

# Daemon mode: runs health check every hour, full refresh if needed
ExecStart=${INSTALL_DIR}/v2auto.sh --daemon --interval 3600

# Clean stop
ExecStop=/bin/kill -TERM \$MAINPID

# Restart policy
Restart=on-failure
RestartSec=60s
StartLimitBurst=5
StartLimitIntervalSec=600

# Resource limits
MemoryMax=512M
CPUQuota=90%
LimitNOFILE=65536
LimitNPROC=1024

# Logging — view with: journalctl -u ${SERVICE_NAME} -f
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Environment
Environment="V2AUTO_LOG_FILE=${INSTALL_DIR}/logs/v2auto.log"
Environment="V2AUTO_DB_PATH=/etc/x-ui/x-ui.db"
Environment="V2AUTO_OUTPUT_DIR=${INSTALL_DIR}/output"
Environment="V2AUTO_BACKUP_DIR=${INSTALL_DIR}/backup"
Environment="V2AUTO_MAX_WORKERS=20"
Environment="V2AUTO_TOP_N=50"
Environment="V2AUTO_MAX_LATENCY=2000"
Environment="V2AUTO_TEST_TIMEOUT=12"
Environment="V2AUTO_PING_COUNT=3"
Environment="V2AUTO_PING_MIN_PASS=3"
Environment="V2AUTO_REFRESH_THRESHOLD=50"
Environment="V2AUTO_BALANCER_TAG=Balancer"
Environment="V2AUTO_XRAY_SERVICE=x-ui"
Environment="V2AUTO_TAG_PREFIX=v2auto"
Environment="V2AUTO_MAX_OUTBOUNDS=50"

# Security — allow access to x-ui database and project dir
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR} /etc/x-ui /tmp

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    _info "Service installed: ${SERVICE_FILE}"
fi

# ─── Step 8: Logrotate ─────────────────────────────────────────
if [[ -d /etc/logrotate.d ]]; then
    cat > "/etc/logrotate.d/v2auto" << EOF
${INSTALL_DIR}/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
    _info "logrotate configured"
fi

# ─── Step 9: Set permissions ───────────────────────────────────
chown -R root:root "${INSTALL_DIR}"
chmod 755 "${INSTALL_DIR}"
chmod 755 "${INSTALL_DIR}/v2auto.sh"
chmod 644 "${INSTALL_DIR}/core/"*.sh
[[ -f "${INSTALL_DIR}/xray" ]] && chmod 755 "${INSTALL_DIR}/xray"
chmod 700 "${INSTALL_DIR}/backup"   # backup dir restricted
chmod 755 "${INSTALL_DIR}/output"
chmod 755 "${INSTALL_DIR}/logs"

_info "Permissions set"

# ─── Final summary ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
_g " V2Auto Installation Complete"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Install dir  : ${INSTALL_DIR}"
echo "  Main script  : ${INSTALL_DIR}/v2auto.sh"
echo "  xray binary  : ${XRAY_FOUND:-NOT FOUND — install manually}"
echo "  Subs file    : ${INSTALL_DIR}/subs.txt"
echo "  Database     : ${XUI_DB}"
echo "  Log file     : ${INSTALL_DIR}/logs/v2auto.log"
echo "  Service      : ${SERVICE_NAME}"
echo ""
_y "NEXT STEPS:"
echo ""
echo "  1. Add your subscription URLs to subs.txt:"
echo "       nano ${INSTALL_DIR}/subs.txt"
echo ""
echo "  2. Test first (no deployment):"
echo "       ${INSTALL_DIR}/v2auto.sh --dry-run -v"
echo ""
echo "  3. Run once manually:"
echo "       ${INSTALL_DIR}/v2auto.sh"
echo ""
echo "  4. Enable the service (runs every hour automatically):"
echo "       systemctl enable ${SERVICE_NAME}"
echo "       systemctl start  ${SERVICE_NAME}"
echo ""
echo "  5. Service management:"
echo "       systemctl status  ${SERVICE_NAME}"
echo "       systemctl stop    ${SERVICE_NAME}"
echo "       systemctl restart ${SERVICE_NAME}"
echo "       journalctl -u ${SERVICE_NAME} -f"
echo ""

[[ -z "${XRAY_FOUND:-}" ]] && \
    _r "  ⚠  xray not installed — place binary at ${INSTALL_DIR}/xray before running"

[[ ! -f "${XUI_DB}" ]] && \
    _y "  ⚠  x-ui database not found — start x-ui first before enabling V2auto service"

echo ""

# Ask to run dry-run now
if [[ -n "${XRAY_FOUND:-}" ]]; then
    read -r -p "Run a dry-run test now? [y/N] " ans
    if [[ "${ans,,}" == "y" ]]; then
        echo ""
        "${INSTALL_DIR}/v2auto.sh" --dry-run -v
    fi
fi
