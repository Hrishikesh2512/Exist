#!/usr/bin/env bash
# Free HTTPS address for the Exist server, reachable from any network (mobile data too),
# via a Cloudflare quick tunnel. No account needed. The address changes every time this
# starts: type the new one into the app (login screen → "Server: …").
# WARNING: this makes the server public. Change the demo passwords first.
set -euo pipefail
RT=$(command -v podman || command -v docker)
$RT rm -f exist-tunnel >/dev/null 2>&1 || true
$RT run -d --name exist-tunnel --network host --restart unless-stopped \
  docker.io/cloudflare/cloudflared:latest tunnel --no-autoupdate --url http://127.0.0.1:8080 >/dev/null
echo "Starting tunnel…"
for _ in $(seq 1 30); do
  URL=$($RT logs exist-tunnel 2>&1 | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | head -1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
if [ -z "${URL:-}" ]; then echo "No address yet; check: $RT logs exist-tunnel"; exit 1; fi
echo
echo "  Server address for the app:  $URL"
echo "  Admin dashboard:             $URL"
echo "  Android app download:        $URL/app.apk"
echo
echo "Stop it with: $RT rm -f exist-tunnel"
