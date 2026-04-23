#!/usr/bin/env bash
#
# TAPPaaS QualiWare Module - Install
#
# 1. Clones the Windows Server template into a new VM
# 2. Applies baseline configuration (SQL Server, IIS, VirtIO, etc.)
# 3. Installs the QualiWare application from the Suite ISO
#
# Prerequisites:
#   - Windows Server 2025 template (VMID 8081) exists in Proxmox
#   - QW_Suite.iso uploaded to Proxmox local ISO storage
#   - /home/tappaas/secrets/qualiware.env exists with SQL_PASSWORD set
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh qualiware
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

# Step 1: Clone the Windows Server template into a new VM
. /home/tappaas/bin/install-vm.sh

# Step 2: Install the QualiWare application
. ./install-qualiware.sh

echo ""
info "${GN}✓${CL} QualiWare installation completed successfully."
