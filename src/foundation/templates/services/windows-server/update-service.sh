#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Server Service - Update
#
# Runs security-only Windows Updates on a consuming module's Windows Server VM.
# Automatic Windows Update is disabled; this script is the sole update mechanism.
#
# Strategy:
#   - Only installs "Security Updates" category (no feature/driver updates)
#   - Temporarily enables the Windows Update service, installs, then disables
#   - Reboots ONLY if Windows reports a reboot is required
#   - A Proxmox snapshot is created before rebooting (by update-module.sh)
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Runs security-only Windows Updates for the specified module."
    exit 1
fi

MODULE_NAME="$1"

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$MODULE_NAME")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'srv')"
VM_HOST="${VMNAME}.${ZONE0}.internal"
MGMT="mgmt"

readonly SSH_OPTS="-o ConnectTimeout=30 -o BatchMode=yes -o LogLevel=ERROR"

info "=== Windows Security Update ==="
info "VM: ${VMNAME} (VMID: ${VMID}) on ${NODE}"

# Step 1: Enable Windows Update service temporarily
info "  Enabling Windows Update service..."
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
    Set-Service -Name wuauserv -StartupType Manual
    Start-Service wuauserv
    Write-Output 'Windows Update service started'
\"" || true

# Step 2: Install security updates only
info "  Checking for security updates..."
# shellcheck disable=SC2086
update_result=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
    Import-Module PSWindowsUpdate

    # Get available security updates
    \$available = Get-WindowsUpdate -Category 'Security Updates' -IgnoreReboot
    if (\$available.Count -eq 0) {
        Write-Output 'UPDATES:0|REBOOT:False'
        exit 0
    }

    Write-Output \"Found \$(\$available.Count) security update(s):\"
    foreach (\$u in \$available) {
        Write-Output \"  - \$(\$u.Title)\"
    }

    # Install the updates
    \$installed = Get-WindowsUpdate -Category 'Security Updates' -AcceptAll -Install -IgnoreReboot
    \$rebootNeeded = (Get-WURebootStatus).RebootRequired
    Write-Output \"UPDATES:\$(\$installed.Count)|REBOOT:\$rebootNeeded\"
\"" 2>/dev/null) || true

info "  ${update_result}"

# Step 3: Disable Windows Update service again
info "  Disabling Windows Update service..."
# shellcheck disable=SC2086
ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Set-Service -Name wuauserv -StartupType Disabled
    Write-Output 'Windows Update service disabled'
\"" || true

# Step 4: Reboot only if required
if [[ "${update_result}" == *"REBOOT:True"* ]]; then
    info "  Reboot required after security updates"
    info "  Rebooting VM..."
    ssh "root@${NODE}.${MGMT}.internal" "qm reboot ${VMID}" || true
    info "  Waiting 120 seconds for VM to restart..."
    sleep 120

    # Wait for SSH to become available
    local max_wait=300
    local waited=0
    info "  Waiting for SSH to become available on ${VM_HOST}..."
    while ! ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; do
        sleep 10
        waited=$((waited + 10))
        if [[ ${waited} -ge ${max_wait} ]]; then
            error "  SSH not available on ${VM_HOST} after ${max_wait}s"
            exit 1
        fi
    done
    info "  VM is back online after reboot"
elif [[ "${update_result}" == *"UPDATES:0"* ]]; then
    info "  No security updates available — system is up to date"
else
    info "  Updates installed — no reboot required"
fi

info "=== Windows Security Update complete ==="
