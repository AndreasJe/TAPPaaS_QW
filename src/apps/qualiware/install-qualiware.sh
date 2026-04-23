#!/usr/bin/env bash
#
# TAPPaaS QualiWare Module - Application Installer
#
# Mounts the QualiWare Suite ISO on the VM, detects whether this is a
# fresh install or an upgrade, runs UnattendedInstaller.exe accordingly,
# then unmounts the ISO and configures Defender exclusions.
#
# Fresh install : UnattendedInstaller.exe /dataPath:"..." /p:...
# Upgrade       : UnattendedInstaller.exe /change /dataPath:"..." /p:...
#
# Detection     : Presence of the QEF Windows service on the target VM.
#
# Usage: ./install-qualiware.sh <vmname>
# Example: ./install-qualiware.sh qualiware
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ──────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
readonly VMNAME VMID NODE ZONE0NAME

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${VMNAME}.json"

QW_ISO=$(jq -r '.qualiware.installerIso // ""'         "${MODULE_JSON}")
QEF_DATABASE=$(jq -r '.qualiware.QEFDatabase // "QEF"'         "${MODULE_JSON}")
SQL_USER=$(jq -r '.qualiware.SQLUser // "sqlQualiWareQEF"'      "${MODULE_JSON}")
DB_SERVER=$(jq -r '.qualiware.DatabaseServer // "localhost"'    "${MODULE_JSON}")
INTEGRATION_PORTS=$(jq -r '.qualiware.IntegrationPorts // "25780-25799"' "${MODULE_JSON}")

# Credentials — read from the secrets file, never from git-tracked config.
# Create /home/tappaas/secrets/qualiware.env before running this script.
# See src/apps/qualiware/qualiware.secrets.template for the format.
readonly SECRETS_FILE="/home/tappaas/secrets/${VMNAME}.env"
QEF_ADMIN_USER="Admin"
QEF_ADMIN_PASSWORD=""
SQL_PASSWORD=""
if [[ -f "${SECRETS_FILE}" ]]; then
    # shellcheck source=/dev/null
    . "${SECRETS_FILE}"
fi
if [[ -z "${QEF_ADMIN_PASSWORD:-}" ]]; then
    error "QEF_ADMIN_PASSWORD is not set."
    error "  Create ${SECRETS_FILE} containing:"
    error "    QEF_ADMIN_USER=Admin"
    error "    QEF_ADMIN_PASSWORD=<your-password>"
    error "    SQL_PASSWORD=<your-sql-password>"
    error "  See src/apps/qualiware/qualiware.secrets.template for the full format."
    exit 1
fi
if [[ -z "${SQL_PASSWORD:-}" ]]; then
    error "SQL_PASSWORD is not set."
    error "  Add SQL_PASSWORD=<your-password> to ${SECRETS_FILE}"
    exit 1
fi

NODE_FQDN="${NODE}.mgmt.internal"
readonly QW_ISO_SLOT="ide3"
QW_ISO_MOUNTED=false

readonly SSH_OPTS="-o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# ── SSH preflight validation ────────────────────────────────────────────

validate_ssh_access() {
    local host="$1"
    local user="${2:-tappaas}"
    local max_attempts="${3:-3}"
    local wait=10
    local attempt

    info "Validating SSH access to ${user}@${host} ..."

    if ! getent hosts "${host}" &>/dev/null; then
        error "Cannot resolve '${host}' — the VM may not be running or DNS is not configured."
        error ""
        error "  Check VM status : qm status ${VMID}"
        error "  Check DNS       : getent hosts ${host}"
        exit 1
    fi
    info "  ✓ DNS: ${host} resolved"

    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        # shellcheck disable=SC2086
        if ssh ${SSH_OPTS} "${user}@${host}" "exit 0" &>/dev/null; then
            info "  ✓ SSH: connected to ${user}@${host}"
            break
        fi
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            warn "  SSH not ready — retrying in ${wait}s (${attempt}/${max_attempts}) ..."
            sleep "${wait}"
            continue
        fi
        error "Cannot connect via SSH to ${user}@${host} after ${max_attempts} attempts."
        error ""
        error "  Common fixes:"
        error "    1. Install and start OpenSSH on the VM (elevated PowerShell):"
        error "         Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
        error "         Set-Service -Name sshd -StartupType Automatic"
        error "         Start-Service sshd"
        error "    2. Authorise the tappaas SSH key on the VM:"
        error "         Copy the public key into C:\\ProgramData\\ssh\\administrators_authorized_keys"
        error "         icacls administrators_authorized_keys /inheritance:r"
        error "         icacls administrators_authorized_keys /grant \"SYSTEM:(F)\" /grant \"Administrators:(F)\""
        error "    3. Check the VM is running : qm status ${VMID}"
        error "    4. Check port 22 is open   : nc -zv ${host} 22"
        exit 1
    done

    local ps_ver
    # shellcheck disable=SC2086
    ps_ver=$(ssh ${SSH_OPTS} "${user}@${host}" \
        "powershell -NoProfile -NonInteractive -Command \"\$PSVersionTable.PSVersion.Major\"" \
        2>/dev/null) || true

    if [[ -z "${ps_ver}" ]]; then
        error "SSH connected but PowerShell is not accessible on ${host}."
        error "  The default SSH shell for '${user}' may not be PowerShell."
        error ""
        error "  Fix (run as Administrator on the VM):"
        error "    New-ItemProperty -Path 'HKLM:\\SOFTWARE\\OpenSSH' \\"
        error "      -Name DefaultShell \\"
        error "      -Value 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe' \\"
        error "      -PropertyType String -Force"
        exit 1
    fi

    info "  ✓ PowerShell ${ps_ver}.x accessible via SSH"
}

# ── Prerequisites validation ────────────────────────────────────────────

validate_prerequisites() {
    local host="$1"
    local user="${2:-tappaas}"
    local failed=0

    info ""
    info "Validating QualiWare prerequisites on ${VM_HOST} ..."

    # Check IIS (W3SVC)
    # shellcheck disable=SC2086
    local iis_status
    iis_status=$(ssh ${SSH_OPTS} "${user}@${host}" \
        "powershell -NoProfile -NonInteractive -Command \"\
            \$s = Get-Service -Name W3SVC -ErrorAction SilentlyContinue;\
            if (\$s -and \$s.Status -eq 'Running') { 'OK' }\
            elseif (\$s) { 'STOPPED' } else { 'MISSING' }\
        \"" 2>/dev/null) || true

    if [[ "${iis_status}" == "OK" ]]; then
        info "  ✓ IIS (W3SVC) is running"
    else
        error "  ✗ IIS not ready (status: ${iis_status:-no response})"
        error "    IIS is required because QualiWare serves its web interface through it."
        failed=$((failed + 1))
    fi

    # Check SQL Server (MSSQLSERVER)
    # shellcheck disable=SC2086
    local sql_status
    sql_status=$(ssh ${SSH_OPTS} "${user}@${host}" \
        "powershell -NoProfile -NonInteractive -Command \"\
            \$s = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue;\
            if (\$s -and \$s.Status -eq 'Running') { 'OK' }\
            elseif (\$s) { 'STOPPED' } else { 'MISSING' }\
        \"" 2>/dev/null) || true

    if [[ "${sql_status}" == "OK" ]]; then
        info "  ✓ SQL Server (MSSQLSERVER) is running"
    else
        error "  ✗ SQL Server not ready (status: ${sql_status:-no response})"
        error "    SQL Server is required — QualiWare stores all data in the QEF, AccessLog, and QLM databases."
        failed=$((failed + 1))
    fi

    # Check VirtIO guest agent (QEMU-GA)
    # shellcheck disable=SC2086
    local agent_status
    agent_status=$(ssh ${SSH_OPTS} "${user}@${host}" \
        "powershell -NoProfile -NonInteractive -Command \"\
            \$s = Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue;\
            if (\$s -and \$s.Status -eq 'Running') { 'OK' }\
            elseif (\$s) { 'STOPPED' } else { 'MISSING' }\
        \"" 2>/dev/null) || true

    if [[ "${agent_status}" == "OK" ]]; then
        info "  ✓ VirtIO guest agent (QEMU-GA) is running"
    else
        warn "  ⚠ VirtIO guest agent not running (status: ${agent_status:-no response})"
        warn "    The guest agent enables Proxmox to manage the VM (shutdown, snapshots, etc.)."
        warn "    Install virtio-win-guest-tools.exe from the VirtIO ISO to fix this."
        warn "    Continuing — not required for the QualiWare installer itself."
    fi

    if [[ ${failed} -gt 0 ]]; then
        error ""
        error "${failed} prerequisite(s) not satisfied — cannot run the QualiWare installer."
        error ""
        error "  install-service.sh sets up the Windows baseline that QualiWare depends on:"
        error "    • IIS            — hosts the QualiWare web interface"
        error "    • SQL Server     — stores QualiWare data (QEF, AccessLog, QLM databases)"
        error "    • SQL login      — ${SQL_USER} with db_owner on each database"
        error "    • VC++ runtimes  — required by QualiWare binaries"
        error "    • Firewall rules — opens ports 80 and ${INTEGRATION_PORTS}"
        error ""
        error "  Run it first:"
        error "    ./install-service.sh ${VMNAME}"
        exit 1
    fi

    info "  All required prerequisites satisfied."
    info ""
}

# ── Cleanup ────────────────────────────────────────────────────────────

cleanup_iso() {
    if [[ "${QW_ISO_MOUNTED:-false}" == "true" ]]; then
        warn "Cleaning up: unmounting QualiWare ISO from VMID ${VMID} ..."
        ssh -o BatchMode=yes root@"${NODE_FQDN}" \
            "qm set ${VMID} --delete ${QW_ISO_SLOT}" 2>/dev/null || true
    fi
}

# ── Main ───────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        echo "Usage: ${SCRIPT_NAME} <vmname>"
        exit 0
    fi

    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        exit 1
    fi

    trap cleanup_iso EXIT ERR

    echo ""
    info "=== QualiWare Application Installer ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"

    if [[ -z "${QW_ISO}" ]]; then
        warn "qualiware.installerIso is not set in ${MODULE_JSON} — skipping"
        warn "Set it to the ISO filename in Proxmox local storage"
        exit 0
    fi

    # ── Validate SSH and prerequisites ────────────────────────────────
    validate_ssh_access "${VM_HOST}"
    validate_prerequisites "${VM_HOST}"

    # ── Detect install vs upgrade ──────────────────────────────────────
    info ""
    info "Detecting existing QualiWare installation ..."
    # shellcheck disable=SC2086
    QW_INSTALLED=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "powershell -NoProfile -NonInteractive -Command \"\
            if (Get-Service -Name 'QEF' -ErrorAction SilentlyContinue) { 'true' } else { 'false' }\
        \"" 2>/dev/null || echo "false")

    local qw_mode
    if [[ "${QW_INSTALLED}" == "true" ]]; then
        qw_mode="/change"
        info "QEF service detected — running upgrade (/change)"
    else
        qw_mode=""
        info "QEF service not found — running fresh installation"
    fi

    # ── Mount ISO ──────────────────────────────────────────────────────
    info ""
    info "Mounting ${QW_ISO} on VMID ${VMID} via ${NODE_FQDN} ..."
    ssh -o BatchMode=yes root@"${NODE_FQDN}" \
        "qm set ${VMID} --${QW_ISO_SLOT} local:iso/${QW_ISO},media=cdrom"
    QW_ISO_MOUNTED=true

    # ── Run installer ─────────────────────────────────────────────────
    if [[ -z "${qw_mode}" ]]; then

        # Fresh install — SuiteInstallerC.exe with full connection strings
        info "Running SuiteInstallerC.exe /install on ${VM_HOST} ..."
        # shellcheck disable=SC2086
        ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
            \$installerDrive = ''
            foreach (\$d in [System.IO.DriveInfo]::GetDrives()) {
                if (\$d.DriveType -eq 'CDRom' -and (Test-Path (\$d.Name + 'Suite'))) {
                    \$installerDrive = \$d.Name
                    break
                }
            }
            if (-not \$installerDrive) {
                throw 'QualiWare Suite not found on any CD-ROM drive. Check the ISO is mounted.'
            }
            Write-Output ('Installer drive: ' + \$installerDrive)

            \$suiteExe = Get-ChildItem -Path \$installerDrive -Recurse \
                -Filter 'SuiteInstallerC.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not \$suiteExe) {
                throw 'SuiteInstallerC.exe not found on drive ' + \$installerDrive + '. Check the ISO contents.'
            }
            Write-Output ('Found installer at: ' + \$suiteExe.FullName)

            \$tmpDir = 'C:\Temp\QWSuiteInstall'
            if (Test-Path \$tmpDir) { Remove-Item \$tmpDir -Recurse -Force }
            New-Item -ItemType Directory -Path \$tmpDir -Force | Out-Null
            Copy-Item -Path (\$suiteExe.DirectoryName + '\*') -Destination \$tmpDir -Recurse -Force
            \$exePath = Join-Path \$tmpDir 'SuiteInstallerC.exe'
            if (-not (Test-Path \$exePath)) {
                throw 'SuiteInstallerC.exe not found in temp directory after copy'
            }

            \$instance  = 'QEF'
            \$dbServer  = '${DB_SERVER}'
            \$qefDb     = '${QEF_DATABASE}'
            \$sqlUser   = '${SQL_USER}'
            \$sqlPass   = '${SQL_PASSWORD}'
            \$adminUser = '${QEF_ADMIN_USER}'
            \$adminPwd  = '${QEF_ADMIN_PASSWORD}'

            \$connBase = 'data source=' + \$dbServer + ';initial catalog=' + \$qefDb + \
                         ';password=' + \$sqlPass + ';user id=' + \$sqlUser
            \$qefConn  = 'provider name=DatabaseProviders.Qef.MSSql;schema name=dbo;' + \$connBase
            \$qisConn  = 'provider name=DatabaseProviders.Qis.MSSql;schema name=qis;' + \$connBase
            \$qnsConn  = 'provider name=DatabaseProviders.Qns.MSSql;schema name=qns;' + \$connBase

            \$installerArgs = @(
                '/install',
                '/p:QefFolder=C:\Program Files\Qualiware\' + \$instance,
                '/p:InstanceName=' + \$instance,
                '/p:QefDatabase=' + \$qefConn,
                '/p:QefUserName=' + \$adminUser,
                '/p:QefUserPwdCmd=' + \$adminPwd,
                '/p:QisDatabaseRepositoryDefinitionDb=' + \$qisConn,
                '/p:QnsDatabaseQnsDb=' + \$qnsConn,
                '/p:QefSpnSkipCheck=True'
            )
            Write-Output 'Running SuiteInstallerC.exe /install ...'

            \$proc = Start-Process -FilePath \$exePath \
                -ArgumentList \$installerArgs \
                -WorkingDirectory \$tmpDir \
                -Wait -PassThru -NoNewWindow
            if (\$proc.ExitCode -ne 0) {
                throw ('SuiteInstallerC.exe exited with code: ' + \$proc.ExitCode)
            }
            Write-Output 'Fresh QualiWare installation completed successfully'
            Remove-Item \$tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        \"" || {
            error "QualiWare fresh installation failed"
            exit 1
        }

    else

        # Upgrade — UnattendedInstaller.exe /change with installData.cfg
        info "Running UnattendedInstaller.exe /change (upgrade) on ${VM_HOST} ..."
        # shellcheck disable=SC2086
        ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
            \$installerDrive = ''
            foreach (\$d in [System.IO.DriveInfo]::GetDrives()) {
                if (\$d.DriveType -eq 'CDRom' -and (Test-Path (\$d.Name + 'Suite\Unattended installer files\Install.bat'))) {
                    \$installerDrive = \$d.Name
                    break
                }
            }
            if (-not \$installerDrive) {
                throw 'Installer not found on any CD-ROM drive. Check ISO is mounted and contains Suite\Unattended installer files\'
            }
            Write-Output ('Installer drive: ' + \$installerDrive)

            \$srcDir   = \$installerDrive + 'Suite'
            \$tmpDir   = 'C:\Temp\QWSuite'
            \$unattDir = \$tmpDir + '\Unattended installer files'

            Write-Output ('Copying Suite folder to ' + \$tmpDir)
            if (Test-Path \$tmpDir) { Remove-Item \$tmpDir -Recurse -Force }
            Copy-Item -Path \$srcDir -Destination \$tmpDir -Recurse -Force

            \$sampleCfg = \$unattDir + '\installData.cfg.sample'
            \$cfg       = \$unattDir + '\installData.cfg'
            if (-not (Test-Path \$sampleCfg)) {
                throw ('installData.cfg.sample not found in ' + \$unattDir)
            }
            Rename-Item -Path \$sampleCfg -NewName 'installData.cfg'
            Write-Output 'Renamed installData.cfg.sample -> installData.cfg'

            \$exePath = \$unattDir + '\UnattendedInstaller.exe'
            \$dataArg = '/dataPath:' + [char]34 + \$cfg + [char]34
            \$installerArgs = @('/change', \$dataArg, \
                '/p:QefUserName=${QEF_ADMIN_USER}', \
                '/p:QefUserPwdCmd=${QEF_ADMIN_PASSWORD}')
            Write-Output ('Running: ' + \$exePath + ' ' + (\$installerArgs -join ' '))

            \$proc = Start-Process -FilePath \$exePath \
                -ArgumentList \$installerArgs \
                -WorkingDirectory \$unattDir \
                -Wait -PassThru -NoNewWindow
            if (\$proc.ExitCode -ne 0) {
                throw ('UnattendedInstaller.exe exited with code: ' + \$proc.ExitCode)
            }
            Write-Output 'QualiWare upgrade completed successfully'
            Remove-Item \$tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        \"" || {
            error "QualiWare upgrade failed"
            exit 1
        }

    fi

    # ── Unmount ISO ────────────────────────────────────────────────────
    info "Unmounting ISO ..."
    ssh -o BatchMode=yes root@"${NODE_FQDN}" \
        "qm set ${VMID} --delete ${QW_ISO_SLOT}" || true
    QW_ISO_MOUNTED=false

    # ── Defender exclusions ────────────────────────────────────────────
    info "Configuring Defender exclusions ..."
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"
        \$qwPaths = @(
            'C:\Program Files\QualiWare',
            'C:\Program Files\QualiWare\QEF\Modules\QualiWare Integration Server'
        )
        \$qwProcesses = @(
            'Qdc.Module.exe', 'Qef.exe', 'Qis.Module.exe',
            'QProcessManager.exe', 'Qts.Module.exe', 'Qwc32.exe'
        )
        Set-MpPreference -ExclusionPath \$qwPaths -ErrorAction SilentlyContinue
        Set-MpPreference -ExclusionProcess \$qwProcesses -ErrorAction SilentlyContinue
        Write-Output 'Defender exclusions configured'
    \"" || true

    echo ""
    info "=== QualiWare Installation Complete ==="
}

main "$@"
