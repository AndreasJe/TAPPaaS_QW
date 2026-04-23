#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Server Service - Test
#
# Verifies that Windows Server baseline configuration is correctly applied
# to a consuming module's VM. Validates all requirements from the
# QualiWare Pre-Installation Document.
#
# Tests:
#   1. SSH connectivity (Windows OpenSSH)
#   2. Windows Roles & Features (IIS, File Server)
#   3. Visual C++ Redistributables
#   4. SQL Server running and accessible
#   5. SQL databases exist with correct collation
#   6. SQL service account has DB_OWNER
#   7. Windows Firewall rules
#   Deep mode:
#   8. SQL Server Management Studio installed
#   9. Windows Defender exclusions configured
#  10. Windows Update is TAPPaaS-managed (auto-update disabled)
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"

if [[ ! -f "${MODULE_JSON}" ]]; then
    error "Module config not found: ${MODULE_JSON}"
    exit 2
fi

VMNAME=$(jq -r '.vmname // empty' "${MODULE_JSON}")
ZONE0=$(jq -r '.zone0 // "srv"' "${MODULE_JSON}")
VM_HOST="${VMNAME}.${ZONE0}.internal"

QEF_DATABASE=$(jq -r '.qualiware.QEFDatabase // "QEF"' "${MODULE_JSON}")
SQL_USER=$(jq -r '.qualiware.SQLUser // "sqlQualiWareQEF"' "${MODULE_JSON}")

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0

readonly SSH_OPTS="-o ConnectTimeout=30 -o BatchMode=yes -o LogLevel=ERROR"

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

# Helper: run PowerShell and return output
run_ps() {
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"$1\"" 2>/dev/null
}

info "  ${BOLD}templates:windows-server tests for ${BL}${MODULE}${CL}"
info "    VM: ${VM_HOST}"

# ── Test 1: SSH connectivity ────────────────────────────────────────

info "  Check 1: SSH connectivity (OpenSSH)"
# shellcheck disable=SC2086
if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; then
    pass "SSH connection successful"
else
    fail "SSH connection failed to tappaas@${VM_HOST}"
    info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
    exit 1
fi

# ── Test 2: Windows Roles & Features ────────────────────────────────

info "  Check 2: Windows Roles & Features"
features_result=$(run_ps '
    $required = @("Web-Server","Web-Default-Doc","Web-Static-Content","Web-Windows-Auth","Web-Mgmt-Console","FS-FileServer")
    $missing = @()
    foreach ($f in $required) {
        $state = (Get-WindowsFeature -Name $f).InstallState
        if ($state -ne "Installed") { $missing += $f }
    }
    if ($missing.Count -eq 0) { Write-Output "OK" }
    else { Write-Output "MISSING:$($missing -join ",")" }
') || true

if [[ "${features_result}" == "OK" ]]; then
    pass "All required roles & features installed"
else
    fail "Missing features: ${features_result#MISSING:}"
fi

# ── Test 3: Visual C++ Redistributables ─────────────────────────────

info "  Check 3: Visual C++ Redistributables"
vcredist_result=$(run_ps '
    $installed = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" |
                 Where-Object { $_.DisplayName -like "*Visual C++*" -and $_.DisplayName -like "*Redistributable*" }
    $count = ($installed | Measure-Object).Count
    Write-Output "COUNT:$count"
') || true

vcredist_count="${vcredist_result#COUNT:}"
if [[ -n "${vcredist_count}" && "${vcredist_count}" -ge 4 ]]; then
    pass "Visual C++ Redistributables installed (${vcredist_count} packages)"
else
    fail "Insufficient VC++ Redistributables (found: ${vcredist_count:-0}, need >= 4)"
fi

# ── Test 4: SQL Server running ──────────────────────────────────────

info "  Check 4: SQL Server"
sql_status=$(run_ps '
    $svc = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { Write-Output "RUNNING" }
    elseif ($svc) { Write-Output "STOPPED:$($svc.Status)" }
    else { Write-Output "NOTFOUND" }
') || true

if [[ "${sql_status}" == "RUNNING" ]]; then
    pass "SQL Server is running"
else
    fail "SQL Server not running (${sql_status:-no response})"
fi

# ── Test 5: Databases exist with correct collation ──────────────────

info "  Check 5: SQL Databases"
db_result=$(run_ps '
    $required = @("'"${QEF_DATABASE}"'", "AccessLog", "QLM")
    $missing = @()
    $wrongCollation = @()
    foreach ($db in $required) {
        $result = Invoke-Sqlcmd -Query "SELECT name, collation_name FROM sys.databases WHERE name = '"'"'$db'"'"'" -ErrorAction SilentlyContinue
        if (-not $result) { $missing += $db }
        elseif ($result.collation_name -ne "SQL_Latin1_General_CP1_CI_AS") {
            $wrongCollation += "$db($($result.collation_name))"
        }
    }
    if ($missing.Count -eq 0 -and $wrongCollation.Count -eq 0) { Write-Output "OK" }
    else {
        $msg = ""
        if ($missing.Count -gt 0) { $msg += "MISSING:$($missing -join ",")" }
        if ($wrongCollation.Count -gt 0) { $msg += " COLLATION:$($wrongCollation -join ",")" }
        Write-Output $msg.Trim()
    }
') || true

if [[ "${db_result}" == "OK" ]]; then
    pass "Databases exist with correct collation (SQL_Latin1_General_CP1_CI_AS)"
else
    fail "Database issues: ${db_result}"
fi

# ── Test 6: SQL service account permissions ─────────────────────────

info "  Check 6: SQL service account (${SQL_USER})"
account_result=$(run_ps '
    $login = Invoke-Sqlcmd -Query "SELECT name FROM sys.server_principals WHERE name = '"'"''"${SQL_USER}"''"'"'" -ErrorAction SilentlyContinue
    if (-not $login) { Write-Output "NOLOGIN"; exit 0 }

    $dbs = @("'"${QEF_DATABASE}"'", "AccessLog", "QLM")
    $notOwner = @()
    foreach ($db in $dbs) {
        $isOwner = Invoke-Sqlcmd -Query "
            USE [$db];
            SELECT IS_ROLEMEMBER('"'"'db_owner'"'"', '"'"''"${SQL_USER}"''"'"') AS IsOwner
        " -ErrorAction SilentlyContinue
        if (-not $isOwner -or $isOwner.IsOwner -ne 1) { $notOwner += $db }
    }
    if ($notOwner.Count -eq 0) { Write-Output "OK" }
    else { Write-Output "NOTOWNER:$($notOwner -join ",")" }
') || true

if [[ "${account_result}" == "OK" ]]; then
    pass "Service account '${SQL_USER}' is DB_OWNER on all databases"
elif [[ "${account_result}" == "NOLOGIN" ]]; then
    fail "SQL login '${SQL_USER}' does not exist"
else
    fail "Service account issue: ${account_result}"
fi

# ── Test 7: Windows Firewall rules ──────────────────────────────────

info "  Check 7: Windows Firewall rules"
fw_result=$(run_ps '
    $required = @(
        "QualiWare IIS HTTP",
        "QualiWare Integration Server",
        "QualiWare SMB TCP",
        "QualiWare SMB UDP",
        "QualiWare SQL Server"
    )
    $missing = @()
    foreach ($r in $required) {
        if (!(Get-NetFirewallRule -DisplayName $r -ErrorAction SilentlyContinue)) {
            $missing += $r
        }
    }
    if ($missing.Count -eq 0) { Write-Output "OK" }
    else { Write-Output "MISSING:$($missing -join ",")" }
') || true

if [[ "${fw_result}" == "OK" ]]; then
    pass "All firewall rules configured"
else
    fail "Missing firewall rules: ${fw_result#MISSING:}"
fi

# ── Deep mode tests ─────────────────────────────────────────────────

if [[ "${DEEP}" -eq 1 ]]; then

    # Test 8: SSMS installed
    info "  Check 8: SQL Server Management Studio"
    ssms_result=$(run_ps '
        $ssms = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
                Where-Object { $_.DisplayName -like "*SQL Server Management Studio*" }
        if ($ssms) { Write-Output "OK:$($ssms.DisplayVersion)" }
        else { Write-Output "NOTFOUND" }
    ') || true

    if [[ "${ssms_result}" == OK:* ]]; then
        pass "SSMS installed (${ssms_result#OK:})"
    else
        fail "SQL Server Management Studio not found"
    fi

    # Test 9: Windows Defender exclusions
    info "  Check 9: Windows Defender exclusions"
    defender_result=$(run_ps '
        $prefs = Get-MpPreference
        $requiredProcesses = @("Qef.exe","QProcessManager.exe")
        $missing = @()
        foreach ($p in $requiredProcesses) {
            if ($prefs.ExclusionProcess -notcontains $p) { $missing += $p }
        }
        if ($missing.Count -eq 0) { Write-Output "OK" }
        else { Write-Output "MISSING:$($missing -join ",")" }
    ') || true

    if [[ "${defender_result}" == "OK" ]]; then
        pass "Windows Defender exclusions configured"
    else
        fail "Defender exclusions: ${defender_result}"
    fi

    # Test 10: Windows Update is managed
    info "  Check 10: Windows Update configuration"
    wu_result=$(run_ps '
        $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        $startType = $svc.StartType
        $auReg = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name NoAutoUpdate -ErrorAction SilentlyContinue
        $psWU = Get-Module -ListAvailable -Name PSWindowsUpdate
        if ($startType -eq "Disabled" -and $auReg.NoAutoUpdate -eq 1 -and $psWU) {
            Write-Output "OK"
        } else {
            $issues = @()
            if ($startType -ne "Disabled") { $issues += "WUService:$startType" }
            if (!$auReg -or $auReg.NoAutoUpdate -ne 1) { $issues += "AutoUpdateNotDisabled" }
            if (!$psWU) { $issues += "PSWindowsUpdateMissing" }
            Write-Output "ISSUES:$($issues -join ",")"
        }
    ') || true

    if [[ "${wu_result}" == "OK" ]]; then
        pass "Windows Update is TAPPaaS-managed (auto-update disabled, PSWindowsUpdate installed)"
    else
        fail "Windows Update config: ${wu_result}"
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
fi
exit 0
