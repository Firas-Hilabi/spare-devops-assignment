#!/usr/bin/env bash
#
# ops.sh — operator helper for the local Notifications API stack.
#
# Usage:
#   ./scripts/ops.sh up       # build + start the stack (idempotent)
#   ./scripts/ops.sh down     # stop the stack (data volume kept)
#   ./scripts/ops.sh status   # show container + API health
#   ./scripts/ops.sh logs     # tail API logs
#   ./scripts/ops.sh smoke    # run basic API checks
#
set -euo pipefail

# Run from the repo root regardless of where the script is invoked.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BASE_URL="${BASE_URL:-http://localhost:8080}"
COMPOSE="docker compose"

# --- pretty output -----------------------------------------------------------
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed or not on PATH."
  docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker Desktop and retry."
}

ensure_env() {
  # Compose needs a .env for variable substitution; seed it from the example.
  if [[ ! -f .env ]]; then
    info ".env not found — creating it from .env.example"
    cp .env.example .env
  fi
}

# Poll /health until the API is ready or we time out.
wait_for_health() {
  local retries="${1:-30}"
  info "Waiting for API at ${BASE_URL}/health ..."
  for ((i = 1; i <= retries; i++)); do
    if curl -fsS "${BASE_URL}/health" >/dev/null 2>&1; then
      green "API is healthy."
      return 0
    fi
    sleep 2
  done
  die "API did not become healthy within $((retries * 2))s. Try: ./scripts/ops.sh logs"
}

cmd_up() {
  require_docker
  ensure_env
  info "Building and starting the stack ..."
  $COMPOSE up -d --build
  wait_for_health
  green "Stack is up. Try: curl ${BASE_URL}/health"
}

cmd_down() {
  require_docker
  info "Stopping the stack (data volume preserved) ..."
  $COMPOSE down
  green "Stack stopped."
}

cmd_status() {
  require_docker
  $COMPOSE ps
  echo
  info "API health:"
  if curl -fsS "${BASE_URL}/health"; then
    echo; green "API is healthy."
  else
    echo; die "API is not responding on ${BASE_URL}/health"
  fi
}

cmd_logs() {
  require_docker
  info "Tailing API logs (Ctrl-C to stop) ..."
  $COMPOSE logs -f --tail=100 api
}

cmd_smoke() {
  require_docker
  wait_for_health
  info "Smoke test: create a user"
  local user_resp user_id
  user_resp="$(curl -fsS -X POST "${BASE_URL}/users" \
    -H 'Content-Type: application/json' \
    -d '{"name":"SmokeTest User"}')"
  echo "  $user_resp"
  user_id="$(echo "$user_resp" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')"
  [[ -n "$user_id" ]] || die "Could not parse user id from response."

  info "Smoke test: create a notification for user ${user_id}"
  curl -fsS -X POST "${BASE_URL}/notifications" \
    -H 'Content-Type: application/json' \
    -d "{\"user_id\":${user_id},\"title\":\"Hello\",\"body\":\"Welcome!\"}" \
    | sed 's/^/  /'; echo

  info "Smoke test: list users"
  curl -fsS "${BASE_URL}/users" | sed 's/^/  /'; echo

  info "Smoke test: list notifications for user ${user_id}"
  curl -fsS "${BASE_URL}/notifications?user_id=${user_id}" | sed 's/^/  /'; echo

  echo
  green "Smoke test passed."
}

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    logs)   cmd_logs ;;
    smoke)  cmd_smoke ;;
    *)      usage ;;
  esac
}

main "$@"
