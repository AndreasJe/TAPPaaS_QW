#!/usr/bin/env bash
#
# TAPPaaS QualiWare Health & Regression Test
#
# Validates that the QualiWare module is running correctly by checking
# SSH connectivity, IIS, SQL Server, QualiWare services, and HTTP endpoint.
#
# Usage: ./test.sh <vmname>
# Example: ./test.sh qualiware
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ─────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
readonly VMNAME VMID ZONE0NAME

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

readonly SSH_OPTS="-o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SSH_AVAILABLE=false

# ── Helper functions ──────────────────────────────────────────────────

check_pass() {
    info "  ${GN}✓${CL} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

check_fail() {
    error "  ✗ $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_skip() {
    warn "  — $1 (skipped — SSH unavailable)"
    SKIP_COUNT=$((SKIP_COUNT + 1))
}

# Helper: run PowerShell on remote VM
run_ps() {
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"$1\"" 2>/dev/null
}

# ── Test functions ────────────────────────────────────────────────────

check_ssh() {
    info "Check 1: SSH connectivity to ${VM_HOST}"
    local attempt
    local max_attempts=6
    local wait_seconds=10

    # DNS preflight — fast-fail before burning retries
    if ! getent hosts "${VM_HOST}" &>/dev/null; then
        check_fail "Cannot resolve '${VM_HOST}' — VM may not be running or DNS is not set up"
        warn "         Check VM status : qm status ${VMID}"
        warn "         Check DNS       : getent hosts ${VM_HOST}"
        return
    fi
    debug "  DNS resolved: ${VM_HOST}"

    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        # shellcheck disable=SC2086
        if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; then
            SSH_AVAILABLE=true
            check_pass "SSH connection successful"
            return
        fi
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            debug "  SSH not ready, retrying in ${wait_seconds}s (${attempt}/${max_attempts})..."
            sleep "${wait_seconds}"
        fi
    done

    check_fail "SSH connection failed to tappaas@${VM_HOST} after ${max_attempts} attempts"
    warn "         Ensure OpenSSH Server is installed and running on the VM."
    warn "         Check port 22: nc -zv ${VM_HOST} 22"
    warn "         Remaining checks will be skipped."
}

check_iis() {
    info "Check 2: IIS is running"
    [[ "${SSH_AVAILABLE}" == "true" ]] || { check_skip "IIS"; return; }
    local iis_status
    iis_status=$(run_ps '
        $svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { Write-Output "RUNNING" }
        elseif ($svc) { Write-Output "STOPPED:$($svc.Status)" }
        else { Write-Output "NOTFOUND" }
    ') || true

    if [[ "${iis_status}" == "RUNNING" ]]; then
        check_pass "IIS (W3SVC) is running"
    else
        check_fail "IIS not running (${iis_status:-no response})"
    fi
}

check_sql_server() {
    info "Check 3: SQL Server is running"
    [[ "${SSH_AVAILABLE}" == "true" ]] || { check_skip "SQL Server"; return; }
    local sql_status
    sql_status=$(run_ps '
        $svc = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { Write-Output "RUNNING" }
        elseif ($svc) { Write-Output "STOPPED:$($svc.Status)" }
        else { Write-Output "NOTFOUND" }
    ') || true

    if [[ "${sql_status}" == "RUNNING" ]]; then
        check_pass "SQL Server is running"
    else
        check_fail "SQL Server not running (${sql_status:-no response})"
    fi
}

check_http() {
    info "Check 4: HTTP health check on port 80 (IIS)"
    [[ "${SSH_AVAILABLE}" == "true" ]] || { check_skip "HTTP port 80"; return; }
    local http_code
    local attempt
    local max_attempts=6
    local wait_seconds=10

    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        # shellcheck disable=SC2086
        http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
            "powershell -Command \"try { (Invoke-WebRequest -Uri 'http://localhost/' -UseBasicParsing -TimeoutSec 10).StatusCode } catch { Write-Output 0 }\"" \
            2>/dev/null) || true

        if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
            check_pass "HTTP responding (status ${http_code})"
            return
        fi
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            debug "  HTTP not ready (status: ${http_code:-timeout}), retrying in ${wait_seconds}s (${attempt}/${max_attempts})..."
            sleep "${wait_seconds}"
        fi
    done

    check_fail "HTTP not responding after ${max_attempts} attempts (status: ${http_code:-timeout})"
}

check_qualiware_services() {
    info "Check 5: QualiWare services"
    [[ "${SSH_AVAILABLE}" == "true" ]] || { check_skip "QualiWare services"; return; }
    local qw_status
    qw_status=$(run_ps '
        $svc = Get-Service -Name "QEF" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { Write-Output "RUNNING" }
        elseif ($svc) { Write-Output "STOPPED:$($svc.Status)" }
        else { Write-Output "MISSING" }
    ') || true

    if [[ "${qw_status}" == "RUNNING" ]]; then
        check_pass "QualiWare (QEF) service is running"
    elif [[ "${qw_status}" == STOPPED:* ]]; then
        check_fail "QualiWare (QEF) service is installed but not running (${qw_status#STOPPED:})"
    elif [[ "${qw_status}" == "MISSING" ]]; then
        check_pass "QEF service not found — QualiWare not yet installed (expected before first install)"
    else
        check_fail "Could not check QEF service (${qw_status:-no response})"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        echo "Usage: ${SCRIPT_NAME} <vmname>"
        exit 0
    fi

    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        exit 1
    fi

    info "=== QualiWare Health Check ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"
    echo ""

    check_ssh
    check_iis
    check_sql_server
    check_http
    check_qualiware_services

    echo ""
    info "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        error "Health check FAILED — ${FAIL_COUNT} check(s) did not pass"
        exit 1
    fi

    if [[ "${SKIP_COUNT}" -gt 0 ]]; then
        warn "Health check INCOMPLETE — ${SKIP_COUNT} check(s) skipped due to SSH failure"
        exit 1
    fi

    info "${GN}All health checks passed${CL}"
    exit 0
}

main "$@"
