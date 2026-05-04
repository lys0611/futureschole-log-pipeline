#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
is_pkg_installed(){ dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

install_missing_packages(){
  local missing=()
  for pkg in "$@"; do
    if is_pkg_installed "$pkg"; then log "Package already installed: $pkg"; else missing+=("$pkg"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then log "Installing missing packages: ${missing[*]}"; sudo apt-get update; sudo apt-get install -y "${missing[@]}"; else log "All required packages are already installed."; fi
}

[ -f /etc/os-release ] || { echo "[ERROR] /etc/os-release not found. Ubuntu only."; exit 1; }
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || { echo "[ERROR] Ubuntu only. Current OS: ${ID:-unknown}"; exit 1; }

TARGET_USER="${SUDO_USER:-$USER}"
KEYRING_DIR="/etc/apt/keyrings"
DOCKER_GPG="${KEYRING_DIR}/docker.gpg"
DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
ARCH="$(dpkg --print-architecture)"
CODENAME="${VERSION_CODENAME}"
DOCKER_REPO_LINE="deb [arch=${ARCH} signed-by=${DOCKER_GPG}] https://download.docker.com/linux/ubuntu ${CODENAME} stable"

COMMON_PACKAGES=(ca-certificates curl gnupg git jq)
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

log "Checking base packages..."
install_missing_packages "${COMMON_PACKAGES[@]}"

if [ -d "$KEYRING_DIR" ]; then log "Keyring directory already exists: $KEYRING_DIR"; else log "Creating keyring directory: $KEYRING_DIR"; sudo install -m 0755 -d "$KEYRING_DIR"; fi

if [ -s "$DOCKER_GPG" ]; then
  log "Docker GPG key already exists: $DOCKER_GPG"
else
  log "Adding Docker GPG key..."
  TMP_GPG="$(mktemp)"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor > "$TMP_GPG"
  sudo install -m 0644 "$TMP_GPG" "$DOCKER_GPG"
  rm -f "$TMP_GPG"
fi

REPO_CHANGED=0
if [ -f "$DOCKER_LIST" ] && grep -Fxq "$DOCKER_REPO_LINE" "$DOCKER_LIST"; then
  log "Docker APT repository already configured: $DOCKER_LIST"
else
  log "Configuring Docker APT repository..."
  echo "$DOCKER_REPO_LINE" | sudo tee "$DOCKER_LIST" > /dev/null
  REPO_CHANGED=1
fi

MISSING_DOCKER_PACKAGES=()
for pkg in "${DOCKER_PACKAGES[@]}"; do
  if is_pkg_installed "$pkg"; then log "Docker package already installed: $pkg"; else MISSING_DOCKER_PACKAGES+=("$pkg"); fi
done

if [ "$REPO_CHANGED" -eq 1 ] || [ "${#MISSING_DOCKER_PACKAGES[@]}" -gt 0 ]; then log "Updating APT package index..."; sudo apt-get update; fi
if [ "${#MISSING_DOCKER_PACKAGES[@]}" -gt 0 ]; then log "Installing Docker packages: ${MISSING_DOCKER_PACKAGES[*]}"; sudo apt-get install -y "${MISSING_DOCKER_PACKAGES[@]}"; else log "All Docker packages are already installed."; fi

sudo systemctl enable --now docker >/dev/null 2>&1 || true

if getent group docker > /dev/null 2>&1; then log "Docker group exists."; else log "Creating docker group..."; sudo groupadd docker; fi

GROUP_CHANGED=0
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  log "User '$TARGET_USER' is already in docker group."
else
  log "Adding user '$TARGET_USER' to docker group..."
  sudo usermod -aG docker "$TARGET_USER"
  GROUP_CHANGED=1
fi

log "Docker version:"
docker --version
log "Docker Compose version:"
docker compose version

if docker ps >/dev/null 2>&1; then
  log "Docker permission check passed in current shell."
  log "Done."
  exit 0
fi

if [ "$GROUP_CHANGED" -eq 1 ] || id "$TARGET_USER" | grep -q 'docker'; then
  warn "Current shell does not have docker group permission yet."
  log "Verifying Docker permission in a docker-group shell..."
  sg docker -c "docker ps >/dev/null"
  log "Docker permission check passed in docker-group shell."
  warn "Opening a new shell with docker group applied. Run docker compose commands in this shell."
  exec sg docker -c "exec ${SHELL:-/bin/bash}"
fi

echo "[ERROR] Docker permission check failed. Try: sudo usermod -aG docker $TARGET_USER && newgrp docker"
exit 1