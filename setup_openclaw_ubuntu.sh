#!/bin/bash
set -euo pipefail

USERNAME="openclaw"
SWAP_DEFAULT_GB=2
SWAPPINESS=10
CREDENTIALS_FILE="/root/openclaw_credentials.txt"
SETUP_MARKER="/root/.openclaw_setup_done"

log() { echo -e "\n🦞 $*"; }
warn() { echo -e "\n⚠️  $*"; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
  fi
}

gen_password() {
  openssl rand -base64 18 | tr -d '\n'
}

get_saved_password() {
  if [[ -f "${CREDENTIALS_FILE}" ]]; then
    awk -F': ' '/^Password:/ {print $2; exit}' "${CREDENTIALS_FILE}"
  fi
}

get_swap_mb() {
  awk '/SwapTotal:/ {printf "%.0f\n", $2/1024}' /proc/meminfo
}

is_amd64() {
  [[ "$(dpkg --print-architecture)" == "amd64" ]]
}

is_wsl() {
  grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null || \
    grep -qiE '(microsoft|wsl)' /proc/sys/kernel/osrelease 2>/dev/null
}

has_systemd() {
  [[ -d /run/systemd/system ]] && systemctl is-system-running >/dev/null 2>&1 || \
    [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]
}

require_root
export DEBIAN_FRONTEND=noninteractive

# =========================
# SYSTEM UPDATE + PACKAGES
# =========================

log "Updating system..."

apt update

apt-get -o Dpkg::Use-Pty=0 install -y --no-install-recommends \
  software-properties-common \
  curl wget git unzip htop mc \
  ca-certificates gnupg lsb-release \
  net-tools openssl \
  jq moreutils \
  ufw fail2ban \
  build-essential procps file

apt upgrade -y
apt autoremove -y

# =========================
# ENABLE REPOS
# =========================

log "Enabling repositories..."

add-apt-repository -y universe
add-apt-repository -y multiverse
add-apt-repository -y restricted

# =========================
# USER SETUP
# =========================

log "Ensuring user '${USERNAME}' exists..."

USER_CREATED="no"
USER_PASS=""

if id "${USERNAME}" >/dev/null 2>&1; then
  warn "User '${USERNAME}' already exists."
  USER_PASS="$(get_saved_password || true)"
else
  USER_CREATED="yes"
  USER_PASS="$(gen_password)"
  adduser --disabled-password --gecos "" "${USERNAME}"
  echo "${USERNAME}:${USER_PASS}" | chpasswd
fi

usermod -aG sudo "${USERNAME}"

echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USERNAME}"
chmod 440 "/etc/sudoers.d/${USERNAME}"
visudo -cf "/etc/sudoers.d/${USERNAME}" >/dev/null

if [[ "${USER_CREATED}" == "yes" ]]; then
  {
    echo "User: ${USERNAME}"
    echo "Password: ${USER_PASS}"
  } > "${CREDENTIALS_FILE}"
  chmod 600 "${CREDENTIALS_FILE}"
fi

# =========================
# WSL2: ENABLE SYSTEMD
# =========================

if is_wsl; then
  WSL_CONF="/etc/wsl.conf"
  if ! grep -q '^\[boot\]' "${WSL_CONF}" 2>/dev/null || \
     ! grep -q '^systemd=true' "${WSL_CONF}" 2>/dev/null; then
    log "Enabling systemd for WSL2..."

    # Ensure [boot] section with systemd=true exists
    if [[ -f "${WSL_CONF}" ]] && grep -q '^\[boot\]' "${WSL_CONF}"; then
      # [boot] section exists — add or replace systemd line
      if grep -q '^systemd=' "${WSL_CONF}"; then
        sed -i 's/^systemd=.*/systemd=true/' "${WSL_CONF}"
      else
        sed -i '/^\[boot\]/a systemd=true' "${WSL_CONF}"
      fi
    else
      # Append [boot] section
      printf '\n[boot]\nsystemd=true\n' >> "${WSL_CONF}"
    fi

    warn "systemd has been enabled in ${WSL_CONF}."
    warn "Run 'wsl --shutdown' from PowerShell after this script finishes, then reopen WSL."
  else
    log "systemd already enabled in ${WSL_CONF}."
  fi

  # Enable user service lingering so openclaw-gateway runs after logout
  if command -v loginctl >/dev/null 2>&1 && has_systemd; then
    loginctl enable-linger "${USERNAME}" 2>/dev/null || true
  fi
fi

# =========================
# FIREWALL
# =========================

if is_wsl; then
  warn "WSL detected — skipping UFW (firewall is managed by Windows host)."
else
  log "Configuring firewall..."

  # Ensure OpenSSH server is installed so the UFW profile exists.
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    apt-get -o Dpkg::Use-Pty=0 install -y --no-install-recommends openssh-server || true
  fi

  if ufw app list 2>/dev/null | grep -q '^  OpenSSH$\|OpenSSH'; then
    ufw allow OpenSSH >/dev/null
  else
    warn "OpenSSH UFW profile not found — falling back to port 22/tcp."
    ufw allow 22/tcp >/dev/null
  fi
  ufw --force enable >/dev/null
fi

# =========================
# FAIL2BAN
# =========================

if has_systemd; then
  log "Starting fail2ban..."
  systemctl enable fail2ban
  systemctl restart fail2ban
else
  warn "systemd not active — skipping fail2ban (likely WSL without systemd)."
fi

# =========================
# SWAP
# =========================

if is_wsl; then
  warn "WSL detected — skipping swap setup (managed by Windows host via .wslconfig)."
else
  log "Configuring swap..."

  SWAPFILE="/swapfile"
  TARGET_SWAP_MB=$((SWAP_DEFAULT_GB * 1024))
  CURRENT_SWAP_MB="$(get_swap_mb)"

  if [[ "${CURRENT_SWAP_MB}" -lt "${TARGET_SWAP_MB}" ]]; then

    swapoff "${SWAPFILE}" 2>/dev/null || true
    rm -f "${SWAPFILE}"

    if ! fallocate -l "${SWAP_DEFAULT_GB}G" "${SWAPFILE}" 2>/dev/null; then
      warn "fallocate failed, using dd..."
      dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${TARGET_SWAP_MB}" status=progress
    fi

    chmod 600 "${SWAPFILE}"
    mkswap "${SWAPFILE}" >/dev/null
    swapon "${SWAPFILE}"

    grep -q "${SWAPFILE}" /etc/fstab || echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
  fi

  sysctl -w "vm.swappiness=${SWAPPINESS}" >/dev/null 2>&1 || true
  echo "vm.swappiness=${SWAPPINESS}" > /etc/sysctl.d/99-swappiness.conf
fi

# =========================
# HOMEBREW
# =========================

log "Installing Homebrew..."

BREW_PREFIX="/home/linuxbrew/.linuxbrew"
BREW_BIN="${BREW_PREFIX}/bin/brew"
BREW_ENV_LINE='eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"'

if [[ ! -x "${BREW_BIN}" ]]; then
  su - "${USERNAME}" -c 'CI=1 NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
fi

for FILE in "/home/${USERNAME}/.bashrc" "/home/${USERNAME}/.profile"; do
  if ! grep -q "linuxbrew" "${FILE}" 2>/dev/null; then
    echo "" >> "${FILE}"
    echo "${BREW_ENV_LINE}" >> "${FILE}"
  fi
done

log "Installing GCC via brew..."

su - "${USERNAME}" -c "export PATH=${BREW_PREFIX}/bin:\$PATH && brew install gcc || true"

# =========================
# GOOGLE CHROME
# =========================

log "Installing Chrome..."

if is_amd64; then

  su - "${USERNAME}" -c "
    cd /home/${USERNAME}
    wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    sudo dpkg -i google-chrome-stable_current_amd64.deb || true
    sudo apt --fix-broken install -y
    rm -f google-chrome-stable_current_amd64.deb
  "

else

  warn "Skipping Chrome install: not amd64"

fi

# =========================
# CLAUDE CLI
# =========================

log "Installing Claude CLI..."

su - "${USERNAME}" -c '
curl -fsSL https://claude.ai/install.sh | bash

for FILE in "$HOME/.bashrc" "$HOME/.profile"; do
  if ! grep -q ".local/bin" "$FILE" 2>/dev/null; then
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$FILE"
  fi
done
'

# =========================
# OPENCLAW INSTALL
# =========================

log "Installing OpenClaw..."

su - "${USERNAME}" -c '
curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard
'

# =========================
# OPENCLAW SETUP
# =========================

log "Running openclaw setup..."

su - "${USERNAME}" -c '
set -e

sleep 2

export PATH="$HOME/.npm-global/bin:$PATH"

$HOME/.npm-global/bin/openclaw setup

jq '"'"'. * {"agents":{"defaults":{"elevatedDefault":"full","sandbox":{"mode":"off"}}},"browser":{"enabled":true,"executablePath":"/usr/bin/google-chrome-stable","headless":true,"noSandbox":true},"session":{"dmScope":"per-channel-peer","reset":{"mode":"idle","idleMinutes":240}},"update":{"channel":"stable","auto":{"enabled":true,"stableDelayHours":6,"stableJitterHours":12,"betaCheckIntervalHours":1}},"tools":{"profile":"full"}}'"'"' \
~/.openclaw/openclaw.json | sponge ~/.openclaw/openclaw.json

cat > ~/.openclaw/exec-approvals.json << '"'"'APPROVALS'"'"'
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full",
    "autoAllowSkills": true
  }
}
APPROVALS
'

# =========================
# VALIDATE CONFIGURATION
# =========================

log "Validating configuration..."

su - "${USERNAME}" -c '
export PATH="$HOME/.npm-global/bin:$PATH"
$HOME/.npm-global/bin/openclaw doctor --yes --repair --non-interactive
' >/dev/null 2>&1

# =========================
# SUMMARY
# =========================

log "Setup complete."

if is_wsl; then
  SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
else
  SERVER_IP="$(curl -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
fi

echo
echo "====== SUMMARY ======"
echo "Сервер IP: ${SERVER_IP}"
echo
echo "Логин: ${USERNAME}"

if [[ -n "${USER_PASS}" ]]; then
  echo "Пароль: ${USER_PASS}"
  echo "Credentials saved to: ${CREDENTIALS_FILE}"
else
  echo "Пароль: unchanged (not available to script)"
fi

echo
echo "Swap: $(get_swap_mb) MB"
echo "Claude: $(su - ${USERNAME} -c 'export PATH=$HOME/.local/bin:$PATH; command -v claude >/dev/null 2>&1 && claude --version || echo not-detected')"

if is_wsl; then
  if ! has_systemd; then
    echo
    echo "⚠️  systemd включён в /etc/wsl.conf, но ещё не активен."
    echo "Выполните в PowerShell: wsl --shutdown"
    echo "Затем снова откройте WSL."
  fi
else
  echo
  echo "SSH:"
  echo "ssh ${USERNAME}@${SERVER_IP}"
fi

# Marker file for cloud-init: check with `ls /root/.openclaw_setup_done`
touch "${SETUP_MARKER}"
