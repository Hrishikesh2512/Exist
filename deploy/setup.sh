#!/usr/bin/env bash
# One-command launch on a fresh Ubuntu server (e.g. Oracle Cloud Always Free):
#   sudo ./deploy/setup.sh
# Installs Docker, opens the web ports, creates secrets, starts Exist with HTTPS and backups.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo: sudo $0"; exit 1; fi

echo "== Exist setup =="
if [ ! -f .env ]; then
  read -rp "Your domain (e.g. myschool.duckdns.org): " DOMAIN
  [ -n "$DOMAIN" ] || { echo "A domain is needed for HTTPS"; exit 1; }
  read -rp "Institution name (shown in the app, e.g. ABC Engineering College): " INST
  read -rp "Time zone [Asia/Kolkata]: " TZ_IN
  echo "Teacher code: teachers must enter it to create a teacher account (so students can't)."
  read -rp "  Teacher code [press Enter to generate one]: " TCODE
  TCODE=${TCODE:-$(tr -dc 'A-HJ-NP-Z2-9' </dev/urandom | head -c 8)}
  echo "Optional: email for 'forgot password' (Gmail + app password). Leave blank to skip."
  read -rp "  SMTP user (e.g. you@gmail.com): " SMTP_USER
  SMTP_PASS=""
  if [ -n "$SMTP_USER" ]; then read -rsp "  SMTP app password: " SMTP_PASS; echo; fi
  cat > .env <<ENV
DOMAIN=$DOMAIN
INSTITUTION_NAME="$INST"
TEACHER_SIGNUP_CODE=$TCODE
INSTITUTION_TZ=${TZ_IN:-Asia/Kolkata}
POSTGRES_PASSWORD=$(openssl rand -hex 24)
JWT_SECRET=$(openssl rand -hex 32)
SECRETS_KEY=$(openssl rand -base64 32)
ATTESTATION_MODE=record
SMTP_HOST=${SMTP_USER:+smtp.gmail.com}
SMTP_PORT=465
SMTP_USER=$SMTP_USER
SMTP_PASS=$SMTP_PASS
SMTP_FROM=${SMTP_USER:+Exist <$SMTP_USER>}
ENV
  chmod 600 .env
  echo "Saved settings to deploy/.env (keep it private and backed up)."
fi
set -a; . ./.env; set +a

if ! command -v docker >/dev/null; then
  echo "Installing Docker…"
  curl -fsSL https://get.docker.com | sh
fi

# Oracle's Ubuntu images block ports with iptables even when the cloud firewall allows them.
if command -v iptables >/dev/null; then
  for p in 80 443; do
    iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT 6 -p tcp --dport $p -j ACCEPT
  done
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
fi
command -v ufw >/dev/null && ufw status | grep -q active && ufw allow 80/tcp && ufw allow 443/tcp || true

mkdir -p downloads backups
docker compose up -d --build

echo "Waiting for the server…"
for _ in $(seq 1 60); do
  if docker compose exec -T api node -e "fetch('http://localhost:8080/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then break; fi
  sleep 3
done

cat <<DONE

Exist is running at https://$DOMAIN  (the HTTPS certificate is issued on the first visit).
  1. Build the phone app on your computer:   ./deploy/build-app.sh $DOMAIN
     and upload it:                          scp exist.apk <this-server>:$(pwd)/downloads/exist.apk
  2. Share https://$DOMAIN/app.apk with everyone.
  3. Give teachers the teacher code: ${TEACHER_SIGNUP_CODE:-}
     Teachers create accounts and classes in the app, and share each class code with their students.

Useful:  docker compose -f $(pwd)/docker-compose.yml logs -f api     (logs)
         ls $(pwd)/backups                                            (daily backups)
DONE
