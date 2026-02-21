#!/usr/bin/env bash
# =============================================================================
# V2Auto - Optimizer
# Sort by latency, dedup, apply Top-N, export working.txt
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

: "${V2AUTO_MAX_LATENCY:=2000}"
: "${V2AUTO_TOP_N:=50}"
: "${V2AUTO_OUTPUT_DIR:=/opt/v2auto/output}"

optimizer_run() {
    local input_file="$1"
    local out_dir="${2:-${V2AUTO_OUTPUT_DIR}}"

    log_section "Optimizer"
    [[ ! -f "${input_file}" ]] && { log_error "Input not found: ${input_file}"; return 1; }

    mkdir -p "${out_dir}" || { log_error "Cannot create output dir: ${out_dir}"; return 1; }

    local working_txt="${out_dir}/working.txt"
    local sorted_txt="${out_dir}/sorted_working.txt"

    sort -t'|' -k1,1n "${input_file}" > "${sorted_txt}.tmp"

    declare -A _seen_hp
    local total=0 deduped=0 lat_drop=0

    > "${sorted_txt}"
    > "${working_txt}"

    while IFS= read -r rec || [[ -n "${rec}" ]]; do
        [[ -z "${rec}" ]] && continue
        (( total++ ))

        local lat="${rec%%|*}"
        [[ "${lat}" =~ ^[0-9]+$ ]] || continue
        (( lat <= 0 )) && continue

        if [[ "${V2AUTO_MAX_LATENCY}" -gt 0 ]] && (( lat > V2AUTO_MAX_LATENCY )); then
            (( lat_drop++ ))
            continue
        fi

        # Fields: avg_latency|proto|host|port|raw
        local _lat proto host port raw
        IFS='|' read -r _lat proto host port raw <<< "${rec}"
        local key="${host}:${port}"

        if [[ -v _seen_hp["${key}"] ]]; then
            (( deduped++ ))
            continue
        fi
        _seen_hp["${key}"]=1

        printf '%s\n' "${rec}"  >> "${sorted_txt}"
        printf '%s\n' "${raw}"  >> "${working_txt}"

    done < "${sorted_txt}.tmp"
    rm -f "${sorted_txt}.tmp"

    # Apply Top-N
    local final; final="$(wc -l < "${sorted_txt}" 2>/dev/null || echo 0)"
    if [[ "${V2AUTO_TOP_N}" -gt 0 ]] && (( final > V2AUTO_TOP_N )); then
        head -n "${V2AUTO_TOP_N}" "${sorted_txt}" > "${sorted_txt}.n" && mv "${sorted_txt}.n" "${sorted_txt}"
        head -n "${V2AUTO_TOP_N}" "${working_txt}" > "${working_txt}.n" && mv "${working_txt}.n" "${working_txt}"
        final="${V2AUTO_TOP_N}"
    fi

    # Print stats
    {
        log_info "Optimizer results:"
        log_info "  Input    : ${total}"
        log_info "  Deduped  : ${deduped}"
        log_info "  Lat>limit: ${lat_drop}"
        log_info "  Final    : ${final}"
        if [[ -s "${sorted_txt}" ]]; then
            log_info "  Top 5 configs:"
            head -5 "${sorted_txt}" | while IFS='|' read -r lat proto host port _; do
                log_info "    ${lat}ms  ${proto}  ${host}:${port}"
            done
        fi
    }

    log_metric "configs.final" "${final}"
    printf '%s' "${out_dir}"
}
