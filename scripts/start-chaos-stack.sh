#!/usr/bin/env bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
# If nvm is installed, prefer using latest LTS, but do not require nvm.
command -v nvm >/dev/null 2>&1 && nvm use --lts >/dev/null 2>&1 || true
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT_DIR/.runtime-logs"
mkdir -p "$LOG_DIR"
FRONTEND_DIR="$ROOT_DIR/frontend/parking-manager"

PIDS=()
NPM_CMD=""
NODE_CMD=""
MIN_NODE_MAJOR=18
MIN_NPM_MAJOR=9

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null || \
    grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null
}

resolve_runtime_commands() {
  NPM_CMD="$(command -v npm || true)"
  NODE_CMD="$(command -v node || true)"
  local NODEJS_CMD="$(command -v nodejs || true)"

  if is_wsl; then
    # Prefer Linux binaries in WSL to avoid invoking Windows node/npm via /mnt/c.
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

    if [[ -z "$NPM_CMD" || "$NPM_CMD" == /mnt/* || "$NPM_CMD" == *.cmd || "$NPM_CMD" == *.exe ]]; then
      if [[ -x /usr/bin/npm ]]; then
        NPM_CMD="/usr/bin/npm"
      else
        NPM_CMD="$(command -v npm || true)"
      fi
    fi

    if [[ -z "$NODE_CMD" || "$NODE_CMD" == /mnt/* || "$NODE_CMD" == *.cmd || "$NODE_CMD" == *.exe ]]; then
      if [[ -x /usr/bin/node ]]; then
        NODE_CMD="/usr/bin/node"
      elif [[ -x /usr/bin/nodejs ]]; then
        NODE_CMD="/usr/bin/nodejs"
      else
        NODE_CMD="$(command -v node || true)"
      fi
    fi

    if [[ -z "$NODE_CMD" && -n "$NODEJS_CMD" && "$NODEJS_CMD" != /mnt/* ]]; then
      NODE_CMD="$NODEJS_CMD"
    fi
  fi

  if [[ -z "$NPM_CMD" || -z "$NODE_CMD" ]]; then
    if is_wsl; then
      echo "❌ Linux Node.js/npm are missing in this WSL shell."
      echo "   Detected node: ${NODE_CMD:-<missing>}"
      echo "   Detected npm:  ${NPM_CMD:-<missing>}"
      echo "   Install in WSL Ubuntu with:"
      echo "   sudo apt update && sudo apt install -y nodejs npm"
      echo "   Then run this script again."
    else
      echo "❌ Node.js and npm must be installed in this shell."
    fi
    exit 1
  fi

  if is_wsl && [[ "$NPM_CMD" == /mnt/* || "$NODE_CMD" == /mnt/* ]]; then
    echo "❌ Detected Windows Node/npm inside WSL."
    echo "   Install Linux Node.js in WSL and ensure /usr/bin or your Linux node path is first in PATH."
    echo "   Current node: $NODE_CMD"
    echo "   Current npm:  $NPM_CMD"
    exit 1
  fi
}

validate_runtime_versions() {
  local node_raw
  node_raw="$($NODE_CMD -v 2>/dev/null || true)"
  local npm_raw
  npm_raw="$($NPM_CMD -v 2>/dev/null || true)"

  local node_ver
  node_ver="${node_raw#v}"
  local npm_ver
  npm_ver="${npm_raw#v}"

  local node_major
  node_major="${node_ver%%.*}"
  local npm_major
  npm_major="${npm_ver%%.*}"

  if [[ -z "$node_major" || ! "$node_major" =~ ^[0-9]+$ ]]; then
    echo "❌ Could not detect a valid Node.js version from: ${node_raw:-<empty>}"
    echo "   Detected node binary: $NODE_CMD"
    exit 1
  fi

  if [[ -z "$npm_major" || ! "$npm_major" =~ ^[0-9]+$ ]]; then
    echo "❌ Could not detect a valid npm version from: ${npm_raw:-<empty>}"
    echo "   Detected npm binary: $NPM_CMD"
    exit 1
  fi

  if (( node_major < MIN_NODE_MAJOR || npm_major < MIN_NPM_MAJOR )); then
    echo "❌ Detected outdated runtime versions."
    echo "   Required: node >= ${MIN_NODE_MAJOR}.x, npm >= ${MIN_NPM_MAJOR}.x"
    echo "   Current:  node ${node_raw}, npm ${npm_raw}"
    echo "   Fix:      ./scripts/check-and-update-prereqs.sh --update"
    exit 1
  fi
}

ensure_dependencies() {
  local service_dir="$1"
  local should_install=0

  if [[ ! -d "$service_dir/node_modules" ]]; then
    should_install=1
  else
    (
      cd "$service_dir"
      "$NPM_CMD" ls --depth=0 >/dev/null 2>&1
    ) || should_install=1
  fi

  if [[ "$should_install" == "1" ]]; then
    echo "📦 Installing dependencies in $service_dir"
    (
      cd "$service_dir"
      "$NPM_CMD" install
    )
  fi
}

needs_frontend_build() {
  local build_index="$FRONTEND_DIR/build/index.html"

  if [[ "${FORCE_FRONTEND_BUILD:-0}" == "1" ]]; then
    return 0
  fi

  if [[ ! -f "$build_index" ]]; then
    return 0
  fi

  if find \
    "$FRONTEND_DIR/src" \
    "$FRONTEND_DIR/public" \
    -type f \
    -newer "$build_index" \
    -print -quit | grep -q .; then
    return 0
  fi

  if [[ "$FRONTEND_DIR/server.js" -nt "$build_index" ]] || \
     [[ "$FRONTEND_DIR/package.json" -nt "$build_index" ]] || \
     [[ "$FRONTEND_DIR/tsconfig.json" -nt "$build_index" ]]; then
    return 0
  fi

  return 1
}

start_service() {
  local name="$1"
  local service_dir="$2"
  local command="$3"

  echo "▶️  Starting $name"
  (
    cd "$service_dir"
    eval "$command" >"$LOG_DIR/${name}.log" 2>&1
  ) &

  local pid=$!
  PIDS+=("$pid")
  echo "   PID: $pid | log: $LOG_DIR/${name}.log"
}

cleanup() {
  echo
  echo "🛑 Stopping all services..."
  for pid in "${PIDS[@]:-}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
  wait || true
  echo "✅ All services stopped"
}

trap cleanup EXIT INT TERM

echo "🚀 Starting local chaos stack"
echo "   Workspace: $ROOT_DIR"

resolve_runtime_commands
validate_runtime_versions
echo "   Runtime:   node=$NODE_CMD | npm=$NPM_CMD"

CHAOS_URL="${CHAOS_CONTROL_URL:-http://localhost:3090}"

ensure_dependencies "$ROOT_DIR/backend/chaos-control"
ensure_dependencies "$ROOT_DIR/backend/vm-health-control"
ensure_dependencies "$ROOT_DIR/backend/lisbon-parking-api"
ensure_dependencies "$ROOT_DIR/backend/madrid-parking-api"
ensure_dependencies "$ROOT_DIR/backend/paris-parking-api"
ensure_dependencies "$ROOT_DIR/backend/berlin-parking-api"
ensure_dependencies "$FRONTEND_DIR"

if needs_frontend_build; then
  echo "🏗️  Frontend changes detected. Building..."
  (
    cd "$FRONTEND_DIR"
    "$NPM_CMD" run build
  )
else
  echo "✅ Frontend build is up to date"
fi

start_service "chaos-control" "$ROOT_DIR/backend/chaos-control" "'$NPM_CMD' run start"
start_service "vm-health-control" "$ROOT_DIR/backend/vm-health-control" "'$NPM_CMD' run start"
start_service "lisbon-api" "$ROOT_DIR/backend/lisbon-parking-api" "CHAOS_CONTROL_URL='$CHAOS_URL' '$NPM_CMD' run start"
start_service "madrid-api" "$ROOT_DIR/backend/madrid-parking-api" "CHAOS_CONTROL_URL='$CHAOS_URL' '$NPM_CMD' run start"
start_service "paris-api" "$ROOT_DIR/backend/paris-parking-api" "CHAOS_CONTROL_URL='$CHAOS_URL' '$NPM_CMD' run start"
start_service "berlin-api" "$ROOT_DIR/backend/berlin-parking-api" "CHAOS_CONTROL_URL='$CHAOS_URL' '$NPM_CMD' run start"
start_service "frontend" "$FRONTEND_DIR" "REACT_APP_LISBON_API_URL='http://localhost:3001' REACT_APP_MADRID_API_URL='http://localhost:3002' REACT_APP_PARIS_API_URL='http://localhost:3003' REACT_APP_BERLIN_API_URL='http://localhost:3004' REACT_APP_CHAOS_CONTROL_URL='$CHAOS_URL' REACT_APP_VM_HEALTH_CONTROL_URL='http://localhost:3095' PORT='8080' '$NODE_CMD' server.js"

echo

echo "✅ Chaos stack is running"
echo "   Frontend:      http://localhost:8080"
echo "   Chaos control: $CHAOS_URL/health"
echo "   Logs:          $LOG_DIR"
echo
echo "Press Ctrl+C to stop all services"

wait
