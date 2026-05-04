#!/usr/bin/env bash
set -euo pipefail

# Checks and updates local prerequisites for this repo in Ubuntu/WSL.
# Default mode: check only
# Update mode:   ./scripts/check-and-update-prereqs.sh --update [--yes]

REQUIRED_NODE="18.0.0"
REQUIRED_NPM="9.0.0"
REQUIRED_PYTHON="3.11.0"

DO_UPDATE=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)
      DO_UPDATE=1
      shift
      ;;
    --yes|-y)
      ASSUME_YES=1
      shift
      ;;
    --help|-h)
      cat <<'EOF'
Usage:
  ./scripts/check-and-update-prereqs.sh
  ./scripts/check-and-update-prereqs.sh --update [--yes]

Options:
  --update   Install/upgrade required prerequisites on Ubuntu/WSL
  --yes      Do not prompt before update steps
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null || \
    grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null
}

strip_v() {
  echo "$1" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//'
}

version_ge() {
  local installed="$1"
  local required="$2"
  [[ "$(printf '%s\n' "$required" "$installed" | sort -V | head -n1)" == "$required" ]]
}

get_cmd_version() {
  local cmd="$1"
  local version_args="$2"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "MISSING"
    return
  fi

  # shellcheck disable=SC2086
  local raw
  raw=$("$cmd" $version_args 2>/dev/null | head -n1 || true)
  local cleaned
  cleaned=$(strip_v "$raw")

  if [[ -z "$cleaned" ]]; then
    echo "UNKNOWN"
  else
    echo "$cleaned"
  fi
}

print_row() {
  local name="$1"
  local required="$2"
  local installed="$3"
  local status="$4"
  printf '%-10s %-12s %-12s %-10s\n' "$name" "$required" "$installed" "$status"
}

status_for() {
  local installed="$1"
  local required="$2"

  if [[ "$installed" == "MISSING" || "$installed" == "UNKNOWN" ]]; then
    echo "MISSING"
    return
  fi

  if version_ge "$installed" "$required"; then
    echo "OK"
  else
    echo "OUTDATED"
  fi
}

report_versions() {
  NODE_VERSION=$(get_cmd_version node "-v")
  NPM_VERSION=$(get_cmd_version npm "-v")
  PYTHON_VERSION=$(get_cmd_version python3 "--version")
  DOCKER_VERSION=$(get_cmd_version docker "--version")
  AZ_VERSION=$(get_cmd_version az "version")

  NODE_STATUS=$(status_for "$NODE_VERSION" "$REQUIRED_NODE")
  NPM_STATUS=$(status_for "$NPM_VERSION" "$REQUIRED_NPM")
  PYTHON_STATUS=$(status_for "$PYTHON_VERSION" "$REQUIRED_PYTHON")

  echo
  echo "Prerequisite Version Report"
  echo "Required baseline: Node.js >= $REQUIRED_NODE, npm >= $REQUIRED_NPM, Python >= $REQUIRED_PYTHON"
  printf '%-10s %-12s %-12s %-10s\n' "Tool" "Required" "Installed" "Status"
  printf '%-10s %-12s %-12s %-10s\n' "----------" "------------" "------------" "----------"
  print_row "node" "$REQUIRED_NODE" "$NODE_VERSION" "$NODE_STATUS"
  print_row "npm" "$REQUIRED_NPM" "$NPM_VERSION" "$NPM_STATUS"
  print_row "python3" "$REQUIRED_PYTHON" "$PYTHON_VERSION" "$PYTHON_STATUS"
  print_row "docker" "optional" "$DOCKER_VERSION" "INFO"
  print_row "az" "optional" "$AZ_VERSION" "INFO"
  echo

  if is_wsl && [[ "$DOCKER_VERSION" == "MISSING" ]]; then
    echo "Note: Docker is optional for local stack startup. For containers in WSL, enable Docker Desktop WSL integration."
  fi

  REQUIRED_MISMATCH=0
  if [[ "$NODE_STATUS" != "OK" || "$NPM_STATUS" != "OK" || "$PYTHON_STATUS" != "OK" ]]; then
    REQUIRED_MISMATCH=1
  fi
}

need_sudo() {
  if sudo -n true >/dev/null 2>&1; then
    return
  fi

  echo "sudo access is required for updates. You may be prompted for your password."
  sudo -v
}

confirm_updates() {
  if [[ "$ASSUME_YES" == "1" ]]; then
    return
  fi

  echo "This will install/update required tools (node, npm, python3.11+) using apt."
  read -r -p "Continue? [y/N]: " answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Update cancelled."
    exit 0
  fi
}

install_or_update_node() {
  local current="$NODE_VERSION"
  if [[ "$NODE_STATUS" == "OK" ]]; then
    echo "Node.js is already compliant: $current"
    return
  fi

  echo "Updating Node.js to LTS (20.x) via NodeSource..."
  # Remove legacy Ubuntu Node 12 dev/docs packages that conflict with NodeSource nodejs.
  local conflicting_packages=(libnode-dev nodejs-dev nodejs-doc)
  local to_remove=()
  local pkg
  for pkg in "${conflicting_packages[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      to_remove+=("$pkg")
    fi
  done

  if [[ ${#to_remove[@]} -gt 0 ]]; then
    echo "Removing conflicting packages: ${to_remove[*]}"
    sudo apt-get remove -y "${to_remove[@]}"
  fi

  # Repair interrupted package operations before continuing.
  sudo dpkg --configure -a || true
  sudo apt-get -f install -y || true

  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs

  hash -r
}

install_or_update_npm() {
  # npm usually comes with nodejs package, but enforce baseline if still outdated.
  local current
  current=$(get_cmd_version npm "-v")
  local status
  status=$(status_for "$current" "$REQUIRED_NPM")

  if [[ "$status" == "OK" ]]; then
    echo "npm is already compliant: $current"
    return
  fi

  echo "Updating npm to latest stable..."
  sudo npm install -g npm@latest
  hash -r
}

install_or_update_python() {
  local current="$PYTHON_VERSION"
  if [[ "$PYTHON_STATUS" == "OK" ]]; then
    echo "Python is already compliant: $current"
    return
  fi

  echo "Installing Python 3.11..."
  sudo apt-get update -y
  sudo apt-get install -y python3.11 python3.11-venv python3-pip
}

report_versions

if [[ "$DO_UPDATE" == "0" ]]; then
  if [[ "$REQUIRED_MISMATCH" == "1" ]]; then
    echo "Required prerequisites are not satisfied. Run with --update to fix."
    exit 1
  fi

  echo "All required prerequisites are satisfied."
  exit 0
fi

confirm_updates
need_sudo
install_or_update_node
install_or_update_npm
install_or_update_python

report_versions

if [[ "$REQUIRED_MISMATCH" == "1" ]]; then
  echo "Some required prerequisites are still not satisfied. Please review output above."
  exit 1
fi

echo "All required prerequisites are now satisfied."
