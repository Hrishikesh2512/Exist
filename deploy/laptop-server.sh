#!/usr/bin/env bash
# Run Exist on this computer (e.g. for a class demo), published at a fixed HTTPS address
# with Tailscale Funnel. Safe to run again: it updates and restarts the server.
#   ./deploy/laptop-server.sh
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
DATA=$HOME/.local/share/exist
mkdir -p "$DATA/downloads" "$DATA/backups"

podman pod exists exist || podman pod create --name exist -p 127.0.0.1:8080:8080 >/dev/null
podman volume exists exist-db || podman volume create exist-db >/dev/null
if ! podman container exists exist-db; then
  podman run -d --pod exist --name exist-db --restart always \
    -e POSTGRES_USER=exist -e POSTGRES_PASSWORD=exist -e POSTGRES_DB=exist \
    -v exist-db:/var/lib/postgresql/data docker.io/library/postgres:16 >/dev/null
fi
podman update --restart always exist-db >/dev/null 2>&1 || true

echo "Building the server…"
(cd backend && podman build -q -t exist-api . >/dev/null)
podman rm -f exist-api >/dev/null 2>&1 || true
podman run -d --pod exist --name exist-api --restart always \
  -e DATABASE_URL="postgresql://exist:exist@localhost:5432/${DATABASE_NAME:-exist}" \
  -e JWT_SECRET -e SECRETS_KEY -e INSTITUTION_TZ="${INSTITUTION_TZ:-Asia/Kolkata}" -e ATTESTATION_MODE="${ATTESTATION_MODE:-record}" \
  -e INSTITUTION_NAME -e TEACHER_SIGNUP_CODE -e APK_PATH=/downloads/exist.apk \
  -v "$DATA/downloads":/downloads:ro,z exist-api >/dev/null

# Start again after a reboot (containers with restart=always).
systemctl --user enable --now podman-restart.service >/dev/null 2>&1 || true

# Daily backup of the database.
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/exist-backup.service" <<UNIT
[Unit]
Description=Exist database backup
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'podman exec exist-db pg_dump -U exist ${DATABASE_NAME:-exist} | gzip > $DATA/backups/exist-\$(date +%%Y-%%m-%%d_%%H%%M).sql.gz && ls -1t $DATA/backups/exist-*.sql.gz | tail -n +15 | xargs -r rm -f'
UNIT
cat > "$HOME/.config/systemd/user/exist-backup.timer" <<UNIT
[Unit]
Description=Daily Exist database backup
[Timer]
OnCalendar=*-*-* 21:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now exist-backup.timer >/dev/null

for _ in $(seq 1 40); do curl -sf -m 3 http://127.0.0.1:8080/health >/dev/null && break; sleep 2; done
curl -sf -m 3 http://127.0.0.1:8080/health >/dev/null && echo "Server is running on this computer." || { echo "Server did not start: podman logs exist-api"; exit 1; }
URL=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print("https://"+json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)
echo "Public address (after 'tailscale funnel --bg 8080' once): ${URL:-<tailscale not available>}"
