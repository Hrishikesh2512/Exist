#!/usr/bin/env bash
# Make exist-server.tgz with just what the server needs, to copy to your cloud server:
#   ./deploy/package.sh && scp exist-server.tgz ubuntu@<server-ip>:
#   (on the server) tar xzf exist-server.tgz && cd exist && sudo ./deploy/setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."
tar czf exist-server.tgz --transform 's,^,exist/,' \
  --exclude='backend/node_modules' --exclude='backend/dist' --exclude='deploy/.env' --exclude='deploy/backups' --exclude='deploy/downloads' \
  backend deploy shared
echo "Created exist-server.tgz ($(du -h exist-server.tgz | cut -f1))"
