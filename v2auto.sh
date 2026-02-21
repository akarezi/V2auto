#!/usr/bin/env bash
# =============================================================================
# V2Auto - Main Orchestrator v2.2
# Writes configs directly to 3x-ui SQLite database (xrayTemplateConfig).
# Daemon mode: every hour checks working configs, refreshes if degraded.
#
# Usage: v2auto [OPTIONS]
# Options:
#   -i FILE        Input subs file     [default: /opt/v2auto/subs.txt]
#   -d FILE        3x-ui database      [default: /etc/x-ui/x-ui.db]
#   -w INT         Test workers        [default: 20]
#   -t INT         Test timeout (sec)  [default: 12]
#   -l INT         Max latency (ms)    [default: 2000]
#   -n INT         Top-N configs       [default: 50]
#   -x FILE        xray binary path
#   --no-deploy    Skip deployment
#   --dry-run      Test only, no deploy
#   --daemon       Continuous daemon mode
#   --interval N   Daemon interval sec [default: 3600]
#   -v             Verbose/debug
#   -h             Help
# =============================================================================

set -o nounset
set -o pipefail

readonly V2AUTO_VERSION="2.2.0"

# ─── Resolve real script dir (follows symlinks) ────────────────
_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "${_SOURCE}" ]]; do
    _DIR="$(cd -P "$(dirname "${_SOURCE}")" && pwd)"
    _SOURCE="$(readlink "${_SOURCE}")"
    [[ "${_SOURCE}" != /* ]] && _SOURCE="${_DIR}/${_SOURCE}"
done
readonly V2AUTO_DIR="$(cd -P "$(dirname "${_SOURCE}")" && pwd)"
readonly CORE_DIR="${V2AUTO_DIR}/core"

# ─── Load modules ──────────────────────────────────────────────
_require() {
    local f="${CORE_DIR}/$1"
    [[ -f "${f}" ]] || { printf '[FATAL] Module missing: %s\n' "${f}" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "${f}"
}
_require "logger.sh"
_require "health_monitor.sh"
_require "input_engine.sh"
_require "parser_engine.sh"
_require "test_engine.sh"
_require "optimizer.sh"

# ─── Defaults ──────────────────────────────────────────────────
export V2AUTO_INPUT_FILE="/opt/v2auto/subs.txt"
export V2AUTO_OUTPUT_DIR="/opt/v2auto/output"
export V2AUTO_DB_PATH="/etc/x-ui/x-ui.db"
export V2AUTO_MAX_WORKERS=20
export V2AUTO_TEST_TIMEOUT=12
export V2AUTO_MAX_LATENCY=2000
export V2AUTO_TOP_N=50
export V2AUTO_PING_COUNT=3
export V2AUTO_PING_MIN_PASS=3
export V2AUTO_LOG_FILE="/opt/v2auto/logs/v2auto.log"
export V2AUTO_BACKUP_DIR="/opt/v2auto/backup"
export V2AUTO_STATE_FILE="/opt/v2auto/logs/state"
export V2AUTO_LOG_LEVEL="${LOG_INFO:-1}"
export V2AUTO_XRAY_SERVICE="x-ui"
export V2AUTO_BALANCER_TAG="Balancer"
export V2AUTO_TAG_PREFIX="v2auto"
export V2AUTO_MAX_OUTBOUNDS=50
# Threshold: if fewer than this % of working configs are still alive, do full refresh
export V2AUTO_REFRESH_THRESHOLD=50   # percent

OPT_DEPLOY=true
OPT_DRY_RUN=false
OPT_DAEMON=false
OPT_INTERVAL=3600

# ─── Temp file registry ────────────────────────────────────────
declare -a _TEMPS=()
_reg_temp()       { _TEMPS+=("$1"); }
_cleanup_temps()  { for f in "${_TEMPS[@]:-}"; do rm -f "${f}" 2>/dev/null; done; }
trap '_cleanup_temps; health_write_state "stopped" "exit"' EXIT
trap 'log_warn "Interrupted"; exit 130' INT TERM

# ─── Usage ─────────────────────────────────────────────────────
_usage() {
    cat << EOF
V2Auto v${V2AUTO_VERSION}

Usage: v2auto [OPTIONS]

Options:
  -i FILE        Input subs file      [default: /opt/v2auto/subs.txt]
  -d FILE        3x-ui database       [default: /etc/x-ui/x-ui.db]
  -w INT         Workers              [default: 20]
  -t INT         Test timeout (sec)   [default: 12]
  -l INT         Max latency (ms)     [default: 2000]
  -n INT         Top-N configs        [default: 50]
  -x FILE        xray binary path
  --no-deploy    Skip deployment
  --dry-run      Test only, no deploy
  --daemon       Continuous daemon mode
  --interval N   Daemon interval sec  [default: 3600]
  -v             Verbose logging
  -h             Help

Service management:
  systemctl start   V2auto
  systemctl stop    V2auto
  systemctl status  V2auto
  journalctl -u V2auto -f
EOF
}

# ─── Args ──────────────────────────────────────────────────────
_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) V2AUTO_INPUT_FILE="$2";  shift 2 ;;
            -d) V2AUTO_DB_PATH="$2";     shift 2 ;;
            -w) V2AUTO_MAX_WORKERS="$2"; shift 2 ;;
            -t) V2AUTO_TEST_TIMEOUT="$2";shift 2 ;;
            -l) V2AUTO_MAX_LATENCY="$2"; shift 2 ;;
            -n) V2AUTO_TOP_N="$2";       shift 2 ;;
            -x) V2AUTO_XRAY_BIN="$2"; export V2AUTO_XRAY_BIN; shift 2 ;;
            --no-deploy) OPT_DEPLOY=false; shift ;;
            --dry-run)   OPT_DRY_RUN=true; OPT_DEPLOY=false; shift ;;
            --daemon)    OPT_DAEMON=true; shift ;;
            --interval)  OPT_INTERVAL="$2"; shift 2 ;;
            -v) V2AUTO_LOG_LEVEL="${LOG_DEBUG:-0}"; shift ;;
            -h|--help) _usage; exit 0 ;;
            *) log_warn "Unknown option: $1"; shift ;;
        esac
    done
}

# ─── xray detection ────────────────────────────────────────────
_find_xray() {
    # 1. Explicit env
    [[ -n "${V2AUTO_XRAY_BIN:-}" && -x "${V2AUTO_XRAY_BIN}" ]] && {
        printf '%s' "${V2AUTO_XRAY_BIN}"; return 0
    }
    # 2. Project directory (preferred — installed alongside v2auto)
    [[ -x "${V2AUTO_DIR}/xray" ]] && { printf '%s' "${V2AUTO_DIR}/xray"; return 0; }
    # 3. x-ui bundled xray
    [[ -x "/usr/local/x-ui/bin/xray" ]] && { printf '%s' "/usr/local/x-ui/bin/xray"; return 0; }
    # 4. System PATH
    local sys; sys="$(command -v xray 2>/dev/null)" && { printf '%s' "${sys}"; return 0; }
    return 1
}

# ─── Deploy to 3x-ui database ──────────────────────────────────
_deploy_to_db() {
    local working_file="$1"

    log_section "Deploy Engine → 3x-ui Database"
    log_info "Working file : ${working_file}"
    log_info "Database     : ${V2AUTO_DB_PATH}"
    log_info "Balancer     : ${V2AUTO_BALANCER_TAG}"
    log_info "Max outbounds: ${V2AUTO_MAX_OUTBOUNDS}"

    [[ ! -f "${working_file}" ]] && { log_error "Working file not found"; return 1; }
    [[ ! -f "${V2AUTO_DB_PATH}" ]] && { log_error "Database not found: ${V2AUTO_DB_PATH}"; return 1; }

    local lines; lines="$(wc -l < "${working_file}")"
    (( lines == 0 )) && { log_error "Working file is empty"; return 1; }
    log_info "Configs to deploy: ${lines}"

    # Backup database
    local bak="${V2AUTO_BACKUP_DIR}/xui_db_$(date +%Y%m%d_%H%M%S).db"
    mkdir -p "${V2AUTO_BACKUP_DIR}"
    cp "${V2AUTO_DB_PATH}" "${bak}" || { log_error "Database backup failed"; return 1; }
    log_info "DB backup: ${bak}"
    # Keep last 10 backups
    ls -t "${V2AUTO_BACKUP_DIR}"/xui_db_*.db 2>/dev/null | tail -n +11 | xargs -r rm -f

    # Parse configs and write to DB
    local deploy_rc
    python3 - "${working_file}" "${V2AUTO_DB_PATH}" \
        "${V2AUTO_TAG_PREFIX}" "${V2AUTO_BALANCER_TAG}" \
        "${V2AUTO_MAX_OUTBOUNDS}" 2>&1 | while IFS= read -r line; do
            log_info "  ${line}"
        done
    deploy_rc=${PIPESTATUS[0]}

    # Re-run to get exit code (pipe swallows it above)
    python3 - "${working_file}" "${V2AUTO_DB_PATH}" \
        "${V2AUTO_TAG_PREFIX}" "${V2AUTO_BALANCER_TAG}" \
        "${V2AUTO_MAX_OUTBOUNDS}" > /dev/null 2>/dev/null
    deploy_rc=$?

    if [[ "${deploy_rc}" -ne 0 ]]; then
        log_error "Deploy script failed (rc=${deploy_rc}) — restoring backup"
        cp "${bak}" "${V2AUTO_DB_PATH}" || log_error "Restore FAILED — manual fix needed!"
        return 1
    fi

    # Restart x-ui
    log_info "Restarting ${V2AUTO_XRAY_SERVICE}..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart "${V2AUTO_XRAY_SERVICE}" 2>/dev/null || {
            log_warn "systemctl restart returned error — checking status..."
        }
        sleep 3
        if systemctl is-active --quiet "${V2AUTO_XRAY_SERVICE}"; then
            log_info "✓ ${V2AUTO_XRAY_SERVICE} is running"
        else
            log_error "${V2AUTO_XRAY_SERVICE} failed to start — restoring DB backup"
            cp "${bak}" "${V2AUTO_DB_PATH}"
            systemctl restart "${V2AUTO_XRAY_SERVICE}" 2>/dev/null || true
            return 1
        fi
    else
        log_warn "systemctl not available — skipping service restart"
    fi

    log_info "✓ Deploy complete"
    return 0
}

# ─── Python: parse working.txt → inject into DB ────────────────
# Called twice above (once for log, once for exit code)
# We inline the Python here so it can be called cleanly
_deploy_python() {
    local working_file="$1"
    python3 - "${working_file}" "${V2AUTO_DB_PATH}" \
        "${V2AUTO_TAG_PREFIX}" "${V2AUTO_BALANCER_TAG}" \
        "${V2AUTO_MAX_OUTBOUNDS}" << 'PYEOF'
import json, sys, base64, re, urllib.parse, sqlite3

working_file   = sys.argv[1]
db_path        = sys.argv[2]
tag_prefix     = sys.argv[3]
balancer_tag   = sys.argv[4]
max_outbounds  = int(sys.argv[5])

# ── Helpers ────────────────────────────────────────────────────
def fix_b64(s):
    s = s.strip()
    r = len(s) % 4
    if r == 2: s += "=="
    elif r == 3: s += "="
    return s

def qs(url):
    p = {}
    if "?" in url:
        for kv in url.split("?", 1)[1].split("#")[0].split("&"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                p[k.lower()] = urllib.parse.unquote(v)
    return p

def parse_hostport(hp):
    m = re.match(r'^\[([^\]]+)\]:(\d+)$', hp)
    if m: return m.group(1), int(m.group(2))
    if ':' in hp:
        parts = hp.rsplit(':', 1)
        return parts[0], int(parts[1])
    return None, None

def build_stream(net, params, sni):
    s = {"network": net}
    sec = params.get("security", "none")
    if net == "ws":
        s["wsSettings"] = {
            "path": params.get("path", "/"),
            "host": params.get("host", sni),
            "heartbeatPeriod": 0
        }
    elif net == "grpc":
        s["grpcSettings"] = {"serviceName": params.get("servicename", params.get("mode", ""))}
    elif net == "h2":
        s["httpSettings"] = {"path": params.get("path", "/"), "host": [params.get("host", sni)]}

    if sec == "tls":
        s["security"] = "tls"
        s["tlsSettings"] = {
            "serverName": params.get("sni", sni),
            "alpn": [],
            "fingerprint": params.get("fp", ""),
            "echConfigList": "",
            "verifyPeerCertByName": "",
            "pinnedPeerCertSha256": ""
        }
    elif sec == "reality":
        s["security"] = "reality"
        s["realitySettings"] = {
            "serverName":  params.get("sni", sni),
            "fingerprint": params.get("fp", "chrome"),
            "publicKey":   params.get("pbk", ""),
            "shortId":     params.get("sid", ""),
            "spiderX":     params.get("spx", "/"),
        }
    else:
        s["security"] = "none"
    return s

# ── Protocol parsers → xray outbound objects ───────────────────
def parse_vmess(raw, tag):
    try:
        d = json.loads(base64.b64decode(fix_b64(raw[8:])).decode('utf-8', 'replace'))
    except Exception as e:
        print(f"  vmess parse error: {e}", file=sys.stderr); return None
    host = str(d.get("add", "")).strip()
    uid  = str(d.get("id",  "")).strip()
    try: port = int(str(d.get("port", 0)).strip())
    except: return None
    if not all([host, port, uid]): return None
    try: aid = int(d.get("aid", 0))
    except: aid = 0

    net = d.get("net", "tcp"); tls = d.get("tls", "")
    stream = {"network": net}
    if net == "ws":
        stream["wsSettings"] = {
            "path": d.get("path", "/"),
            "host": d.get("host", host),
            "heartbeatPeriod": 0
        }
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": d.get("path", "")}
    if tls == "tls":
        stream["security"] = "tls"
        stream["tlsSettings"] = {
            "serverName": d.get("sni", host), "alpn": [],
            "fingerprint": d.get("fp", ""),
            "echConfigList": "", "verifyPeerCertByName": "", "pinnedPeerCertSha256": ""
        }
    else:
        stream["security"] = "none"

    return {
        "tag": tag, "protocol": "vmess",
        "settings": {"address": host, "port": port, "id": uid, "alterId": aid, "security": "auto"},
        "streamSettings": stream
    }

def parse_vless(raw, tag):
    body = raw[8:]
    if "@" not in body: return None
    uid, rest = body.split("@", 1)
    uid = uid.strip()
    hp_str = rest.split("?")[0].split("#")[0]
    host, port = parse_hostport(hp_str)
    if not host: return None
    params = qs(raw)
    sni = params.get("sni", host)
    return {
        "tag": tag, "protocol": "vless",
        "settings": {
            "address": host, "port": port,
            "id": uid, "flow": params.get("flow", ""), "encryption": "none"
        },
        "streamSettings": build_stream(params.get("type", "tcp"), params, sni)
    }

def parse_trojan(raw, tag):
    body = raw[9:].split("#")[0]
    if "@" not in body: return None
    pw_enc, rest = body.split("@", 1)
    pw = urllib.parse.unquote(pw_enc)
    hp_str = rest.split("?")[0]
    host, port = parse_hostport(hp_str)
    if not host: return None
    params = qs(raw)
    sni = params.get("sni", host)
    net = params.get("type", "tcp")
    stream = {
        "network": net, "security": "tls",
        "tlsSettings": {
            "serverName": sni, "alpn": [],
            "fingerprint": params.get("fp", ""),
            "echConfigList": "", "verifyPeerCertByName": "", "pinnedPeerCertSha256": ""
        }
    }
    if net == "ws":
        stream["wsSettings"] = {
            "path": params.get("path", "/"),
            "host": params.get("host", sni),
            "heartbeatPeriod": 0
        }
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": params.get("servicename", "")}
    return {
        "tag": tag, "protocol": "trojan",
        "settings": {"address": host, "port": port, "password": pw},
        "streamSettings": stream
    }

def parse_ss(raw, tag):
    body = raw[5:].split("#")[0].strip()
    host = port = method = password = None
    try:
        if "@" in body:
            userinfo_raw, hps = body.rsplit("@", 1)
            try:
                decoded_ui = base64.b64decode(fix_b64(userinfo_raw)).decode('utf-8', 'replace')
                if ":" in decoded_ui and len(decoded_ui.split(":")[0]) < 30:
                    method, password = decoded_ui.split(":", 1)
                else:
                    userinfo = urllib.parse.unquote(userinfo_raw)
                    method, password = userinfo.split(":", 1)
            except:
                userinfo = urllib.parse.unquote(userinfo_raw)
                if ":" in userinfo:
                    method, password = userinfo.split(":", 1)
            host, port = parse_hostport(hps)
        else:
            decoded = base64.b64decode(fix_b64(body)).decode('utf-8', 'replace')
            userinfo, hps = decoded.rsplit("@", 1)
            method, password = userinfo.split(":", 1)
            host, port = parse_hostport(hps)
    except Exception as e:
        print(f"  ss parse error: {e}", file=sys.stderr); return None

    if not all([host, port, method, password]): return None
    return {
        "tag": tag, "protocol": "shadowsocks",
        "settings": {
            "address": host, "port": port,
            "method": method.strip(), "password": password.strip()
        },
        "streamSettings": {"network": "tcp", "security": "none"}
    }

# ── Parse working configs ──────────────────────────────────────
dispatch = [
    ("vmess://",  parse_vmess),
    ("vless://",  parse_vless),
    ("trojan://", parse_trojan),
    ("ss://",     parse_ss),
]

outbounds = []
tags       = []
n          = 0

with open(working_file) as f:
    for line in f:
        raw = line.strip()
        if not raw or n >= max_outbounds:
            break
        tag = f"{tag_prefix}_{n+1:03d}"
        ob  = None
        for pfx, fn in dispatch:
            if raw.startswith(pfx):
                ob = fn(raw, tag)
                break
        if ob:
            outbounds.append(ob)
            tags.append(tag)
            n += 1
            print(f"  ✓ {tag}: {ob['protocol']} → {ob['settings']['address']}:{ob['settings']['port']}", file=sys.stderr)
        else:
            print(f"  ✗ parse failed: {raw[:60]}", file=sys.stderr)

if not outbounds:
    print("ERROR: No valid outbounds parsed", file=sys.stderr)
    sys.exit(1)

print(f"Parsed {len(outbounds)} valid outbounds", file=sys.stderr)

# ── Load current xrayTemplateConfig from DB ────────────────────
conn   = sqlite3.connect(db_path)
cursor = conn.cursor()
cursor.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'")
row = cursor.fetchone()

try:
    config = json.loads(row[0]) if row and row[0] else {}
except Exception:
    config = {}

if not config or "outbounds" not in config:
    config = {
        "log":      {"loglevel": "warning"},
        "outbounds": [
            {"tag": "direct",  "protocol": "freedom",   "settings": {}},
            {"tag": "blocked", "protocol": "blackhole",  "settings": {}}
        ],
        "routing": {"rules": [], "balancers": []}
    }

# ── Remove old v2auto outbounds, keep everything else ─────────
before = len(config["outbounds"])
config["outbounds"] = [
    ob for ob in config.get("outbounds", [])
    if not ob.get("tag", "").startswith(tag_prefix)
]
print(f"Removed {before - len(config['outbounds'])} old {tag_prefix} outbounds", file=sys.stderr)

# ── Inject new outbounds ───────────────────────────────────────
config["outbounds"].extend(outbounds)

# ── Update Balancer ────────────────────────────────────────────
routing   = config.setdefault("routing", {})
balancers = routing.setdefault("balancers", [])
found     = False
for b in balancers:
    if b.get("tag") == balancer_tag:
        b["selector"] = tags
        b["strategy"] = {"type": "leastPing"}
        found = True
        break
if not found:
    balancers.append({
        "tag":         balancer_tag,
        "selector":    tags,
        "fallbackTag": "",
        "strategy":    {"type": "leastPing"}
    })

# ── Ensure routing rule ────────────────────────────────────────
rules = routing.setdefault("rules", [])
rules = [r for r in rules if r.get("balancerTag") != balancer_tag]
# Insert after API rule (if present), else at position 0
insert_at = 0
for i, r in enumerate(rules):
    if r.get("outboundTag") == "api" or "api" in r.get("inboundTag", []):
        insert_at = i + 1
rules.insert(insert_at, {
    "type":        "field",
    "network":     "tcp,udp",
    "balancerTag": balancer_tag
})
routing["rules"] = rules

# ── Update observatory ─────────────────────────────────────────
config["observatory"] = {
    "subjectSelector":   tags,
    "probeURL":          "https://www.google.com/generate_204",
    "probeInterval":     "5m",
    "enableConcurrency": True
}

# ── Write to database ──────────────────────────────────────────
config_str = json.dumps(config, ensure_ascii=False)
cursor.execute(
    "UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'",
    (config_str,)
)
if cursor.rowcount == 0:
    cursor.execute(
        "INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)",
        (config_str,)
    )
conn.commit()

# ── Verify ─────────────────────────────────────────────────────
cursor.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'")
verify_row = cursor.fetchone()
if verify_row:
    v_cfg    = json.loads(verify_row[0])
    v2a_obs  = [ob for ob in v_cfg.get("outbounds", []) if ob.get("tag", "").startswith(tag_prefix)]
    print(f"✓ Database verified: {len(v2a_obs)} {tag_prefix} outbounds stored", file=sys.stderr)
else:
    print("ERROR: verification failed — no row found after write", file=sys.stderr)
    conn.close()
    sys.exit(1)

conn.close()
print(f"✓ Done: {n} configs deployed to {db_path}", file=sys.stderr)
PYEOF
}

# ─── Hourly health check cycle ─────────────────────────────────
# Checks existing working configs. If too many are dead → full refresh.
_health_check_cycle() {
    log_section "Health Check — Existing Configs"

    local working_file="${V2AUTO_OUTPUT_DIR}/working.txt"

    if [[ ! -f "${working_file}" ]] || [[ ! -s "${working_file}" ]]; then
        log_warn "No working.txt found — triggering full refresh"
        return 1  # signal: need full refresh
    fi

    local total; total="$(wc -l < "${working_file}")"
    log_info "Existing configs: ${total}"

    if (( total == 0 )); then
        log_warn "working.txt is empty — triggering full refresh"
        return 1
    fi

    # Re-check all configs (3 pings each)
    local still_ok_file; still_ok_file="$(mktemp /tmp/v2auto_still_ok.XXXXXX)"
    recheck_working_configs "${working_file}" "${still_ok_file}"

    local still_ok; still_ok="$(wc -l < "${still_ok_file}" 2>/dev/null || echo 0)"
    log_info "Still working: ${still_ok}/${total}"

    local pct=0
    (( total > 0 )) && pct=$(( still_ok * 100 / total ))
    log_info "Health: ${pct}% configs alive (threshold: ${V2AUTO_REFRESH_THRESHOLD}%)"

    if (( pct < V2AUTO_REFRESH_THRESHOLD )); then
        log_warn "Health below threshold (${pct}% < ${V2AUTO_REFRESH_THRESHOLD}%) — full refresh needed"
        rm -f "${still_ok_file}"
        return 1  # need full refresh
    fi

    # Enough configs still working — update DB with remaining healthy ones
    log_info "Sufficient configs alive — updating DB with healthy subset"

    # Update working.txt with only the healthy configs
    cp "${still_ok_file}" "${working_file}"
    rm -f "${still_ok_file}"

    if [[ "${OPT_DEPLOY}" == "true" && "${OPT_DRY_RUN}" == "false" ]]; then
        _deploy_python "${working_file}" > /dev/null 2>&1 || {
            log_warn "DB update with healthy subset failed"
        }
        # Restart x-ui to apply
        systemctl restart "${V2AUTO_XRAY_SERVICE}" 2>/dev/null || true
        sleep 2
        systemctl is-active --quiet "${V2AUTO_XRAY_SERVICE}" \
            && log_info "✓ x-ui restarted with healthy configs" \
            || log_warn "x-ui restart issue after health update"
    fi

    return 0  # healthy enough
}

# ─── Full run cycle ────────────────────────────────────────────
_full_cycle() {
    local t0; t0="$(date +%s)"
    log_section "V2Auto v${V2AUTO_VERSION} — Full Cycle — $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "Input    : ${V2AUTO_INPUT_FILE}"
    log_info "Database : ${V2AUTO_DB_PATH}"
    log_info "xray     : ${V2AUTO_XRAY_BIN}"
    log_info "Workers  : ${V2AUTO_MAX_WORKERS}"
    log_info "Top-N    : ${V2AUTO_TOP_N}"

    health_monitor_run || return 1

    # Phase 1: Input
    local raw_file; raw_file="$(input_engine_run)" || { log_error "Input failed"; return 1; }
    _reg_temp "${raw_file}"
    local raw_count; raw_count="$(wc -l < "${raw_file}")"
    (( raw_count == 0 )) && { log_error "No configs collected"; return 1; }

    # Phase 2: Parse
    local parsed_file; parsed_file="$(mktemp /tmp/v2auto_parsed.XXXXXX)"
    _reg_temp "${parsed_file}"
    parser_engine_run "${raw_file}" "${parsed_file}" || { log_error "Parse failed"; return 1; }
    local parsed_count; parsed_count="$(wc -l < "${parsed_file}" 2>/dev/null || echo 0)"
    (( parsed_count == 0 )) && { log_error "No configs passed parsing"; return 1; }

    # Phase 3: Test (3 pings each)
    local tested_file; tested_file="$(mktemp /tmp/v2auto_tested.XXXXXX)"
    _reg_temp "${tested_file}"
    test_engine_run "${parsed_file}" "${tested_file}" || log_warn "Test engine issues"
    local working_count; working_count="$(wc -l < "${tested_file}" 2>/dev/null || echo 0)"
    (( working_count == 0 )) && { log_error "No working configs found"; return 1; }

    # Phase 4: Optimize
    local out_dir; out_dir="$(optimizer_run "${tested_file}" "${V2AUTO_OUTPUT_DIR}")" \
        || { log_error "Optimizer failed"; return 1; }
    local final_count; final_count="$(wc -l < "${out_dir}/working.txt" 2>/dev/null || echo 0)"

    # Phase 5: Deploy
    if [[ "${OPT_DEPLOY}" == "true" && "${OPT_DRY_RUN}" == "false" ]]; then
        local wf="${out_dir}/working.txt"
        if [[ -f "${wf}" ]]; then
            _deploy_python "${wf}" 2>&1 | while IFS= read -r line; do log_info "  ${line}"; done

            # Restart x-ui
            log_info "Restarting ${V2AUTO_XRAY_SERVICE}..."
            systemctl restart "${V2AUTO_XRAY_SERVICE}" 2>/dev/null || log_warn "Restart returned error"
            sleep 3
            if systemctl is-active --quiet "${V2AUTO_XRAY_SERVICE}"; then
                log_info "✓ ${V2AUTO_XRAY_SERVICE} running"
            else
                log_error "${V2AUTO_XRAY_SERVICE} not running after restart!"
            fi
        else
            log_warn "working.txt not found — skipping deploy"
        fi
    elif [[ "${OPT_DRY_RUN}" == "true" ]]; then
        log_info "DRY RUN — results: ${out_dir}/working.txt"
    fi

    local elapsed=$(( $(date +%s) - t0 ))
    log_section "Full Cycle Complete"
    log_info "Duration  : ${elapsed}s"
    log_info "Collected : ${raw_count}"
    log_info "Parsed    : ${parsed_count}"
    log_info "Working   : ${working_count}"
    log_info "Final     : ${final_count}"
    log_metric "cycle.secs" "${elapsed}"
    health_write_state "idle" "last cycle: ${elapsed}s, final: ${final_count}"
    return 0
}

# ─── Daemon loop ───────────────────────────────────────────────
_daemon_loop() {
    log_info "Daemon started — interval: ${OPT_INTERVAL}s"
    local cycle=0

    while true; do
        (( cycle++ ))
        log_info "════ Daemon cycle #${cycle} ════"

        if (( cycle == 1 )); then
            # First cycle: always do a full run
            log_info "First cycle — performing full refresh"
            _full_cycle || log_warn "Full cycle failed"
        else
            # Subsequent cycles: health check first
            if _health_check_cycle; then
                log_info "Health check passed — no full refresh needed"
            else
                log_info "Health check failed — performing full refresh"
                _full_cycle || log_warn "Full cycle failed"
            fi
        fi

        log_info "Sleeping ${OPT_INTERVAL}s until next check..."
        sleep "${OPT_INTERVAL}"
    done
}

# ─── Main ──────────────────────────────────────────────────────
main() {
    _parse_args "$@"

    mkdir -p "${V2AUTO_OUTPUT_DIR}" "${V2AUTO_BACKUP_DIR}" \
             "$(dirname "${V2AUTO_LOG_FILE}")" 2>/dev/null || true

    logger_init

    # Find xray
    local xray_bin
    if ! xray_bin="$(_find_xray)"; then
        log_error "xray binary not found!"
        log_error "Searched:"
        log_error "  1. \$V2AUTO_XRAY_BIN env var"
        log_error "  2. ${V2AUTO_DIR}/xray"
        log_error "  3. /usr/local/x-ui/bin/xray"
        log_error "  4. \$PATH"
        log_error "The installer places xray at ${V2AUTO_DIR}/xray"
        exit 1
    fi
    export V2AUTO_XRAY_BIN="${xray_bin}"
    log_info "xray: ${V2AUTO_XRAY_BIN}"

    if [[ "${OPT_DAEMON}" == "true" ]]; then
        _daemon_loop
    else
        _full_cycle
        exit $?
    fi
}

main "$@"
