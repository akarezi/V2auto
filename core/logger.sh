#!/usr/bin/env bash
# =============================================================================
# V2Auto - Logger Module
# =============================================================================

readonly LOG_DEBUG=0
readonly LOG_INFO=1
readonly LOG_WARN=2
readonly LOG_ERROR=3

if [[ -t 2 ]]; then
    _C_RST='\033[0m'; _C_DBG='\033[0;36m'; _C_INF='\033[0;32m'
    _C_WRN='\033[0;33m'; _C_ERR='\033[0;31m'
else
    _C_RST=''; _C_DBG=''; _C_INF=''; _C_WRN=''; _C_ERR=''
fi

: "${V2AUTO_LOG_LEVEL:=$LOG_INFO}"
: "${V2AUTO_LOG_FILE:=/opt/v2auto/logs/v2auto.log}"

logger_init() {
    mkdir -p "$(dirname "${V2AUTO_LOG_FILE}")" 2>/dev/null || V2AUTO_LOG_FILE="/tmp/v2auto.log"
}

_log() {
    local lvl_name="$1" lvl_num="$2" color="$3"; shift 3
    [[ "${lvl_num}" -lt "${V2AUTO_LOG_LEVEL}" ]] && return 0
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[${ts}] [${lvl_name}] $*"
    printf "${color}%s${_C_RST}\n" "${msg}" >&2
    printf '%s\n' "${msg}" >> "${V2AUTO_LOG_FILE}" 2>/dev/null || true
}

log_debug() { _log "DEBUG" "${LOG_DEBUG}" "${_C_DBG}" "$@"; }
log_info()  { _log "INFO " "${LOG_INFO}"  "${_C_INF}" "$@"; }
log_warn()  { _log "WARN " "${LOG_WARN}"  "${_C_WRN}" "$@"; }
log_error() { _log "ERROR" "${LOG_ERROR}" "${_C_ERR}" "$@"; }

log_metric() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [METRIC] %s=%s\n' "${ts}" "$1" "$2" >> "${V2AUTO_LOG_FILE}" 2>/dev/null || true
}

log_section() {
    local line="───────────────────────────────────────────────────────"
    log_info "┌${line}┐"
    log_info "│  $1"
    log_info "└${line}┘"
}
