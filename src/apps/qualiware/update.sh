#!/usr/bin/env bash
#
# TAPPaaS QualiWare Module - Update
#
# OS-level updates are handled by tappaas-cicd via update-os.sh.
# Health checks are handled by test.sh.
# QualiWare application upgrades are handled by install-qualiware.sh.
#
# Usage: ./update.sh <vmname>
#

# OS patching is handled by the windows-server service dependency (update-os.sh).
# QualiWare application upgrades require a new ISO — run install-qualiware.sh manually.
exit 0
