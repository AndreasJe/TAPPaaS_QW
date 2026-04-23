#!/usr/bin/env bash
#
# TAPPaaS Templates Windows Server Service - Delete
#
# Cleans up Windows Server baseline configuration from a module's VM.
# Called when uninstalling a module that depends on templates:windows-server.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <module-name>"
    echo "Removes Windows Server baseline configuration for the specified module."
    exit 1
fi

MODULE_NAME="$1"
echo "templates:windows-server delete-service called for module: ${MODULE_NAME} (not yet implemented)"
