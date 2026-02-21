#!/usr/bin/env bash
# =============================================================================
# V2Auto - Health Monitor
# =============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

: "${V2AUTO_MIN_DISK_MB:=200}"
: "${V2AUTO_MIN_MEM_MB:=100}"
: "${V2AUTO_STATE_FILE:=/opt/v2auto/logs/state}"
: "${V2AUTO_OUTPUT_DIR:=/opt/v2auto/output}"

health_check_resources() {
    local errors=0

    # Disk space
    local free_kb; free_kb="$(df -k /tmp 2>/dev/null | awk 'NR==2{print $4}')" || free_kb=0
    local free_mb=$(( free_kb / 1024 ))
    if (( free_mb < V2AUTO_MIN_DISK_MB )); then
        log_error "Disk space low: ${free_mb}MB (need ${V2AUTO_MIN_DISK_MB}MB)"
        (( errors++ ))
    else
        log_info "Disk: ${free_mb}MB free ✓"
    fi

    # Memory
    if [[ -f /proc/meminfo ]]; then
        local free_mem_kb; free_mem_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo)" || free_mem_kb=0
        local free_mem_mb=$(( free_mem_kb / 1024 ))
        if (( free_mem_mb < V2AUTO_MIN_MEM_MB )); then
            log_error "Memory low: ${free_mem_mb}MB (need ${V2AUTO_MIN_MEM_MB}MB)"
            (( errors++ ))
        else
            log_info "Memory: ${free_mem_mb}MB available ✓"
        fi
    fi

    # Required binaries
    local missing=0
    for bin in curl python3 base64 sort mktemp ss; do
        if ! command -v "${bin}" >/dev/null 2>&1; then
            log_error "Missing required binary: ${bin}"
            (( missing++ ))
        fi
    done
    (( missing > 0 )) && (( errors += missing ))

    return "${errors}"
}

health_cleanup_zombies() {
    local pids
    pids="$(pgrep -f 'v2auto_cfg\.' 2>/dev/null)" || true
    if [[ -n "${pids}" ]]; then
        log_warn "Cleaning stale xray processes: $(echo "${pids}" | wc -w)"
        echo "${pids}" | xargs -r kill -KILL 2>/dev/null || true
    fi
    find /tmp -maxdepth 1 -name "v2auto_*" -mmin +30 -delete 2>/dev/null || true
    find /tmp -maxdepth 2 -path "*/v2auto_ports/port.*" -mmin +10 -delete 2>/dev/null || true
}

health_write_state() {
    local status="$1" message="$2"
    {
        printf 'status=%s\n' "${status}"
        printf 'message=%s\n' "${message}"
        printf 'timestamp=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'pid=%d\n' "$$"
        if [[ -f "${V2AUTO_OUTPUT_DIR}/working.txt" ]]; then
            printf 'working_configs=%d\n' "$(wc -l < "${V2AUTO_OUTPUT_DIR}/working.txt" 2>/dev/null || echo 0)"
        fi
    } > "${V2AUTO_STATE_FILE}" 2>/dev/null || true
}

health_monitor_run() {
    log_section "Health Monitor"
    health_write_state "starting" "initializing"
    health_check_resources || {
        log_error "Resource checks failed"
        health_write_state "error" "resource check failed"
        return 1
    }
    health_cleanup_zombies
    health_write_state "running" "running"
    log_info "Health checks passed ✓"
    return 0
}
