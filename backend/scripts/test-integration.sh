#!/usr/bin/env bash
# Runs all backend tests against a throwaway Postgres, using podman (or docker).
set -euo pipefail
cd "$(dirname "$0")/../.."
RT=$(command -v podman || command -v docker)
POD=exist-test-$$
$RT pod create --name "$POD" >/dev/null
trap '$RT pod rm -f "$POD" >/dev/null' EXIT
$RT run -d --pod "$POD" -e POSTGRES_USER=exist -e POSTGRES_PASSWORD=exist -e POSTGRES_DB=exist_test docker.io/library/postgres:16 >/dev/null
$RT run --rm --pod "$POD" -v "$PWD":/w:Z -w /w/backend -e NODE_ENV=test \
  -e DATABASE_URL=postgresql://exist:exist@localhost:5432/exist_test docker.io/library/node:22-bookworm sh -c '
  for i in $(seq 1 30); do node -e "require(\"net\").connect(5432,\"localhost\").on(\"connect\",()=>process.exit(0)).on(\"error\",()=>process.exit(1))" && break; sleep 1; done
  sleep 2
  npx prisma db push >/dev/null && npx vitest run &&
  echo "checking the compiled build starts…" && rm -rf dist && npx tsc -p tsconfig.build.json &&
  JWT_SECRET=x node -e "Promise.all([import(\"./dist/src/lib/attestation.js\"), import(\"./dist/src/routes/dashboard.js\"), import(\"./dist/src/app.js\")]).then(() => console.log(\"compiled build OK\"))"'
