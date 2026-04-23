#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Server Service - Install
#
# Applies Windows Server baseline configuration to a consuming module's VM.
# Installs all prerequisites from the QualiWare Pre-Installation Document:
#
#   1. Visual C++ Redistributable Packages (2010 x86/x64, 2013, 2015)
#   2. Windows Roles & Features (IIS, File Server, Windows Auth)
#   3. SQL Server (latest) with correct collation
#   4. SQL Server Management Studio
#   5. Service Account creation and permissions
#   6. Database creation (QEF, AccessLog, QLM)
#   7. Windows Firewall rules
#   8. Windows Update configuration (security-only, TAPPaaS-managed)
#   9. Windows Defender antivirus exclusions
#
# Prerequisites:
#   - Windows Server 2025 VM must be running with OpenSSH Server enabled
#   - tappaas user must have Administrator privileges
#   - VirtIO guest agent must be installed
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Applies Windows Server baseline configuration for the specified module."
    exit 1
fi

MODULE_NAME="$1"

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "$MODULE_NAME")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0="$(get_config_value 'zone0' 'srv')"
VM_HOST="${VMNAME}.${ZONE0}.internal"

readonly SSH_OPTS="-o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Read QualiWare-specific config from module JSON
readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE_NAME}.json"
readonly SECRETS_FILE="/home/tappaas/secrets/${MODULE_NAME}.env"

QEF_DATABASE=$(jq -r '.qualiware.QEFDatabase // "QEF"' "${MODULE_JSON}")
SQL_USER=$(jq -r '.qualiware.SQLUser // "sqlQualiWareQEF"' "${MODULE_JSON}")
DB_SERVER=$(jq -r '.qualiware.DatabaseServer // "localhost"' "${MODULE_JSON}")
INTEGRATION_PORTS=$(jq -r '.qualiware.IntegrationPorts // "25780-25799"' "${MODULE_JSON}")

# SQL_PASSWORD is never stored in the module JSON — read from the local secrets file.
# Create /home/tappaas/secrets/<module>.env before running this script.
# See src/apps/qualiware/qualiware.secrets.template for the format.
SQL_PASSWORD=""
if [[ -f "${SECRETS_FILE}" ]]; then
    # shellcheck source=/dev/null
    . "${SECRETS_FILE}"
fi
if [[ -z "${SQL_PASSWORD:-}" ]]; then
    echo "ERROR: SQL_PASSWORD is not set." >&2
    echo "       Create ${SECRETS_FILE} containing:" >&2
    echo "         SQL_PASSWORD=<your-password>" >&2
    exit 1
fi
PORT_START="${INTEGRATION_PORTS%%-*}"
PORT_END="${INTEGRATION_PORTS##*-}"

info "=== Windows Server Baseline Configuration ==="
info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"
info "SQL User: ${SQL_USER}"
info "Database: ${QEF_DATABASE}"
info "DB Server: ${DB_SERVER}"
info "Integration Ports: ${INTEGRATION_PORTS}"

validate_ssh_access "${VM_HOST}"

# ── SSH preflight validation ──────────────────────────────────────────

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
    info ""
}

# ── Helper: run PowerShell on the remote Windows VM ─────────────────
run_ps() {
    local description="$1"
    local script="$2"
    info "  ${description}..."
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "powershell -NoProfile -NonInteractive -Command \"${script}\"" || {
        error "  Failed: ${description}"
        return 1
    }
}

# ── Step 1: Visual C++ Redistributable Packages ─────────────────────
info ""
info "Step 1: Visual C++ Redistributable Packages"

run_ps "Installing VC++ 2010 x86" '
    $url = "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x86.exe"
    $out = "$env:TEMP\vcredist2010_x86.exe"
    if (!(Test-Path "HKLM:\SOFTWARE\Microsoft\VisualStudio\10.0\VC\VCRedist\x86")) {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        Start-Process -Wait -FilePath $out -ArgumentList "/q /norestart"
        Remove-Item $out -Force
        Write-Output "Installed"
    } else { Write-Output "Already installed" }
'

run_ps "Installing VC++ 2010 x64" '
    $url = "https://download.microsoft.com/download/1/6/5/165255E7-1014-4D0A-B094-B6A430A6BFFC/vcredist_x64.exe"
    $out = "$env:TEMP\vcredist2010_x64.exe"
    if (!(Test-Path "HKLM:\SOFTWARE\Microsoft\VisualStudio\10.0\VC\VCRedist\x64")) {
        Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        Start-Process -Wait -FilePath $out -ArgumentList "/q /norestart"
        Remove-Item $out -Force
        Write-Output "Installed"
    } else { Write-Output "Already installed" }
'

run_ps "Installing VC++ 2013 x86+x64" '
    $url = "https://aka.ms/highdpimfc2013x86enu"
    $out = "$env:TEMP\vcredist2013_x86.exe"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    Start-Process -Wait -FilePath $out -ArgumentList "/quiet /norestart"
    Remove-Item $out -Force
    $url = "https://aka.ms/highdpimfc2013x64enu"
    $out = "$env:TEMP\vcredist2013_x64.exe"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    Start-Process -Wait -FilePath $out -ArgumentList "/quiet /norestart"
    Remove-Item $out -Force
    Write-Output "Installed"
'

run_ps "Installing VC++ 2015-2022 x86+x64" '
    $url86 = "https://aka.ms/vs/17/release/vc_redist.x86.exe"
    $url64 = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    $out86 = "$env:TEMP\vcredist2015_x86.exe"
    $out64 = "$env:TEMP\vcredist2015_x64.exe"
    Invoke-WebRequest -Uri $url86 -OutFile $out86 -UseBasicParsing
    Start-Process -Wait -FilePath $out86 -ArgumentList "/quiet /norestart"
    Remove-Item $out86 -Force
    Invoke-WebRequest -Uri $url64 -OutFile $out64 -UseBasicParsing
    Start-Process -Wait -FilePath $out64 -ArgumentList "/quiet /norestart"
    Remove-Item $out64 -Force
    Write-Output "Installed"
'

# ── Step 2: Windows Roles & Features ────────────────────────────────
info ""
info "Step 2: Windows Roles & Features"

run_ps "Installing IIS and File Server roles/features" '
    $features = @(
        "Web-Server",
        "Web-Default-Doc",
        "Web-Static-Content",
        "Web-Windows-Auth",
        "Web-Mgmt-Console",
        "FS-FileServer"
    )
    foreach ($f in $features) {
        $state = (Get-WindowsFeature -Name $f).InstallState
        if ($state -ne "Installed") {
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
            Write-Output "  Installed: $f"
        } else {
            Write-Output "  Already installed: $f"
        }
    }
'

# ── Step 3: SQL Server Installation ─────────────────────────────────
info ""
info "Step 3: SQL Server Installation"

run_ps "Downloading and installing SQL Server 2022" '
    # Check if SQL Server is already installed
    $sqlService = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    if ($sqlService) {
        Write-Output "SQL Server already installed"
        exit 0
    }

    # Download SQL Server 2022 Express installer
    $installerUrl = "https://go.microsoft.com/fwlink/p/?linkid=2216019&clcid=0x409&culture=en-us&country=us"
    $installerPath = "$env:TEMP\SQL2022-SSEI-Expr.exe"
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

    # Download the full media
    $mediaPath = "$env:TEMP\SQL2022Express"
    Start-Process -Wait -FilePath $installerPath -ArgumentList "/Action=Download /MediaPath=$mediaPath /MediaType=Core /Quiet"

    # Find the setup.exe in the downloaded media
    $setupExe = Get-ChildItem -Path $mediaPath -Recurse -Filter "setup.exe" | Select-Object -First 1

    # Run silent install
    $installArgs = @(
        "/Q"
        "/ACTION=Install"
        "/FEATURES=SQLENGINE,FULLTEXT"
        "/INSTANCENAME=MSSQLSERVER"
        "/SQLSVCACCOUNT=""NT Service\MSSQLSERVER"""
        "/SQLSYSADMINACCOUNTS=""BUILTIN\Administrators"""
        "/TCPENABLED=1"
        "/SECURITYMODE=SQL"
        "/SAPWD=""'"${SQL_PASSWORD}"'"""
        "/SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS"
        "/IACCEPTSQLSERVERLICENSETERMS"
        "/UpdateEnabled=False"
    )
    Start-Process -Wait -FilePath $setupExe.FullName -ArgumentList ($installArgs -join " ")

    # Verify installation
    $sqlService = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
    if ($sqlService -and $sqlService.Status -eq "Running") {
        Write-Output "SQL Server installed and running"
    } else {
        Write-Error "SQL Server installation may have failed"
        exit 1
    }

    # Cleanup
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue
    Remove-Item $mediaPath -Recurse -Force -ErrorAction SilentlyContinue
'

# ── Step 4: SQL Server Management Studio ────────────────────────────
info ""
info "Step 4: SQL Server Management Studio"

run_ps "Installing SSMS" '
    # Check if SSMS is already installed
    $ssms = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
            Where-Object { $_.DisplayName -like "*SQL Server Management Studio*" }
    if ($ssms) {
        Write-Output "SSMS already installed: $($ssms.DisplayVersion)"
        exit 0
    }

    $url = "https://aka.ms/ssmsfullsetup"
    $out = "$env:TEMP\SSMS-Setup-ENU.exe"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    Start-Process -Wait -FilePath $out -ArgumentList "/install /quiet /norestart"
    Remove-Item $out -Force
    Write-Output "SSMS installed"
'

# ── Step 5: Service Account & Database Setup ────────────────────────
info ""
info "Step 5: Service Account & Database Setup"

run_ps "Creating SQL login and databases" '
    Import-Module SqlServer -ErrorAction SilentlyContinue

    # Create SQL login if not exists
    $loginExists = Invoke-Sqlcmd -Query "
        SELECT name FROM sys.server_principals WHERE name = '"'"''"${SQL_USER}"''"'"'
    " -ErrorAction SilentlyContinue
    if (-not $loginExists) {
        Invoke-Sqlcmd -Query "
            CREATE LOGIN ['"${SQL_USER}"'] WITH PASSWORD = '"'"''"${SQL_PASSWORD}"''"'"',
            CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
            ALTER SERVER ROLE sysadmin ADD MEMBER ['"${SQL_USER}"'];
        "
        Write-Output "Created SQL login: '"${SQL_USER}"'"
    } else {
        Write-Output "SQL login already exists: '"${SQL_USER}"'"
    }

    # Create databases with correct collation and initial sizes
    $databases = @(
        @{ Name = "'"${QEF_DATABASE}"'";  Size = "10240MB" },
        @{ Name = "AccessLog"; Size = "20480MB" },
        @{ Name = "QLM";       Size = "20480MB" }
    )

    foreach ($db in $databases) {
        $exists = Invoke-Sqlcmd -Query "SELECT name FROM sys.databases WHERE name = '"'"'$($db.Name)'"'"'" -ErrorAction SilentlyContinue
        if (-not $exists) {
            Invoke-Sqlcmd -Query "
                CREATE DATABASE [$($db.Name)] COLLATE SQL_Latin1_General_CP1_CI_AS;
                ALTER DATABASE [$($db.Name)] MODIFY FILE (NAME = $($db.Name), SIZE = $($db.Size));
            "
            Write-Output "Created database: $($db.Name) ($($db.Size))"
        } else {
            Write-Output "Database already exists: $($db.Name)"
        }

        # Grant DB_OWNER to service account
        Invoke-Sqlcmd -Query "
            USE [$($db.Name)];
            IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '"'"''"${SQL_USER}"''"'"')
                CREATE USER ['"${SQL_USER}"'] FOR LOGIN ['"${SQL_USER}"'];
            ALTER ROLE db_owner ADD MEMBER ['"${SQL_USER}"'];
        "
        Write-Output "  DB_OWNER granted on $($db.Name)"
    }
'

# ── Step 6: Service Principal Names ─────────────────────────────────
info ""
info "Step 6: Service Principal Names"

run_ps "Configuring SPNs" '
    $serverFQDN = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $serverShort = $env:COMPUTERNAME

    # Set SPNs for the local machine account (non-domain environment)
    setspn -S "http/$serverFQDN" "$serverShort" 2>$null
    setspn -S "http/$serverShort" "$serverShort" 2>$null
    Write-Output "SPNs configured for $serverFQDN and $serverShort"
'

# ── Step 7: Windows Firewall Rules ──────────────────────────────────
info ""
info "Step 7: Windows Firewall Rules"

run_ps "Configuring firewall rules" '
    $rules = @(
        @{ Name = "QualiWare IIS HTTP";             Port = "80";             Protocol = "TCP" },
        @{ Name = "QualiWare Integration Server";   Port = "'"${PORT_START}"'-'"${PORT_END}"'"; Protocol = "TCP" },
        @{ Name = "QualiWare SMB TCP";              Port = "139,445";        Protocol = "TCP" },
        @{ Name = "QualiWare SMB UDP";              Port = "137,138";        Protocol = "UDP" },
        @{ Name = "QualiWare SQL Server";           Port = "1433";           Protocol = "TCP" }
    )

    foreach ($rule in $rules) {
        $existing = Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound `
                -LocalPort $rule.Port -Protocol $rule.Protocol -Action Allow | Out-Null
            Write-Output "  Created: $($rule.Name) ($($rule.Protocol) $($rule.Port))"
        } else {
            Write-Output "  Exists: $($rule.Name)"
        }
    }
'

# ── Step 8: Disable Automatic Windows Update ────────────────────────
info ""
info "Step 8: Configure Windows Update (security-only, TAPPaaS-managed)"

run_ps "Disabling automatic Windows Update" '
    # Disable automatic updates — TAPPaaS update-service.sh manages this
    $auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (!(Test-Path $auPath)) { New-Item -Path $auPath -Force | Out-Null }
    Set-ItemProperty -Path $auPath -Name "NoAutoUpdate" -Value 1 -Type DWord -Force

    # Disable Windows Update service auto-start
    Set-Service -Name wuauserv -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue

    # Install PSWindowsUpdate module for managed updates
    if (!(Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        Install-Module -Name PSWindowsUpdate -Force -Confirm:$false | Out-Null
        Write-Output "Installed PSWindowsUpdate module"
    } else {
        Write-Output "PSWindowsUpdate already installed"
    }

    Write-Output "Automatic Windows Update disabled — managed by TAPPaaS"
'

# ── Step 9: Windows Defender Exclusions (placeholder paths) ─────────
info ""
info "Step 9: Windows Defender Exclusion Paths (pre-configured)"

run_ps "Configuring Defender exclusions" '
    $qwProcesses = @(
        "Qdc.Module.exe",
        "Qef.exe",
        "Qis.Module.exe",
        "QProcessManager.exe",
        "Qts.Module.exe",
        "Qwc32.exe"
    )
    $qwPaths = @(
        "C:\Program Files\QualiWare"
    )

    Set-MpPreference -ExclusionProcess $qwProcesses -ErrorAction SilentlyContinue
    Set-MpPreference -ExclusionPath $qwPaths -ErrorAction SilentlyContinue
    Write-Output "Defender exclusions configured for QualiWare processes and paths"
'

# ── Done ─────────────────────────────────────────────────────────────
info ""
info "=== Windows Server baseline configuration complete ==="
info "VM: ${VMNAME} (VMID: ${VMID})"
info "SQL Server: localhost:1433 (collation: SQL_Latin1_General_CP1_CI_AS)"
info "SQL User: ${SQL_USER}"
info "Databases: ${QEF_DATABASE}, AccessLog, QLM"
info "IIS: HTTP port 80"
info "Integration Ports: ${INTEGRATION_PORTS}"
