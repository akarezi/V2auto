#!/usr/bin/env bash
# =============================================================================
# V2Auto - Parser Engine
# Full validation for all protocols. No silent failures.
# Protocols: vmess, vless (incl. Reality), trojan, shadowsocks (SIP002 + legacy)
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

# ─── Validators ────────────────────────────────────────────────
_valid_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}
_valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}
_valid_host() {
    local h="$1"
    [[ -z "${h}" ]] && return 1
    # IPv4
    [[ "${h}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
    # IPv6 (with or without brackets)
    [[ "${h}" =~ ^\[?[0-9a-fA-F:]+\]?$ ]] && return 0
    # Hostname: must start/end with alnum, can contain dots and hyphens
    [[ "${h}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,252}[a-zA-Z0-9])?$ ]] && return 0
    return 1
}

# ─── Python parser: handles all 4 protocols with full validation ─
# Returns JSON or exits with error
_python_parse() {
    python3 - "$1" << 'PYEOF'
import json, sys, base64, re, urllib.parse

raw = sys.argv[1]

def fail(reason):
    print(f"FAIL:{reason}", file=sys.stderr)
    sys.exit(1)

def fix_b64(s):
    s = s.strip()
    pad = len(s) % 4
    if pad == 2: s += "=="
    elif pad == 3: s += "="
    return s

def parse_qs(url):
    params = {}
    if "?" in url:
        qs = url.split("?", 1)[1].split("#")[0]
        for kv in qs.split("&"):
            if "=" in kv:
                k, v = kv.split("=", 1)
                params[k.lower()] = urllib.parse.unquote(v)
    return params

def valid_uuid(s):
    return bool(re.match(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$', s
    ))

def valid_port(p):
    try:
        n = int(str(p))
        return 1 <= n <= 65535
    except: return False

def valid_host(h):
    if not h: return False
    h = h.strip("[]")
    # IPv4
    if re.match(r'^(\d{1,3}\.){3}\d{1,3}$', h):
        return all(0 <= int(o) <= 255 for o in h.split('.'))
    # IPv6
    if re.match(r'^[0-9a-fA-F:]+$', h) and '::' in h or h.count(':') >= 2:
        return True
    # Hostname
    if re.match(r'^[a-zA-Z0-9]([a-zA-Z0-9.\-]{0,252}[a-zA-Z0-9])?$', h):
        return True
    return False

def parse_hostport(hp_str):
    """Parse host:port, handles IPv6 [::1]:443 and plain host:port"""
    hp_str = hp_str.strip()
    # IPv6 with brackets
    m = re.match(r'^\[([^\]]+)\]:(\d+)$', hp_str)
    if m:
        return m.group(1), int(m.group(2))
    # Plain host:port (rsplit to handle dots in hostname)
    if ':' in hp_str:
        parts = hp_str.rsplit(':', 1)
        return parts[0], int(parts[1])
    return None, None

# ══════════════════════════════════════════════════════════════
# VMess
# ══════════════════════════════════════════════════════════════
if raw.startswith("vmess://"):
    b64part = raw[8:].split("#")[0]
    try:
        d = json.loads(base64.b64decode(fix_b64(b64part)).decode('utf-8', 'replace'))
    except Exception as e:
        fail(f"vmess base64/json decode: {e}")

    host = str(d.get("add", "")).strip()
    uid  = str(d.get("id",  "")).strip()

    # port can be int or string
    try:
        port = int(str(d.get("port", 0)).strip())
    except:
        fail("vmess: port not numeric")

    if not valid_host(host):  fail(f"vmess: invalid host '{host}'")
    if not valid_port(port):  fail(f"vmess: invalid port '{port}'")
    if not valid_uuid(uid):   fail(f"vmess: invalid uuid '{uid}'")

    net = d.get("net", "tcp")
    tls = d.get("tls", "")

    stream = {"network": net}
    if net == "ws":
        stream["wsSettings"] = {
            "path": d.get("path", "/"),
            "host": d.get("host", host),
            "heartbeatPeriod": 0
        }
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": d.get("path", "")}
    elif net == "h2":
        stream["httpSettings"] = {
            "path": d.get("path", "/"),
            "host": [d.get("host", host)]
        }

    if tls == "tls":
        stream["security"] = "tls"
        stream["tlsSettings"] = {
            "serverName": d.get("sni", host),
            "alpn": [],
            "fingerprint": d.get("fp", ""),
            "allowInsecure": False
        }
    else:
        stream["security"] = "none"

    try: aid = int(d.get("aid", 0))
    except: aid = 0

    result = {
        "host": host, "port": port,
        "protocol": "vmess", "tag": "",
        "settings": {
            "address": host, "port": port,
            "id": uid, "alterId": aid, "security": "auto"
        },
        "streamSettings": stream
    }
    print(json.dumps(result))
    sys.exit(0)

# ══════════════════════════════════════════════════════════════
# VLESS (supports Reality, TLS, plain)
# ══════════════════════════════════════════════════════════════
elif raw.startswith("vless://"):
    body = raw[8:]
    if "@" not in body:
        fail("vless: missing '@'")

    uid, rest = body.split("@", 1)
    uid = uid.strip()

    if not valid_uuid(uid):
        fail(f"vless: invalid uuid '{uid}'")

    hp_str = rest.split("?")[0].split("#")[0]
    host, port = parse_hostport(hp_str)

    if host is None:
        fail(f"vless: cannot parse host:port from '{hp_str}'")
    if not valid_host(host):
        fail(f"vless: invalid host '{host}'")
    if not valid_port(port):
        fail(f"vless: invalid port '{port}'")

    params = parse_qs(raw)
    net    = params.get("type", "tcp")
    sec    = params.get("security", "none")
    sni    = params.get("sni", host)

    stream = {"network": net}

    if net == "ws":
        stream["wsSettings"] = {
            "path": params.get("path", "/"),
            "host": params.get("host", sni),
            "heartbeatPeriod": 0
        }
    elif net == "grpc":
        sn = params.get("servicename", params.get("mode", ""))
        stream["grpcSettings"] = {"serviceName": sn}
    elif net == "h2":
        stream["httpSettings"] = {
            "path": params.get("path", "/"),
            "host": [params.get("host", sni)]
        }

    if sec == "tls":
        stream["security"] = "tls"
        stream["tlsSettings"] = {
            "serverName": sni,
            "alpn": [],
            "fingerprint": params.get("fp", ""),
            "allowInsecure": False
        }
    elif sec == "reality":
        pbk = params.get("pbk", "")
        if not pbk:
            fail("vless/reality: missing publicKey (pbk)")
        stream["security"] = "reality"
        stream["realitySettings"] = {
            "serverName":  sni,
            "fingerprint": params.get("fp", "chrome"),
            "publicKey":   pbk,
            "shortId":     params.get("sid", ""),
            "spiderX":     params.get("spx", "/"),
        }
    else:
        stream["security"] = "none"

    result = {
        "host": host, "port": port,
        "protocol": "vless", "tag": "",
        "settings": {
            "address": host, "port": port,
            "id": uid,
            "flow": params.get("flow", ""),
            "encryption": "none"
        },
        "streamSettings": stream
    }
    print(json.dumps(result))
    sys.exit(0)

# ══════════════════════════════════════════════════════════════
# Trojan
# ══════════════════════════════════════════════════════════════
elif raw.startswith("trojan://"):
    body = raw[9:]
    # Remove fragment
    body = body.split("#")[0]

    if "@" not in body:
        fail("trojan: missing '@'")

    pw_enc, rest = body.split("@", 1)
    pw = urllib.parse.unquote(pw_enc)

    if len(pw) < 1:
        fail("trojan: empty password")

    hp_str = rest.split("?")[0]
    host, port = parse_hostport(hp_str)

    if host is None:
        fail(f"trojan: cannot parse host:port from '{hp_str}'")
    if not valid_host(host):
        fail(f"trojan: invalid host '{host}'")
    if not valid_port(port):
        fail(f"trojan: invalid port '{port}'")

    params = parse_qs(raw)
    net    = params.get("type", "tcp")
    sni    = params.get("sni", host)

    stream = {"network": net, "security": "tls"}
    stream["tlsSettings"] = {
        "serverName": sni,
        "alpn": [],
        "fingerprint": params.get("fp", ""),
        "allowInsecure": False
    }

    if net == "ws":
        stream["wsSettings"] = {
            "path": params.get("path", "/"),
            "host": params.get("host", sni),
            "heartbeatPeriod": 0
        }
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": params.get("servicename", "")}

    result = {
        "host": host, "port": port,
        "protocol": "trojan", "tag": "",
        "settings": {
            "address": host, "port": port,
            "password": pw
        },
        "streamSettings": stream
    }
    print(json.dumps(result))
    sys.exit(0)

# ══════════════════════════════════════════════════════════════
# Shadowsocks (SIP002 plain, SIP002 b64 userinfo, legacy b64)
# ══════════════════════════════════════════════════════════════
elif raw.startswith("ss://"):
    body = raw[5:].split("#")[0].strip()

    host = port = method = password = None

    if "@" in body:
        # Could be:
        # SIP002 plain:      METHOD:PASSWORD@HOST:PORT
        # SIP002 b64 user:   BASE64(METHOD:PASSWORD)@HOST:PORT
        userinfo_raw, hostport_str = body.rsplit("@", 1)

        # Decode userinfo: try base64 first, fall back to plain
        try:
            decoded_ui = base64.b64decode(fix_b64(userinfo_raw)).decode('utf-8', 'replace')
            # Validate it looks like method:password (method has no spaces)
            if ":" in decoded_ui and not decoded_ui.split(":")[0].strip() == "":
                userinfo = decoded_ui
            else:
                userinfo = urllib.parse.unquote(userinfo_raw)
        except Exception:
            userinfo = urllib.parse.unquote(userinfo_raw)

        if ":" not in userinfo:
            fail(f"ss: cannot split method:password from '{userinfo}'")
        method, password = userinfo.split(":", 1)

        host, port = parse_hostport(hostport_str)
    else:
        # Legacy full base64:  BASE64(METHOD:PASSWORD@HOST:PORT)
        try:
            decoded = base64.b64decode(fix_b64(body)).decode('utf-8', 'replace')
        except Exception as e:
            fail(f"ss: base64 decode failed: {e}")

        if "@" not in decoded:
            fail("ss: decoded legacy has no '@'")

        userinfo, hostport_str = decoded.rsplit("@", 1)
        if ":" not in userinfo:
            fail(f"ss: cannot split method:password from decoded '{userinfo}'")
        method, password = userinfo.split(":", 1)
        host, port = parse_hostport(hostport_str)

    if not method or not password:
        fail("ss: method or password empty")
    if host is None:
        fail(f"ss: cannot parse host:port")
    if not valid_host(host):
        fail(f"ss: invalid host '{host}'")
    if not valid_port(port):
        fail(f"ss: invalid port '{port}'")

    result = {
        "host": host, "port": port,
        "protocol": "shadowsocks", "tag": "",
        "settings": {
            "address": host, "port": port,
            "method": method.strip(),
            "password": password.strip()
        },
        "streamSettings": {"network": "tcp", "security": "none"}
    }
    print(json.dumps(result))
    sys.exit(0)

else:
    fail("unknown protocol")
PYEOF
}

# ─── Shell-level pre-validation (fast path before python) ──────
_shell_precheck() {
    local raw="$1"
    case "${raw}" in
        vmess://*|vless://*|trojan://*|ss://*) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Main parse function ────────────────────────────────────────
# Output: host|port|tag_suffix|proto|raw   (on success)
parse_config() {
    local raw="$1"
    _shell_precheck "${raw}" || return 1

    local json; json="$(_python_parse "${raw}" 2>/dev/null)" || return 1
    [[ -z "${json}" ]] && return 1

    # Extract host and port from json for the pipe-separated record
    local host port proto
    host="$(  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['host'])"  "${json}" 2>/dev/null)"
    port="$(  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['port'])"  "${json}" 2>/dev/null)"
    proto="$( python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['protocol'])" "${json}" 2>/dev/null)"

    [[ -z "${host}" || -z "${port}" || -z "${proto}" ]] && return 1

    # Format: host|port|proto|raw
    # (credential not needed at this stage — deploy engine re-parses raw)
    printf '%s|%s|%s|%s\n' "${host}" "${port}" "${proto}" "${raw}"
}

# ─── Engine entry point ────────────────────────────────────────
parser_engine_run() {
    local input_file="$1"
    local output_file="${2:-$(mktemp /tmp/v2auto_parsed.XXXXXX)}"

    log_section "Parser Engine"
    [[ ! -f "${input_file}" ]] && { log_error "Parser input not found: ${input_file}"; return 1; }

    local total=0 ok=0 fail=0
    declare -A _seen_hp  # dedup at parse stage

    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        (( total++ ))

        # Run python parser and capture both stdout (json) and stderr (fail reason)
        local json fail_reason
        fail_reason="$(_python_parse "${line}" 2>&1 1>/dev/null)" || true
        json="$(_python_parse "${line}" 2>/dev/null)"

        if [[ -z "${json}" ]]; then
            (( fail++ ))
            local reason="${fail_reason#FAIL:}"
            log_debug "SKIP [${total}] ${reason} — ${line:0:70}"
            continue
        fi

        local host port proto
        host="$(  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['host'])"     "${json}" 2>/dev/null)"
        port="$(  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['port'])"     "${json}" 2>/dev/null)"
        proto="$( python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['protocol'])" "${json}" 2>/dev/null)"

        if [[ -z "${host}" || -z "${port}" || -z "${proto}" ]]; then
            (( fail++ ))
            log_debug "SKIP [${total}] json extract failed — ${line:0:70}"
            continue
        fi

        local key="${host}:${port}"
        if [[ -v _seen_hp["${key}"] ]]; then
            (( fail++ ))
            log_debug "SKIP [${total}] duplicate ${key}"
            continue
        fi
        _seen_hp["${key}"]=1

        printf '%s|%s|%s|%s\n' "${host}" "${port}" "${proto}" "${line}" >> "${output_file}"
        (( ok++ ))
        log_debug "OK   [${total}] ${proto} ${host}:${port}"

    done < "${input_file}"

    log_info "Parser: ${total} input → ${ok} valid, ${fail} rejected"
    log_metric "configs.parsed" "${ok}"
    printf '%s' "${output_file}"
}
