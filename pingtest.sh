#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# pingtest.sh - Network ping monitoring and analysis tool (v2)
#
# Records ping results to CSV, provides analysis of latency, packet loss,
# and connectivity gaps. Designed for long-running tests (hours to months).
# =============================================================================

readonly VERSION="2.0.0"
readonly SCRIPT_NAME="${0##*/}"

# --- Exit codes ---
readonly EXIT_OK=0
readonly EXIT_USAGE=1
readonly EXIT_FILE_EXISTS=2
readonly EXIT_FILE_MISSING=3
readonly EXIT_INVALID_INPUT=4
readonly EXIT_NOT_RUNNING=5
readonly EXIT_PING_FAILED=6

# --- Colors (only when stdout is a terminal) ---
if [[ -t 1 ]]; then
    readonly C_RED="\033[0;31m"
    readonly C_GRE="\033[0;32m"
    readonly C_YEL="\033[0;33m"
    readonly C_BLU="\033[0;34m"
    readonly C_PUR="\033[0;35m"
    readonly C_CYA="\033[0;36m"
    readonly C_WHI="\033[1;37m"
    readonly C_GRA="\033[1;30m"
    readonly C_RST="\033[0m"
else
    readonly C_RED="" C_GRE="" C_YEL="" C_BLU="" C_PUR=""
    readonly C_CYA="" C_WHI="" C_GRA="" C_RST=""
fi

# --- Utility functions ---

die() {
    printf "${C_RED}Error: %s${C_RST}\n" "$*" >&2
    exit "${EXIT_INVALID_INPUT}"
}

warn() {
    printf "${C_YEL}Warning: %s${C_RST}\n" "$*" >&2
}

info() {
    printf "${C_CYA}%s${C_RST}\n" "$*"
}

# Require that a variable is set, or die with a message
require_arg() {
    local name="$1" value="$2" flag="$3"
    if [[ -z "${value}" ]]; then
        die "Missing required argument: ${flag} <${name}> (see: ${SCRIPT_NAME} help)"
    fi
}

# Require that a data file exists and has the v2 header
require_file() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        die "File not found: ${file}"
    fi
    local header
    header=$(head -1 "${file}")
    if [[ "${header}" != "# PINGTEST.TIC v2" ]]; then
        die "File is not a pingtest.sh data file (missing v2 header): ${file}"
    fi
}

# Derive the PID file path from a data file path
pid_file_for() {
    local file="$1"
    printf "%s.pid" "${file}"
}

# Derive the log file path from a data file path
log_file_for() {
    local file="$1"
    printf "%s.log" "${file}"
}

# Cleanup temp files on exit (set per-command as needed)
_TMP_FILES=()
cleanup() {
    for f in "${_TMP_FILES[@]+"${_TMP_FILES[@]}"}"; do
        rm -f "${f}" 2>/dev/null || true
    done
}
trap cleanup EXIT

# =============================================================================
# cmd_help - Print usage information
# =============================================================================
cmd_help() {
    local cmd="${1:-}"
    case "${cmd}" in
        start)
            printf "\n${C_CYA}Usage:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} start -f <FILE> -h <HOST> [-t <COUNT>] [-i <INTERVAL>]${C_RST}\n"
            printf "\n${C_CYA}Description:${C_RST}\n"
            printf "  Start a background ping test. Results are logged to FILE in CSV format.\n"
            printf "  A PID file (<FILE>.pid) is created in the current directory.\n"
            printf "\n${C_CYA}Options:${C_RST}\n"
            printf "  ${C_WHI}-f FILE${C_RST}       Output data file name (required)\n"
            printf "  ${C_WHI}-h HOST${C_RST}       Target IP address or hostname (required)\n"
            printf "  ${C_WHI}-t COUNT${C_RST}      Total number of pings to send (default: 2592000 / 30 days)\n"
            printf "  ${C_WHI}-i INTERVAL${C_RST}   Seconds between pings (default: 1)\n"
            printf "\n${C_CYA}Examples:${C_RST}\n"
            printf "  ${C_WHI}# Ping a host by name for the default 30 days${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} start -f webserver.csv -h webserver01${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Ping an IP for 1 hour (3600 pings at 1/sec)${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} start -f router.csv -h 172.27.84.170 -t 3600${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# 24-hour test pinging every 2 seconds${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} start -f switch.csv -h core-switch01 -t 43200 -i 2${C_RST}\n"
            ;;
        stop)
            printf "\n${C_CYA}Usage:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} stop -f <FILE>${C_RST}\n"
            printf "\n${C_CYA}Description:${C_RST}\n"
            printf "  Gracefully stop a running ping test by sending SIGTERM to the\n"
            printf "  background process. Reads the PID from <FILE>.pid.\n"
            printf "\n${C_CYA}Examples:${C_RST}\n"
            printf "  ${C_WHI}# Stop the test writing to webserver.csv${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} stop -f webserver.csv${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Stop the test writing to router.csv${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} stop -f router.csv${C_RST}\n"
            ;;
        status)
            printf "\n${C_CYA}Usage:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} status [-f <FILE>]${C_RST}\n"
            printf "\n${C_CYA}Description:${C_RST}\n"
            printf "  Show status of running ping tests. If -f is given, check only\n"
            printf "  that test. Otherwise, check all .pid files in the current directory.\n"
            printf "\n${C_CYA}Examples:${C_RST}\n"
            printf "  ${C_WHI}# Show status of all running tests in the current directory${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} status${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Check status of a specific test${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} status -f webserver.csv${C_RST}\n"
            ;;
        pingcheck|pc)
            printf "\n${C_CYA}Usage:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} pingcheck -f <FILE> -c <COUNT>${C_RST}\n"
            printf "\n${C_CYA}Description:${C_RST}\n"
            printf "  Find consecutive ping timeouts of at least COUNT length.\n"
            printf "  Reports start time, end time, and total missed for each gap.\n"
            printf "\n${C_CYA}Options:${C_RST}\n"
            printf "  ${C_WHI}-f FILE${C_RST}       Data file to analyze (required)\n"
            printf "  ${C_WHI}-c COUNT${C_RST}      Minimum consecutive missed pings to report (required)\n"
            printf "\n${C_CYA}Examples:${C_RST}\n"
            printf "  ${C_WHI}# Find drops of 4+ consecutive missed pings${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} pingcheck -f webserver.csv -c 4${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Find only longer outages (10+ consecutive drops)${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} pingcheck -f webserver.csv -c 10${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Same command using the short alias${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} pc -f router.csv -c 3${C_RST}\n"
            ;;
        latencycheck|lc)
            printf "\n${C_CYA}Usage:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} latencycheck -f <FILE> [-d <DATE>] [-b <BUCKETS>]${C_RST}\n"
            printf "\n${C_CYA}Description:${C_RST}\n"
            printf "  Show latency distribution in configurable buckets, grouped by day.\n"
            printf "  Uses a single-pass algorithm for fast processing of large files.\n"
            printf "\n${C_CYA}Options:${C_RST}\n"
            printf "  ${C_WHI}-f FILE${C_RST}       Data file to analyze (required)\n"
            printf "  ${C_WHI}-d DATE${C_RST}       Filter to a single day (YYYY-MM-DD format)\n"
            printf "  ${C_WHI}-b BUCKETS${C_RST}    Comma-separated bucket boundaries in ms\n"
            printf "                  (default: 0,10,20,30,40,50,60,70,80,90,100)\n"
            printf "\n${C_CYA}Examples:${C_RST}\n"
            printf "  ${C_WHI}# Show all days with default 10ms buckets${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} latencycheck -f webserver.csv${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Filter to a single day${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} latencycheck -f webserver.csv -d 2026-03-26${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Custom bucket boundaries${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} latencycheck -f webserver.csv -b 0,5,10,25,50,100,200${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Single day with custom buckets using the short alias${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} lc -f webserver.csv -d 2026-03-26 -b 0,5,25,50,100${C_RST}\n"
            ;;
        avglat|al)
            printf "\n${C_CYA}Usage:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} avglat -f <FILE> [-c <COUNT>]${C_RST}\n"
            printf "\n${C_CYA}Description:${C_RST}\n"
            printf "  Compute rolling average latency over windows of COUNT pings.\n"
            printf "  Uses a single-pass algorithm (no external bc calls).\n"
            printf "\n${C_CYA}Options:${C_RST}\n"
            printf "  ${C_WHI}-f FILE${C_RST}       Data file to analyze (required)\n"
            printf "  ${C_WHI}-c COUNT${C_RST}      Window size in pings (default: 30)\n"
            printf "\n${C_CYA}Examples:${C_RST}\n"
            printf "  ${C_WHI}# Rolling average over default 30 pings${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} avglat -f webserver.csv${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Average over 60-ping windows${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} avglat -f webserver.csv -c 60${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Hourly average (3600 pings per window) using the short alias${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} al -f webserver.csv -c 3600${C_RST}\n"
            ;;
        stats)
            printf "\n${C_CYA}Usage:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} stats -f <FILE>${C_RST}\n"
            printf "\n${C_CYA}Description:${C_RST}\n"
            printf "  Show comprehensive summary statistics including min, max, mean,\n"
            printf "  median, P95, P99 latency, jitter (stddev), and packet loss %%.\n"
            printf "\n${C_CYA}Examples:${C_RST}\n"
            printf "  ${C_WHI}# Full summary for a webserver test${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} stats -f webserver.csv${C_RST}\n"
            printf "\n"
            printf "  ${C_WHI}# Stats for a router test${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} stats -f router.csv${C_RST}\n"
            ;;
        "")
            printf "\n${C_CYA}pingtest.sh v${VERSION}${C_RST} - Network ping monitoring and analysis\n"
            printf "\n${C_CYA}Usage:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} <command> [options]${C_RST}\n"
            printf "\n${C_CYA}Commands:${C_RST}\n"
            printf "  ${C_WHI}start${C_RST}          Start a background ping test\n"
            printf "  ${C_WHI}stop${C_RST}           Stop a running ping test\n"
            printf "  ${C_WHI}status${C_RST}         Show status of running tests\n"
            printf "  ${C_WHI}pingcheck${C_RST}      Find consecutive ping drops (alias: pc)\n"
            printf "  ${C_WHI}latencycheck${C_RST}   Latency distribution by day (alias: lc)\n"
            printf "  ${C_WHI}avglat${C_RST}         Rolling average latency (alias: al)\n"
            printf "  ${C_WHI}stats${C_RST}          Summary statistics (min/max/median/p95/p99/jitter)\n"
            printf "  ${C_WHI}help${C_RST}           Show this help, or help for a specific command\n"
            printf "\n${C_CYA}Examples:${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} help start/stop/status/stats/pingcheck/latencycheck/avglat${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} start -f myhost.csv -h 10.0.0.1${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} status${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} stats -f myhost.csv${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} pingcheck -f myhost.csv -c 5${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} latencycheck -f myhost.csv${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} avglat -f myhost.csv${C_RST}\n"
            printf "  ${C_YEL}${SCRIPT_NAME} stop -f myhost.csv${C_RST}\n"
            ;;
        *)
            die "Unknown command: ${cmd} (see: ${SCRIPT_NAME} help)"
            ;;
    esac
    printf "\n"
}

# =============================================================================
# cmd_start - Start a background ping test
# =============================================================================
cmd_start() {
    local file="" host="" total_pings="2592000" interval="1"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) file="$2"; shift 2 ;;
            -h) host="$2"; shift 2 ;;
            -t) total_pings="$2"; shift 2 ;;
            -i) interval="$2"; shift 2 ;;
            *)  die "Unknown option for start: $1" ;;
        esac
    done

    require_arg "FILE" "${file}" "-f"
    require_arg "HOST" "${host}" "-h"

    # Validate numeric arguments
    if ! [[ "${total_pings}" =~ ^[0-9]+$ ]]; then
        die "Total pings (-t) must be a positive integer: ${total_pings}"
    fi
    if ! [[ "${interval}" =~ ^[0-9]+$ ]] || [[ "${interval}" -eq 0 ]]; then
        die "Interval (-i) must be a positive integer: ${interval}"
    fi

    # Check file doesn't already exist
    if [[ -e "${file}" ]]; then
        printf "${C_RED}File already exists: ${file}${C_RST}\n" >&2
        ls -l "${file}" >&2
        local pidf
        pidf="$(pid_file_for "${file}")"
        if [[ -f "${pidf}" ]]; then
            printf "${C_RED}PID file also exists: ${pidf} (PID: $(cat "${pidf}"))${C_RST}\n" >&2
            printf "${C_RED}Use '${SCRIPT_NAME} status -f ${file}' to check if a test is still running.${C_RST}\n" >&2
        fi
        exit ${EXIT_FILE_EXISTS}
    fi

    # Resolve the remote host with a test ping
    local resolved_host="${host}"
    local test_output
    if test_output=$(ping -c 1 -W 5 "${host}" 2>&1); then
        # Extract the IP from the first line, e.g. "PING hostname (1.2.3.4) ..."
        local ip
        ip=$(printf '%s\n' "${test_output}" | head -1 | sed -n 's/.*(\([^)]*\)).*/\1/p')
        if [[ -n "${ip}" ]]; then
            resolved_host="${host} (${ip})"
        fi
    else
        warn "Test ping to ${host} failed -- starting anyway (host may come up later)"
    fi

    # Write the CSV file header
    {
        printf "# PINGTEST.TIC v2\n"
        printf "# host=%s\n" "${resolved_host}"
        printf "# started=%s\n" "$(date -Iseconds)"
        printf "# interval=%s\n" "${interval}"
        printf "# total_pings=%s\n" "${total_pings}"
        printf "timestamp,latency_ms,status\n"
    } > "${file}"

    # Start the background ping process
    # The subshell handles signal traps and writes the end marker on termination
    (
        _write_end_marker() {
            printf "# ended=%s\n" "$(date -Iseconds)" >> "${file}"
            rm -f "$(pid_file_for "${file}")" 2>/dev/null || true
            exit 0
        }
        trap _write_end_marker SIGTERM SIGINT SIGHUP

        ping -c "${total_pings}" -i "${interval}" -O "${host}" 2>/dev/null | while IFS= read -r line; do
            # Parse ping output lines
            # Successful: "64 bytes from 1.2.3.4: icmp_seq=1 ttl=64 time=4.23 ms"
            # Timeout:    "no answer yet for icmp_seq=1"
            if [[ "${line}" == *"time="* ]]; then
                local latency
                latency=$(printf '%s' "${line}" | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
                if [[ -n "${latency}" ]]; then
                    printf "%s,%s,ok\n" "$(date -Iseconds)" "${latency}" >> "${file}"
                fi
            elif [[ "${line}" == "no answer"* ]]; then
                printf "%s,-1,timeout\n" "$(date -Iseconds)" >> "${file}"
            fi
        done

        # Ping finished (all pings sent) -- write end marker
        printf "# ended=%s\n" "$(date -Iseconds)" >> "${file}"
        rm -f "$(pid_file_for "${file}")" 2>/dev/null || true
    ) &

    local bg_pid=$!

    # Write PID file
    printf "%d\n" "${bg_pid}" > "$(pid_file_for "${file}")"

    # Log entry
    local logf
    logf="$(log_file_for "${file}")"
    printf "%s | START | host=%s | file=%s | pid=%d | count=%s | interval=%ss\n" \
        "$(date -Iseconds)" "${resolved_host}" "${file}" "${bg_pid}" "${total_pings}" "${interval}" >> "${logf}"

    printf "${C_GRE}Ping test started${C_RST}\n"
    printf "  Host:     %s\n" "${resolved_host}"
    printf "  File:     %s\n" "${file}"
    printf "  PID:      %d\n" "${bg_pid}"
    printf "  Count:    %s pings\n" "${total_pings}"
    printf "  Interval: %ss\n" "${interval}"
    printf "\n"
    printf "Use '${C_YEL}${SCRIPT_NAME} status -f ${file}${C_RST}' to check progress.\n"
    printf "Use '${C_YEL}${SCRIPT_NAME} stop -f ${file}${C_RST}' to stop.\n"
}

# =============================================================================
# cmd_stop - Gracefully stop a running ping test
# =============================================================================
cmd_stop() {
    local file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) file="$2"; shift 2 ;;
            *)  die "Unknown option for stop: $1" ;;
        esac
    done

    require_arg "FILE" "${file}" "-f"

    local pidf
    pidf="$(pid_file_for "${file}")"

    if [[ ! -f "${pidf}" ]]; then
        die "No PID file found for ${file} (${pidf}). Test may not be running."
    fi

    local pid
    pid=$(cat "${pidf}")

    if ! [[ "${pid}" =~ ^[0-9]+$ ]]; then
        die "Invalid PID in ${pidf}: ${pid}"
    fi

    if ! kill -0 "${pid}" 2>/dev/null; then
        warn "Process ${pid} is not running. Removing stale PID file."
        rm -f "${pidf}"
        exit ${EXIT_NOT_RUNNING}
    fi

    printf "Stopping ping test (PID %d)...\n" "${pid}"
    kill -TERM "${pid}" 2>/dev/null || true

    # Wait up to 10 seconds for the process to exit
    local waited=0
    while kill -0 "${pid}" 2>/dev/null && [[ ${waited} -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
    done

    if kill -0 "${pid}" 2>/dev/null; then
        warn "Process did not exit gracefully, sending SIGKILL..."
        kill -9 "${pid}" 2>/dev/null || true
        rm -f "${pidf}"
    fi

    # Log the stop
    if [[ -f "${file}" ]]; then
        local logf
        logf="$(log_file_for "${file}")"
        printf "%s | STOP  | file=%s | pid=%d\n" \
            "$(date -Iseconds)" "${file}" "${pid}" >> "${logf}"
    fi

    printf "${C_GRE}Ping test stopped.${C_RST}\n"
}

# =============================================================================
# cmd_status - Show status of running ping tests
# =============================================================================
cmd_status() {
    local file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) file="$2"; shift 2 ;;
            *)  die "Unknown option for status: $1" ;;
        esac
    done

    local pid_files=()
    if [[ -n "${file}" ]]; then
        local pidf
        pidf="$(pid_file_for "${file}")"
        if [[ -f "${pidf}" ]]; then
            pid_files=("${pidf}")
        else
            printf "${C_YEL}No PID file found for ${file}.${C_RST}\n"
            # Still show file info if it exists
            if [[ -f "${file}" ]]; then
                _show_file_info "${file}" ""
            else
                printf "Data file not found: ${file}\n"
            fi
            return
        fi
    else
        # Find all .pid files in current directory
        shopt -s nullglob
        for pf in *.csv.pid; do
            pid_files+=("${pf}")
        done
        shopt -u nullglob

        if [[ ${#pid_files[@]} -eq 0 ]]; then
            printf "No ping tests found in current directory.\n"
            return
        fi
    fi

    printf "\n${C_CYA}%-30s %-8s %-10s %-12s %s${C_RST}\n" "FILE" "PID" "STATUS" "LINES" "HOST"
    printf "%-30s %-8s %-10s %-12s %s\n" "------------------------------" "--------" "----------" "------------" "--------------------"

    for pidf in "${pid_files[@]}"; do
        local datafile="${pidf%.pid}"
        local pid
        pid=$(cat "${pidf}" 2>/dev/null || echo "?")
        local status="unknown" lines="?" hostinfo="?"

        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            status="${C_GRE}running${C_RST}"
        else
            status="${C_RED}stopped${C_RST}"
        fi

        if [[ -f "${datafile}" ]]; then
            lines=$(wc -l < "${datafile}")
            # Subtract header lines (comments + CSV header)
            local header_lines
            header_lines=$(grep -c '^#\|^timestamp,' "${datafile}" 2>/dev/null || echo 0)
            lines=$((lines - header_lines))
            [[ ${lines} -lt 0 ]] && lines=0

            hostinfo=$(grep '^# host=' "${datafile}" 2>/dev/null | head -1 | sed 's/^# host=//')
        fi

        printf "%-30s %-8s " "${datafile}" "${pid}"
        printf "%b" "${status}"
        printf "    %-12s %s\n" "${lines} pings" "${hostinfo}"
    done
    printf "\n"
}

_show_file_info() {
    local file="$1" pid="$2"
    if [[ ! -f "${file}" ]]; then
        return
    fi

    local hostinfo started lines header_lines
    hostinfo=$(grep '^# host=' "${file}" 2>/dev/null | head -1 | sed 's/^# host=//')
    started=$(grep '^# started=' "${file}" 2>/dev/null | head -1 | sed 's/^# started=//')
    lines=$(wc -l < "${file}")
    header_lines=$(grep -c '^#\|^timestamp,' "${file}" 2>/dev/null || echo 0)
    lines=$((lines - header_lines))
    [[ ${lines} -lt 0 ]] && lines=0

    printf "\n${C_CYA}File:${C_RST}    %s\n" "${file}"
    printf "${C_CYA}Host:${C_RST}    %s\n" "${hostinfo}"
    printf "${C_CYA}Started:${C_RST} %s\n" "${started}"
    printf "${C_CYA}Pings:${C_RST}   %d\n" "${lines}"
    if [[ -n "${pid}" ]]; then
        printf "${C_CYA}PID:${C_RST}     %s\n" "${pid}"
    fi
    printf "\n"
}

# =============================================================================
# cmd_pingcheck - Find consecutive ping drops (single-pass awk)
# =============================================================================
cmd_pingcheck() {
    local file="" count=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) file="$2"; shift 2 ;;
            -c) count="$2"; shift 2 ;;
            *)  die "Unknown option for pingcheck: $1" ;;
        esac
    done

    require_arg "FILE" "${file}" "-f"
    require_arg "COUNT" "${count}" "-c"
    require_file "${file}"

    if ! [[ "${count}" =~ ^[0-9]+$ ]] || [[ "${count}" -eq 0 ]]; then
        die "Count (-c) must be a positive integer: ${count}"
    fi

    local hostinfo
    hostinfo=$(grep '^# host=' "${file}" | head -1 | sed 's/^# host=//')

    # Check if there are any timeouts at all
    local timeout_count
    timeout_count=$(awk -F',' '/^[^#]/ && !/^timestamp/ && $3 == "timeout" { n++ } END { print n+0 }' "${file}")

    if [[ "${timeout_count}" -eq 0 ]]; then
        printf "\n${C_GRE}No missed pings found in data for host ${hostinfo}.${C_RST}\n\n"
        return
    fi

    local ok_count
    ok_count=$(awk -F',' '/^[^#]/ && !/^timestamp/ && $3 == "ok" { n++ } END { print n+0 }' "${file}")

    if [[ "${ok_count}" -eq 0 ]]; then
        printf "\n${C_RED}Only missed pings found (${timeout_count} total). No successful pings.${C_RST}\n\n"
        return
    fi

    printf "\n${C_CYA}Remote Host:${C_RST} ${hostinfo}\n"
    printf "${C_CYA}Minimum consecutive drops:${C_RST} ${count}\n\n"
    printf "${C_CYA}%-26s %-26s %s${C_RST}\n" "Start time" "End time" "Total missed"
    printf "%-26s %-26s %s\n" "--------------------------" "--------------------------" "------------"

    awk -F',' -v min_count="${count}" '
    /^#/ || /^timestamp/ { next }
    {
        ts = $1
        status = $3
    }
    status == "timeout" {
        if (run_count == 0) { run_start = ts }
        run_count++
        run_end = ts
        next
    }
    {
        # Not a timeout -- flush any accumulated run
        if (run_count >= min_count) {
            printf "%-26s %-26s %d\n", run_start, run_end, run_count
        }
        run_count = 0
    }
    END {
        # Flush final run if file ends with timeouts
        if (run_count >= min_count) {
            printf "%-26s %-26s %d\n", run_start, run_end, run_count
        }
    }' "${file}"

    printf "\n"
}

# =============================================================================
# cmd_latencycheck - Latency distribution by day (single-pass awk)
# =============================================================================
cmd_latencycheck() {
    local file="" date_filter="" buckets="0,10,20,30,40,50,60,70,80,90,100"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) file="$2"; shift 2 ;;
            -d) date_filter="$2"; shift 2 ;;
            -b) buckets="$2"; shift 2 ;;
            *)  die "Unknown option for latencycheck: $1" ;;
        esac
    done

    require_arg "FILE" "${file}" "-f"
    require_file "${file}"

    # Validate date filter format if provided
    if [[ -n "${date_filter}" ]]; then
        if ! [[ "${date_filter}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            die "Invalid date format. Use YYYY-MM-DD (e.g. 2026-03-26)"
        fi
    fi

    local hostinfo
    hostinfo=$(grep '^# host=' "${file}" | head -1 | sed 's/^# host=//')

    printf "\n${C_CYA}Remote Host:${C_RST} ${hostinfo}\n"

    awk -F',' -v buckets_str="${buckets}" -v date_filter="${date_filter}" '
    BEGIN {
        # Parse bucket boundaries
        n_bounds = split(buckets_str, bounds, ",")
        # Sort bounds (simple insertion sort, they should be small)
        for (i = 2; i <= n_bounds; i++) {
            val = bounds[i] + 0
            j = i - 1
            while (j >= 1 && bounds[j] + 0 > val) {
                bounds[j+1] = bounds[j]
                j--
            }
            bounds[j+1] = val
        }
        n_buckets = n_bounds  # includes the "above last" bucket
    }

    /^#/ || /^timestamp/ { next }

    {
        ts = $1
        latency = $2 + 0
        status = $3

        # Extract date (YYYY-MM-DD) from ISO timestamp
        day = substr(ts, 1, 10)

        # Apply date filter
        if (date_filter != "" && day != date_filter) next

        # Track day order
        if (!(day in day_seen)) {
            day_seen[day] = 1
            day_order[++n_days] = day
        }

        if (status == "timeout") {
            timeouts[day]++
            next
        }

        # Find the right bucket
        placed = 0
        for (i = 1; i < n_bounds; i++) {
            low = bounds[i] + 0
            high = bounds[i+1] + 0
            if (latency >= low && latency < high) {
                key = day SUBSEP i
                bucket_counts[key]++
                placed = 1
                break
            }
        }
        # Above the highest boundary
        if (!placed) {
            key = day SUBSEP n_bounds
            bucket_counts[key]++
        }
    }

    END {
        for (d = 1; d <= n_days; d++) {
            day = day_order[d]
            printf "\nDate: %s\n", day

            for (i = 1; i < n_bounds; i++) {
                low = bounds[i] + 0
                high = bounds[i+1] + 0
                key = day SUBSEP i
                cnt = (key in bucket_counts) ? bucket_counts[key] : 0
                label = low "-" high " ms"
                printf "  %9s:  %d\n", label, cnt
            }
            # Above highest
            key = day SUBSEP n_bounds
            cnt = (key in bucket_counts) ? bucket_counts[key] : 0
            printf "  %9s:  %d\n", bounds[n_bounds] + 0 "+ ms", cnt

            to = (day in timeouts) ? timeouts[day] : 0
            printf "  %9s:  %d\n", "Missed", to
        }

        if (n_days == 0) {
            printf "\nNo data found"
            if (date_filter != "") printf " for date %s", date_filter
            printf ".\n"
        }
    }' "${file}"

    printf "\n"
}

# =============================================================================
# cmd_avglat - Rolling average latency (single-pass awk)
# =============================================================================
cmd_avglat() {
    local file="" count="30"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) file="$2"; shift 2 ;;
            -c) count="$2"; shift 2 ;;
            *)  die "Unknown option for avglat: $1" ;;
        esac
    done

    require_arg "FILE" "${file}" "-f"
    require_file "${file}"

    if ! [[ "${count}" =~ ^[0-9]+$ ]] || [[ "${count}" -eq 0 ]]; then
        die "Count (-c) must be a positive integer: ${count}"
    fi

    local hostinfo
    hostinfo=$(grep '^# host=' "${file}" | head -1 | sed 's/^# host=//')

    printf "%-19s   %-19s   %-18s %s\n" "Start Time" "End Time" "Avg Latency (ms)" "Missed Pings"

    awk -F',' -v window="${count}" '
    function fmt_ts(ts) {
        # Replace T separator with space and strip timezone offset
        gsub(/T/, " ", ts)
        sub(/[+-][0-9][0-9]:[0-9][0-9]$/, "", ts)
        return ts
    }
    /^#/ || /^timestamp/ { next }
    {
        ts = $1
        latency = $2 + 0
        status = $3

        idx++

        if (idx == 1) { win_start = ts }

        if (status == "timeout") {
            missed++
        } else {
            lat_sum += latency
        }

        if (idx == window) {
            win_end = ts
            if ((window - missed) > 0) {
                avg = lat_sum / (window - missed)
            } else {
                avg = 0
            }
            printf "%s - %s   %-18.2f %d\n", fmt_ts(win_start), fmt_ts(win_end), avg, missed

            # Reset window
            idx = 0
            lat_sum = 0
            missed = 0
        }
    }' "${file}"
}

# =============================================================================
# cmd_stats - Comprehensive summary statistics
# =============================================================================
cmd_stats() {
    local file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) file="$2"; shift 2 ;;
            *)  die "Unknown option for stats: $1" ;;
        esac
    done

    require_arg "FILE" "${file}" "-f"
    require_file "${file}"

    local hostinfo started ended
    hostinfo=$(grep '^# host=' "${file}" | head -1 | sed 's/^# host=//')
    started=$(grep '^# started=' "${file}" | head -1 | sed 's/^# started=//')
    ended=$(grep '^# ended=' "${file}" | head -1 | sed 's/^# ended=//' || true)

    # If no end marker, use the last data line's timestamp
    if [[ -z "${ended}" ]]; then
        ended=$(awk -F',' '/^[^#]/ && !/^timestamp/ { last=$1 } END { print last }' "${file}")
    fi

    printf "\n${C_CYA}Host:${C_RST}          %s\n" "${hostinfo}"
    printf "${C_CYA}Period:${C_RST}        %s -> %s\n" "${started}" "${ended}"

    # First pass with awk: compute count, sum, sum_sq, min, max, ok/timeout counts
    local summary
    summary=$(awk -F',' '
    /^#/ || /^timestamp/ { next }
    {
        total++
        if ($3 == "timeout") {
            timeouts++
            next
        }
        lat = $2 + 0
        ok++
        sum += lat
        sum_sq += lat * lat
        if (ok == 1 || lat < min_val) min_val = lat
        if (ok == 1 || lat > max_val) max_val = lat
    }
    END {
        if (ok > 0) {
            mean = sum / ok
            variance = (sum_sq / ok) - (mean * mean)
            if (variance < 0) variance = 0
            stddev = sqrt(variance)
        } else {
            mean = 0; stddev = 0; min_val = 0; max_val = 0
        }
        printf "%d %d %d %.4f %.4f %.4f %.4f", total, ok, timeouts, min_val, max_val, mean, stddev
    }' "${file}")

    local total ok_count timeouts min_val max_val mean_val stddev_val
    read -r total ok_count timeouts min_val max_val mean_val stddev_val <<< "${summary}"

    if [[ "${total}" -eq 0 ]]; then
        printf "\n${C_YEL}No data points found in file.${C_RST}\n\n"
        return
    fi

    # Second pass: extract sorted latencies for percentile calculation
    # We pipe only ok pings' latency through sort, then awk picks percentiles
    local percentiles
    percentiles=$(awk -F',' '
    /^#/ || /^timestamp/ { next }
    $3 == "ok" { print $2 + 0 }
    ' "${file}" | sort -n | awk -v n="${ok_count}" '
    BEGIN {
        # Target percentile positions (1-indexed)
        p50_pos = int(n * 0.50 + 0.5)
        p95_pos = int(n * 0.95 + 0.5)
        p99_pos = int(n * 0.99 + 0.5)
        if (p50_pos < 1) p50_pos = 1
        if (p95_pos < 1) p95_pos = 1
        if (p99_pos < 1) p99_pos = 1
    }
    {
        i++
        if (i == p50_pos) median = $1
        if (i == p95_pos) p95 = $1
        if (i == p99_pos) p99 = $1
    }
    END {
        printf "%.4f %.4f %.4f", median+0, p95+0, p99+0
    }')

    local median p95 p99
    read -r median p95 p99 <<< "${percentiles}"

    # Calculate loss percentage
    local loss_pct
    if [[ "${total}" -gt 0 ]]; then
        loss_pct=$(awk "BEGIN { printf \"%.2f\", (${timeouts} / ${total}) * 100 }")
    else
        loss_pct="0.00"
    fi

    printf "${C_CYA}Total pings:${C_RST}   %'d\n" "${total}"
    printf "${C_CYA}Successful:${C_RST}    %'d (%.2f%%)\n" "${ok_count}" "$(awk "BEGIN { printf \"%.2f\", (${ok_count}/${total})*100 }")"
    printf "${C_CYA}Missed:${C_RST}        %'d (${C_RED}%s%%${C_RST})\n" "${timeouts}" "${loss_pct}"
    printf "\n${C_CYA}Latency (ms):${C_RST}\n"
    printf "  ${C_WHI}Min:${C_RST}         %s\n" "${min_val}"
    printf "  ${C_WHI}Max:${C_RST}         %s\n" "${max_val}"
    printf "  ${C_WHI}Mean:${C_RST}        %s\n" "${mean_val}"
    printf "  ${C_WHI}Median:${C_RST}      %s\n" "${median}"
    printf "  ${C_WHI}P95:${C_RST}         %s\n" "${p95}"
    printf "  ${C_WHI}P99:${C_RST}         %s\n" "${p99}"
    printf "  ${C_WHI}Jitter:${C_RST}      %s (stddev)\n" "${stddev_val}"
    printf "\n"
}

# =============================================================================
# Main: parse subcommand and dispatch
# =============================================================================
main() {
    if [[ $# -eq 0 ]]; then
        cmd_help
        exit ${EXIT_USAGE}
    fi

    local command="$1"
    shift

    case "${command}" in
        start)              cmd_start "$@" ;;
        stop)               cmd_stop "$@" ;;
        status)             cmd_status "$@" ;;
        pingcheck|pc)       cmd_pingcheck "$@" ;;
        latencycheck|lc)    cmd_latencycheck "$@" ;;
        avglat|al)          cmd_avglat "$@" ;;
        stats)              cmd_stats "$@" ;;
        help)               cmd_help "$@" ;;
        -h|--help)          cmd_help ;;
        --version)          printf "pingtest.sh v%s\n" "${VERSION}" ;;
        *)                  die "Unknown command: ${command} (see: ${SCRIPT_NAME} help)" ;;
    esac
}

main "$@"
