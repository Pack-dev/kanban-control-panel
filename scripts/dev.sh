#!/usr/bin/env bash
# scripts/dev.sh — start the backend and the frontend dev servers together.
#
# Each runs in the foreground; SIGINT (Ctrl-C) tears both down.
# Backend logs are prefixed [back], frontend logs are prefixed [front].
#
# Prereqs:
#   - submodules initialised: `git submodule update --init --recursive`
#   - backend `.env` exists (copy backend/.env.example → backend/.env, fill JWT_SECRET)
#   - `go` and `npm` on PATH

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -d "$ROOT/backend" || ! -d "$ROOT/frontend" ]]; then
  echo "error: backend/ and/or frontend/ submodules missing" >&2
  echo "run: git submodule update --init --recursive" >&2
  exit 1
fi

if [[ ! -f "$ROOT/backend/.env" ]]; then
  echo "warn: backend/.env not found; the server will fail if JWT_SECRET is unset" >&2
fi

# Track child PIDs so we can clean up on exit.
pids=()
cleanup() {
  echo
  echo "[dev] shutting down…"
  for pid in "${pids[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

(
  cd "$ROOT/backend"
  go run ./cmd/server 2>&1 | sed -e "s/^/[back] /"
) &
pids+=("$!")

(
  cd "$ROOT/frontend"
  if [[ ! -d node_modules ]]; then
    echo "[front] installing deps…"
    npm install --silent
  fi
  npm run dev -- --host 2>&1 | sed -e "s/^/[front] /"
) &
pids+=("$!")

echo "[dev] backend  → http://localhost:8080"
echo "[dev] frontend → http://localhost:5173"
echo "[dev] press Ctrl-C to stop"

wait
