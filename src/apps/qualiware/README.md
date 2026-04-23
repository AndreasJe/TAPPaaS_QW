# QualiWare Application Server

TAPPaaS module for QualiWare — a proprietary enterprise quality management platform
running on Windows Server 2025 with SQL Server.

## Architecture

Single VM containing:
- **Windows Server 2025** (cloned from template VMID 8081)
- **SQL Server 2022** (Express or Standard, configurable)
- **SQL Server Management Studio (SSMS)**
- **IIS** with Windows Authentication for the QualiWare web client (QEP)
- **QualiWare Application Server** (services: QEF, QIS, QTS, QDC)

## Prerequisites

Before running `install-module.sh qualiware`:

1. **Windows Server 2025 template** (VMID 8081) must exist in Proxmox
   - Create manually or via `install-module.sh tappaas-winserver`
   - Must have OpenSSH Server enabled with `tappaas` user having Administrator access
   - Must have QEMU guest agent (VirtIO) installed

2. **VirtIO drivers ISO** must be available on Proxmox nodes
   - Download: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
   - Place in: `/var/lib/vz/template/iso/`

3. **Windows Server 2025 ISO** (for initial template creation)
   - Place in: `/var/lib/vz/template/iso/`

4. **Set SQL password** in `qualiware.json` before installation:
   ```json
   "qualiware": {
     "SQLPassword": "YOUR_SECURE_PASSWORD_HERE"
   }
   ```

## Installation

```bash
cd ~/TAPPaaS/src/apps/qualiware
install-module.sh qualiware
```

This will:
1. Clone the Windows Server template (VMID 8081 → VMID 320)
2. Install Visual C++ Redistributables (2010, 2013, 2015)
3. Install IIS with Windows Authentication and File Server role
4. Install SQL Server 2022 with `SQL_Latin1_General_CP1_CI_AS` collation
5. Install SSMS
6. Create SQL login `sqlQualiWareQEF` with DB_OWNER on all databases
7. Create databases: QEF (10GB), AccessLog (20GB), QLM (20GB)
8. Configure Windows Firewall (HTTP 80, integration ports 25780-25799, SMB, SQL)
9. Disable automatic Windows Update (managed by TAPPaaS)
10. Configure Windows Defender exclusions for QualiWare processes

## QualiWare Application Install

Place the QualiWare installer `.zip` file in this directory, then run:

```bash
update-module.sh qualiware
```

The auto-installer will be called with these parameters (from `qualiware.json`):
- `QEFDatabase` → QEF
- `SQLUser` → sqlQualiWareQEF
- `DatabaseServer` → localhost

## OS Updates

Windows Update is configured for **security-only** updates managed by TAPPaaS:
- Automatic Windows Update is **disabled**
- `update-module.sh qualiware` installs only "Security Updates" category
- Reboots only when Windows explicitly requires it
- Feature updates and driver updates are excluded

## Configuration

Key settings in `qualiware.json`:

| Field | Default | Description |
|-------|---------|-------------|
| `qualiware.QEFDatabase` | `QEF` | Primary QualiWare database name |
| `qualiware.SQLUser` | `sqlQualiWareQEF` | SQL Server login for QualiWare |
| `qualiware.SQLPassword` | (must set) | Password for SQL login |
| `qualiware.DatabaseServer` | `localhost` | SQL Server hostname |
| `qualiware.IntegrationPorts` | `25780-25799` | QualiWare Integration Server port range |

## Network Ports

| Port | Protocol | Service |
|------|----------|---------|
| 80 | TCP | IIS / QualiWare Web Client (QEP) |
| 443 | TCP | HTTPS via Caddy reverse proxy |
| 1433 | TCP | SQL Server |
| 25780-25799 | TCP | QualiWare Integration Server |
| 139, 445 | TCP | SMB file shares |
| 137, 138 | UDP | SMB name resolution |

## Health Checks

`test.sh` validates:
1. SSH connectivity (Windows OpenSSH)
2. IIS is running (W3SVC service)
3. SQL Server is running (MSSQLSERVER service)
4. HTTP endpoint responds on port 80
5. QualiWare services are running (if installed)

`test-service.sh` (templates:windows-server) validates all baseline requirements
from the QualiWare Pre-Installation Document.
