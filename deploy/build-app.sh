#!/usr/bin/env bash
# Build the Android app for your server (run on your own computer; needs podman or docker).
#   ./deploy/build-app.sh myschool.duckdns.org
# Produces ./exist.apk with the server address built in: users never type a server.
set -euo pipefail
DOMAIN=${1:?usage: $0 your-domain (or a full http(s):// URL for testing)}
case "$DOMAIN" in http://*|https://*) URL=$DOMAIN ;; *) URL=https://$DOMAIN ;; esac
cd "$(dirname "$0")/.."
RT=$(command -v podman || command -v docker)
$RT run --rm -v "$PWD":/w:Z -w /w/app -e HOME=/w/.home -e PUB_CACHE=/w/.pub-cache -e GRADLE_USER_HOME=/w/.gradle \
  ghcr.io/cirruslabs/flutter:stable sh -c "mkdir -p /w/.home; git config --global --add safe.directory '*'; flutter build apk --release --dart-define=API_URL=$URL"
cp app/build/app/outputs/flutter-apk/app-release.apk exist.apk
echo "Built exist.apk for $URL"
