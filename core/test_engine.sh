#!/usr/bin/env bash
# =============================================================================
# V2Auto - Test Engine
# 3 attempts per config. Config marked working only if ALL 3 succeed.
# Uses xray binary from V2AUTO_XRAY_BIN (auto-detected from project dir).
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

: "${V2AUTO_MAX_WORKERS:=20}"
: "${V2AUTO_TEST_TIMEOUT:=12}"
: "${V2AUTO_PORT_START:=20000}"
: "${V2AUTO_PORT_END:=29999}"
: "${V2AUTO_TEST_URL:=http://www.gstatic.com/generate_204}"
: "${V2AUTO_PING_COUNT:=3}"          # Number of pings required to pass
: "${V2AUTO_PING_MIN_PASS:=3}"       # All must pass (3 of 3)
: "${V2AUTO_MAX_LATENCY:=2000}"      # ms — configs slower than this are dropped

readonly _PORT_LOCK_DIR="/tmp/v2auto_ports"

# ─── Port allocator ────────────────────────────────────────────
_port_init() {
    mkdir -p "${_PORT_LOCK_DIR}"
    find "${_PORT_LOCK_DIR}" -maxdepth 1 -name "port.*" -mmin +5 -delete 2>/dev/null || true
}

_port_alloc() {
    local tries=0 port lockfile
    while (( tries++ < 300 )); do
        port=$(( RANDOM % (V2AUTO_PORT_END - V2AUTO_PORT_START + 1) + V2AUTO_PORT_START ))
        lockfile="${_PORT_LOCK_DIR}/port.${port}"
        if (set -C; : > "${lockfile}") 2>/dev/null; then
            if ! ss -tlnp 2>/dev/null | grep -q ":${port}[^0-9]"; then
                printf '%d' "${port}"; return 0
            fi
            rm -f "${lockfile}"
        fi
    done
    return 1
}

_port_free() { rm -f "${_PORT_LOCK_DIR}/port.${1}" 2>/dev/null || true; }

# ─── Build xray test config from raw protocol string ───────────
_build_test_config() {
    local host="$1" port="$2" proto="$3" raw="$4" lport="$5"
    python3 - "${host}" "${port}" "${proto}" "${raw}" "${lport}" << 'PYEOF'
import json, sys, base64, re, urllib.parse

host, port, proto, raw, lport = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], int(sys.argv[5])

def fix_b64(s):
    s = s.strip()
    r = len(s) % 4
    if r == 2: s += "=="
    elif r == 3: s += "="
    return s

def qs(s):
    p = {}
    if "?" in s:
        for kv in s.split("?", 1)[1].split("#")[0].split("&"):
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
        s["wsSettings"] = {"path": params.get("path", "/"),
                           "headers": {"Host": params.get("host", sni)}}
    elif net == "grpc":
        s["grpcSettings"] = {"serviceName": params.get("servicename", params.get("mode", ""))}
    elif net == "h2":
        s["httpSettings"] = {"path": params.get("path", "/"), "host": [params.get("host", sni)]}
    if sec == "tls":
        s["security"] = "tls"
        s["tlsSettings"] = {"serverName": params.get("sni", sni),
                            "fingerprint": params.get("fp", ""), "allowInsecure": False}
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

ob = None

if proto == "vmess":
    try:
        d = json.loads(base64.b64decode(fix_b64(raw[8:])).decode('utf-8', 'replace'))
    except Exception as e:
        sys.exit(1)
    net = d.get("net", "tcp"); tls = d.get("tls", "")
    uid = d.get("id", ""); aid = 0
    try: aid = int(d.get("aid", 0))
    except: pass
    stream = {"network": net}
    if net == "ws":
        stream["wsSettings"] = {"path": d.get("path", "/"),
                                 "headers": {"Host": d.get("host", host)}}
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": d.get("path", "")}
    if tls == "tls":
        stream["security"] = "tls"
        stream["tlsSettings"] = {"serverName": d.get("sni", host),
                                  "fingerprint": d.get("fp", ""), "allowInsecure": False}
    else:
        stream["security"] = "none"
    ob = {"protocol": "vmess",
          "settings": {"vnext": [{"address": host, "port": port,
              "users": [{"id": uid, "alterId": aid, "security": "auto"}]}]},
          "streamSettings": stream}

elif proto == "vless":
    body = raw[8:]
    uid = body.split("@")[0].strip()
    p = qs(raw)
    ob = {"protocol": "vless",
          "settings": {"vnext": [{"address": host, "port": port,
              "users": [{"id": uid, "encryption": "none", "flow": p.get("flow", "")}]}]},
          "streamSettings": build_stream(p.get("type", "tcp"), p, host)}

elif proto == "trojan":
    body = raw[9:].split("#")[0]
    pw_enc = body.split("@")[0]
    pw = urllib.parse.unquote(pw_enc)
    p = qs(raw)
    sni = p.get("sni", host)
    net = p.get("type", "tcp")
    stream = {"network": net, "security": "tls",
              "tlsSettings": {"serverName": sni, "fingerprint": p.get("fp", ""),
                              "allowInsecure": False}}
    if net == "ws":
        stream["wsSettings"] = {"path": p.get("path", "/"),
                                  "headers": {"Host": p.get("host", sni)}}
    elif net == "grpc":
        stream["grpcSettings"] = {"serviceName": p.get("servicename", "")}
    ob = {"protocol": "trojan",
          "settings": {"servers": [{"address": host, "port": port, "password": pw}]},
          "streamSettings": stream}

elif proto == "shadowsocks":
    body = raw[5:].split("#")[0].strip()
    method = password = None
    if "@" in body:
        userinfo_raw, hps = body.rsplit("@", 1)
        try:
            decoded_ui = base64.b64decode(fix_b64(userinfo_raw)).decode('utf-8', 'replace')
            if ":" in decoded_ui:
                method, password = decoded_ui.split(":", 1)
            else:
                method, password = urllib.parse.unquote(userinfo_raw).split(":", 1)
        except:
            userinfo = urllib.parse.unquote(userinfo_raw)
            if ":" in userinfo:
                method, password = userinfo.split(":", 1)
    else:
        try:
            decoded = base64.b64decode(fix_b64(body)).decode('utf-8', 'replace')
            userinfo, hps = decoded.rsplit("@", 1)
            method, password = userinfo.split(":", 1)
            h2, p2 = parse_hostport(hps)
            host, port = h2, p2
        except: pass

    if method and password:
        ob = {"protocol": "shadowsocks",
              "settings": {"servers": [{"address": host, "port": port,
                                         "method": method.strip(),
                                         "password": password.strip()}]},
              "streamSettings": {"network": "tcp", "security": "none"}}

if ob is None:
    sys.exit(1)

cfg = {
    "log": {"loglevel": "none"},
    "inbounds": [{"tag": "v2auto-socks", "port": lport, "protocol": "socks",
                  "settings": {"auth": "noauth", "udp": False}}],
    "outbounds": [dict(tag="v2auto-out", **ob)]
}
print(json.dumps(cfg))
PYEOF
}

# ─── Kill xray process cleanly ─────────────────────────────────
_xray_kill() {
    local pid="$1"
    [[ -z "${pid}" || "${pid}" == "0" ]] && return 0
    kill -TERM "${pid}" 2>/dev/null || true
    local i=0
    while kill -0 "${pid}" 2>/dev/null && (( i++ < 20 )); do sleep 0.1; done
    kill -KILL "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
}

# ─── Test single config — 3 pings, all must pass ───────────────
# Input record: host|port|proto|raw
# Output:       avg_latency_ms|proto|host|port|raw  (on success)
_test_one() {
    local record="$1"
    local host port proto raw
    IFS='|' read -r host port proto raw <<< "${record}"

    local lport; lport="$(_port_alloc)" || return 1
    local cfgfile; cfgfile="$(mktemp /tmp/v2auto_cfg.XXXXXX.json)" || {
        _port_free "${lport}"; return 1
    }

    local xpid=0

    _cleanup_test() {
        _xray_kill "${xpid}"
        rm -f "${cfgfile}"
        _port_free "${lport}"
    }

    # Build config
    local xcfg
    xcfg="$(_build_test_config "${host}" "${port}" "${proto}" "${raw}" "${lport}" 2>/dev/null)" || {
        log_debug "Config build failed: ${proto} ${host}:${port}"
        _cleanup_test; return 1
    }
    printf '%s' "${xcfg}" > "${cfgfile}"

    # Start xray
    "${V2AUTO_XRAY_BIN}" -config "${cfgfile}" >/dev/null 2>&1 &
    xpid=$!

    # Wait for xray to bind (max 1s)
    local bind_wait=0
    while (( bind_wait++ < 10 )) && ! ss -tlnp 2>/dev/null | grep -q ":${lport}[^0-9]"; do
        sleep 0.1
    done

    if ! kill -0 "${xpid}" 2>/dev/null; then
        log_debug "xray died immediately: ${host}:${port}"
        _cleanup_test; return 1
    fi

    # ── 3-ping test ───────────────────────────────────────────
    local pass=0 total_lat=0 attempt
    for (( attempt=1; attempt<=V2AUTO_PING_COUNT; attempt++ )); do
        local t0 t1 code
        t0="$(date +%s%3N)"
        code="$(curl \
            --silent \
            --max-time "${V2AUTO_TEST_TIMEOUT}" \
            --connect-timeout 5 \
            --proxy "socks5h://127.0.0.1:${lport}" \
            --output /dev/null \
            --write-out '%{http_code}' \
            -- "${V2AUTO_TEST_URL}" 2>/dev/null)" || code="0"
        t1="$(date +%s%3N)"

        local lat=$(( t1 - t0 ))

        case "${code}" in
            200|204|301|302|403|404)
                # Also check latency per-ping
                if (( lat <= V2AUTO_MAX_LATENCY )); then
                    (( pass++ ))
                    (( total_lat += lat ))
                    log_debug "  ping ${attempt}/${V2AUTO_PING_COUNT} ✓ ${lat}ms — ${host}:${port}"
                else
                    log_debug "  ping ${attempt}/${V2AUTO_PING_COUNT} ✗ too slow ${lat}ms — ${host}:${port}"
                fi
                ;;
            *)
                log_debug "  ping ${attempt}/${V2AUTO_PING_COUNT} ✗ http=${code} — ${host}:${port}"
                ;;
        esac

        # Short pause between pings
        (( attempt < V2AUTO_PING_COUNT )) && sleep 0.3
    done

    _cleanup_test

    # Must pass ALL required pings
    if (( pass >= V2AUTO_PING_MIN_PASS )); then
        local avg_lat=$(( total_lat / pass ))
        log_debug "PASS ${pass}/${V2AUTO_PING_COUNT} avg=${avg_lat}ms — ${host}:${port}"
        printf '%d|%s|%s|%s|%s\n' "${avg_lat}" "${proto}" "${host}" "${port}" "${raw}"
        return 0
    fi

    log_debug "FAIL ${pass}/${V2AUTO_PING_COUNT} pings — ${host}:${port}"
    return 1
}

# ─── Worker pool ───────────────────────────────────────────────
test_engine_run() {
    local input_file="$1"
    local output_file="${2:-$(mktemp /tmp/v2auto_tested.XXXXXX)}"

    log_section "Test Engine"
    _port_init

    [[ ! -f "${input_file}" ]] && { log_error "Input not found: ${input_file}"; return 1; }

    if [[ -z "${V2AUTO_XRAY_BIN:-}" || ! -x "${V2AUTO_XRAY_BIN}" ]]; then
        log_error "xray binary not found: '${V2AUTO_XRAY_BIN:-unset}'"
        return 1
    fi
    log_info "xray binary : ${V2AUTO_XRAY_BIN}"
    log_info "Pings/config: ${V2AUTO_PING_COUNT} (all must pass)"
    log_info "Max latency : ${V2AUTO_MAX_LATENCY}ms"
    log_info "Workers     : ${V2AUTO_MAX_WORKERS}"

    local total; total="$(wc -l < "${input_file}")"
    log_info "Testing ${total} configs..."

    local result_dir; result_dir="$(mktemp -d /tmp/v2auto_res.XXXXXX)"
    local pids=() active=0 tested=0 working=0

    trap '
        log_warn "Test interrupted — cleaning up..."
        for _p in "${pids[@]:-}"; do kill -TERM "${_p}" 2>/dev/null || true; done
        wait 2>/dev/null || true
        rm -rf "${result_dir}"
        exit 130
    ' INT TERM

    _wait_slot() {
        local live=()
        for p in "${pids[@]:-}"; do
            if kill -0 "${p}" 2>/dev/null; then
                live+=("${p}")
            else
                wait "${p}" 2>/dev/null
                (( active > 0 )) && (( active-- ))
            fi
        done
        pids=("${live[@]}")
        while (( active >= V2AUTO_MAX_WORKERS )); do
            sleep 0.05
            live=()
            for p in "${pids[@]:-}"; do
                if kill -0 "${p}" 2>/dev/null; then
                    live+=("${p}")
                else
                    wait "${p}" 2>/dev/null
                    (( active > 0 )) && (( active-- ))
                fi
            done
            pids=("${live[@]}")
        done
    }

    while IFS= read -r rec || [[ -n "${rec}" ]]; do
        [[ -z "${rec}" ]] && continue
        (( tested++ ))
        _wait_slot

        local rf="${result_dir}/${tested}"
        (
            _test_one "${rec}" > "${rf}.tmp" 2>/dev/null \
                && mv "${rf}.tmp" "${rf}" \
                || rm -f "${rf}.tmp"
        ) &
        pids+=($!); (( active++ ))

        (( tested % 20 == 0 )) && log_info "Progress: ${tested}/${total}..."
    done < "${input_file}"

    log_info "Waiting for remaining workers..."
    for p in "${pids[@]:-}"; do wait "${p}" 2>/dev/null || true; done

    # Collect results
    for rf in "${result_dir}"/*; do
        [[ -f "${rf}" ]] || continue
        cat "${rf}" >> "${output_file}" && (( working++ ))
    done

    local failed=$(( tested - working ))
    rm -rf "${result_dir}"
    trap - INT TERM

    log_info "Results: tested=${tested}  working=${working}  failed=${failed}"
    log_metric "configs.working" "${working}"
    printf '%s' "${output_file}"
}

# ─── Re-check existing working configs (for hourly health check) ─
# Input:  working.txt (raw configs, one per line)
# Output: still_working.txt (same format, only configs that pass 3/3 pings)
recheck_working_configs() {
    local working_file="$1"
    local output_file="${2:-$(mktemp /tmp/v2auto_rechecked.XXXXXX)}"

    log_section "Re-check Existing Configs"
    _port_init

    [[ ! -f "${working_file}" ]] && { log_error "Working file not found: ${working_file}"; return 1; }

    if [[ -z "${V2AUTO_XRAY_BIN:-}" || ! -x "${V2AUTO_XRAY_BIN}" ]]; then
        log_error "xray binary not available"
        return 1
    fi

    local total; total="$(wc -l < "${working_file}")"
    log_info "Re-checking ${total} existing configs (${V2AUTO_PING_COUNT} pings each)..."

    # Parse existing raw configs into host|port|proto|raw format
    local parsed_existing; parsed_existing="$(mktemp /tmp/v2auto_recheck_parsed.XXXXXX)"

    python3 - "${working_file}" "${parsed_existing}" << 'PYEOF'
import sys, json, base64, re, urllib.parse

wf, of = sys.argv[1], sys.argv[2]

def fix_b64(s):
    s = s.strip()
    r = len(s) % 4
    if r == 2: s += "=="
    elif r == 3: s += "="
    return s

def qs(s):
    p = {}
    if "?" in s:
        for kv in s.split("?", 1)[1].split("#")[0].split("&"):
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

results = []
with open(wf) as f:
    for line in f:
        raw = line.strip()
        if not raw: continue
        host = port = proto = None
        try:
            if raw.startswith("vmess://"):
                d = json.loads(base64.b64decode(fix_b64(raw[8:])).decode('utf-8', 'replace'))
                host = d.get("add", "").strip()
                port = int(str(d.get("port", 0)).strip())
                proto = "vmess"
            elif raw.startswith("vless://"):
                body = raw[8:]
                hp_str = body.split("@", 1)[1].split("?")[0].split("#")[0]
                host, port = parse_hostport(hp_str)
                proto = "vless"
            elif raw.startswith("trojan://"):
                body = raw[9:].split("#")[0]
                hp_str = body.split("@", 1)[1].split("?")[0]
                host, port = parse_hostport(hp_str)
                proto = "trojan"
            elif raw.startswith("ss://"):
                body = raw[5:].split("#")[0]
                if "@" in body:
                    hps = body.rsplit("@", 1)[1]
                else:
                    decoded = base64.b64decode(fix_b64(body)).decode('utf-8', 'replace')
                    hps = decoded.rsplit("@", 1)[1]
                host, port = parse_hostport(hps)
                proto = "shadowsocks"
        except: pass

        if host and port and proto:
            results.append(f"{host}|{port}|{proto}|{raw}")

with open(of, 'w') as f:
    for r in results:
        f.write(r + "\n")

print(f"Parsed {len(results)} existing configs", file=sys.stderr)
PYEOF

    local parsed_count; parsed_count="$(wc -l < "${parsed_existing}" 2>/dev/null || echo 0)"
    log_info "Successfully parsed: ${parsed_count}/${total}"

    # Now test them
    local tested_file; tested_file="$(mktemp /tmp/v2auto_recheck_tested.XXXXXX)"
    test_engine_run "${parsed_existing}" "${tested_file}"
    rm -f "${parsed_existing}"

    local still_working; still_working="$(wc -l < "${tested_file}" 2>/dev/null || echo 0)"
    log_info "Still working: ${still_working}/${total}"

    # Extract just the raw configs (last field) into output
    if [[ -s "${tested_file}" ]]; then
        awk -F'|' '{print $NF}' "${tested_file}" > "${output_file}"
    fi

    rm -f "${tested_file}"
    printf '%s' "${output_file}"
    return 0
}
