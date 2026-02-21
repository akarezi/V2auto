#!/usr/bin/env bash
# =============================================================================
# V2Auto - Input Engine
# Handles: raw configs, subscription URLs, base64 blobs, mixed content
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

readonly _IE_PROTO_RE='^(vmess|vless|trojan|ss)://'
readonly _IE_URL_RE='^https?://[a-zA-Z0-9._/:%?=&@#+-]+'
readonly _IE_B64_RE='^[A-Za-z0-9+/=]{20,}$'

_ie_is_b64_configs() {
    local s="${1//[[:space:]]/}"
    [[ "${#s}" -lt 20 ]] && return 1
    [[ "${s}" =~ ${_IE_B64_RE} ]] || return 1
    local dec; dec="$(printf '%s' "${s}" | base64 --decode 2>/dev/null)" || return 1
    [[ "${dec}" =~ ${_IE_PROTO_RE} ]]
}

_ie_b64_decode() {
    local s="${1//[[:space:]]/}"
    local pad=$(( ${#s} % 4 ))
    [[ "${pad}" -eq 2 ]] && s="${s}=="
    [[ "${pad}" -eq 3 ]] && s="${s}="
    printf '%s' "${s}" | base64 --decode 2>/dev/null
}

_ie_fetch_url() {
    local url="$1"
    log_info "Fetching: ${url}"
    curl --silent --fail --location \
        --max-time "${V2AUTO_CURL_TIMEOUT:-20}" \
        --connect-timeout 10 \
        --max-redirs 5 \
        --user-agent 'V2Auto/2.1' \
        -- "${url}" 2>/dev/null
}

_ie_extract_configs() {
    local text="$1"
    while IFS= read -r line; do
        line="${line//[$'\r']/}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue
        if [[ "${line}" =~ ${_IE_PROTO_RE} ]]; then
            printf '%s\n' "${line}"
        elif _ie_is_b64_configs "${line}"; then
            local dec; dec="$(_ie_b64_decode "${line}")" || continue
            while IFS= read -r dl; do
                [[ "${dl}" =~ ${_IE_PROTO_RE} ]] && printf '%s\n' "${dl}"
            done <<< "${dec}"
        fi
    done <<< "${text}"
}

input_engine_run() {
    local input_file="${V2AUTO_INPUT_FILE:-/opt/v2auto/subs.txt}"
    local output_file; output_file="$(mktemp /tmp/v2auto_raw.XXXXXX)"

    log_section "Input Engine"
    [[ ! -f "${input_file}" ]] && { log_error "Input file not found: ${input_file}"; return 1; }

    local protos=0 urls=0 blobs=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        local clean; clean="$(printf '%s' "${line}" | tr -cd '[:print:][:space:]')"
        clean="${clean#"${clean%%[![:space:]]*}"}"
        clean="${clean%"${clean##*[![:space:]]}"}"
        [[ -z "${clean}" || "${clean}" =~ ^# ]] && continue

        if [[ "${clean}" =~ ${_IE_PROTO_RE} ]]; then
            printf '%s\n' "${clean}" >> "${output_file}"
            (( protos++ ))
        elif [[ "${clean}" =~ ${_IE_URL_RE} ]]; then
            (( urls++ ))
            local fetched; fetched="$(_ie_fetch_url "${clean}")" || continue
            if _ie_is_b64_configs "${fetched}"; then
                fetched="$(_ie_b64_decode "${fetched}")"
            fi
            local extracted; extracted="$(_ie_extract_configs "${fetched}")"
            [[ -n "${extracted}" ]] && printf '%s\n' "${extracted}" >> "${output_file}"
        elif _ie_is_b64_configs "${clean}"; then
            (( blobs++ ))
            local dec; dec="$(_ie_b64_decode "${clean}")" || continue
            local extracted; extracted="$(_ie_extract_configs "${dec}")"
            [[ -n "${extracted}" ]] && printf '%s\n' "${extracted}" >> "${output_file}"
        else
            log_debug "Skip unrecognized line: ${clean:0:60}"
        fi
    done < "${input_file}"

    local dedup_file; dedup_file="$(mktemp /tmp/v2auto_raw_dedup.XXXXXX)"
    sort -u "${output_file}" > "${dedup_file}"
    rm -f "${output_file}"

    local total; total="$(wc -l < "${dedup_file}")"
    log_info "Collected: direct=${protos} urls=${urls} blobs=${blobs} → unique=${total}"
    log_metric "configs.collected" "${total}"
    printf '%s' "${dedup_file}"
}
