#!/usr/bin/env bash
#
# server-hardening.sh
# Interactive, CIS-aligned hardening for Debian / Ubuntu servers (ISO 27001 prep).
# Maintained by Abhishek Chougule.
#
# TARGET OS: Debian and Ubuntu only (uses apt). Do not run on RHEL/Rocky/Alma
#            without rewriting the package and service steps.
#
# SAFETY MODEL:
#   1. Dry-run by default. Nothing is changed until you choose Apply (or --apply).
#   2. Every config file is backed up (file.bak.TIMESTAMP) before editing.
#   3. SSH and firewall steps refuse to do anything that would lock you out.
#   4. Changing the SSH port is done as a safe migration (old and new port both
#      stay open during the switch, so there is no lockout window).
#   5. sshd config is validated with "sshd -t" before any restart.
#
# USAGE:
#   sudo bash server-hardening.sh            # interactive (asks mode, modules, ports)
#   sudo bash server-hardening.sh --apply    # interactive, but pre-selects Apply mode
#   sudo bash server-hardening.sh -y         # non-interactive, uses the CONFIG defaults
#   sudo bash server-hardening.sh -y --apply # non-interactive and apply (for automation)
#   bash server-hardening.sh --help          # show full help
#
# When run without a terminal (piped or from cron), it is automatically
# non-interactive and uses the CONFIG block below.
#

set -uo pipefail

# =====================================================================
# CONFIG  (defaults used in non-interactive mode, and as starting points
#          for the interactive prompts)
# =====================================================================

# Master switch. Interactive runs ask for this. Pass --apply to pre-select Apply.
DRY_RUN=true

# SSH port sshd should listen on. Blank = keep the current port. Interactive runs
# ask for this. Setting a different port triggers a safe migration (no lockout).
SSH_PORT=""

# Inbound TCP ports to allow through the firewall, space separated. SSH is allowed
# automatically. Interactive runs ask for this.
ALLOWED_TCP_PORTS="80 443"

# Email for unattended-upgrade reports. Leave blank to skip mail.
ADMIN_EMAIL=""

# Configure unattended-upgrades to automatically reboot if required (at 02:00)
AUTO_REBOOT=false

# Run a full package upgrade now as part of the patching module. Off by default
# because it can restart services on a production host.
APPLY_UPGRADES_NOW=false

# ---- Module defaults (used as the starting selection) ----
ENABLE_UPDATES=true               # 1  Patching: unattended security upgrades
ENABLE_SSH=true                   # 2  SSH hardening (key-only, no root password)
ENABLE_FIREWALL=true              # 3  Host firewall (ufw, default deny inbound)
ENABLE_FAIL2BAN=true              # 4  Brute-force protection (fail2ban)
ENABLE_SYSCTL=true                # 5  Kernel and network hardening (sysctl)
ENABLE_AUDITD=true                # 6  Audit logging (auditd + rules)
ENABLE_TIMESYNC=true              # 7  Time synchronisation (chrony)
ENABLE_LOGIN_POLICY=true          # 8  Password and login policy
ENABLE_DISABLE_FILESYSTEMS=true   # 9  Disable unused filesystems and protocols
ENABLE_COREDUMPS=true             # 10 Disable core dumps
ENABLE_SHARED_MEMORY=false        # 11 Mount /dev/shm noexec,nosuid,nodev (edits fstab)
ENABLE_AIDE=true                  # 12 File integrity monitoring (AIDE)
ENABLE_REMOVE_PACKAGES=true       # 13 Remove legacy insecure packages
ENABLE_SESSION_TIMEOUT=true       # 14 Idle shell timeout
ENABLE_PROCESS_ACCOUNTING=true    # 15 Process accounting and activity history
ENABLE_CLAMAV=false               # 16 Anti-malware (clamav, resource heavy)

# =====================================================================
# Internals (no need to edit below this line)
# =====================================================================

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOGFILE="/var/log/server-hardening-${TIMESTAMP}.log"
APPLIED=()
SKIPPED=()
FAILED=()
SSH_MIGRATE_OLD_PORT=""        # set by mod_ssh when the SSH port is being changed
MODE_SET=false                 # true if --apply/--dry-run was passed
FORCE_NONINTERACTIVE=false
FORCE_INTERACTIVE=false
SELECTED_PROFILE="CONFIG Default"

# Colors. Terminal green accent is #00FF9C. Disabled when not a terminal,
# when NO_COLOR is set, or for dumb terminals.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[38;2;0;255;156m'
  C_RED=$'\033[38;2;255;90;90m'
  C_YELLOW=$'\033[38;2;240;200;60m'
  C_CYAN=$'\033[38;2;90;200;250m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''
fi

show_help() {
  cat <<'HELP'
server-hardening.sh  (maintained by Abhishek Chougule)

Interactive CIS-aligned hardening for Debian / Ubuntu, built for ISO 27001 prep.

USAGE:
  sudo bash server-hardening.sh             Interactive. Asks for mode, modules,
                                            SSH port, and allowed ports.
  sudo bash server-hardening.sh --apply     Interactive, with Apply preselected.
  sudo bash server-hardening.sh --dry-run   Interactive, with Preview preselected.
  sudo bash server-hardening.sh -y          Non-interactive. Uses the CONFIG block.
  sudo bash server-hardening.sh -y --apply  Non-interactive and applies changes.
  bash server-hardening.sh --help           This help.

FLAGS:
  --apply              Apply changes (default is a safe dry-run preview).
  --dry-run            Force preview mode.
  -y, --non-interactive   Skip all prompts and use the CONFIG defaults.
  --interactive        Force the interactive prompts even without a terminal.
  --production         Bypass prompts, use Production Recommended profile.
  --all                Bypass prompts, use ALL Hardening Modules.
  --custom             Bypass prompts, use default module selections.
  --ports "80 443"     Specify allowed TCP ports (bypasses prompt).
  --auto-reboot        Enable automatic reboot for unattended-upgrades.
  -h, --help           Show this help.

SAFETY:
  Dry-run by default. Config files are backed up before editing. SSH and the
  firewall will not lock you out, and an SSH port change keeps the old port open
  until you confirm the new one works.
HELP
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)              DRY_RUN=false; MODE_SET=true ;;
    --dry-run)            DRY_RUN=true;  MODE_SET=true ;;
    -y|--non-interactive) FORCE_NONINTERACTIVE=true ;;
    --interactive)        FORCE_INTERACTIVE=true ;;
    --production)         FORCE_NONINTERACTIVE=true; CLI_PROFILE="production" ;;
    --all)                FORCE_NONINTERACTIVE=true; CLI_PROFILE="all" ;;
    --custom)             FORCE_NONINTERACTIVE=true; CLI_PROFILE="custom" ;;
    --auto-reboot)        AUTO_REBOOT=true ;;
    --ports)
      if [ -n "${2:-}" ]; then
        ALLOWED_TCP_PORTS="$2"
        SKIP_PORTS_PROMPT=true
        shift
      else
        echo "--ports requires a quoted string of ports (e.g., \"80 443\")"
        exit 1
      fi
      ;;
    -h|--help)            show_help; exit 0 ;;
    "")                   ;;
    *) echo "Unknown argument: $1"; echo "Use --help."; exit 1 ;;
  esac
  shift
done

# ---- Logging and UI helpers ----
_log() {
  printf '%s\n' "$*"
  if [ -n "${LOGFILE:-}" ]; then printf '%s\n' "$*" >> "$LOGFILE" 2>/dev/null || true; fi
}
_emit() {
  local color="$1" tag="$2"; shift 2
  printf '%b%s%b %s\n' "$color" "$tag" "$C_RESET" "$*"
  if [ -n "${LOGFILE:-}" ]; then printf '%s %s\n' "$tag" "$*" >> "$LOGFILE" 2>/dev/null || true; fi
}
info()  { _emit "$C_CYAN"   "[INFO] " "$*"; }
ok()    { _emit "$C_GREEN"  "[OK]   " "$*"; }
warn()  { _emit "$C_YELLOW" "[WARN] " "$*"; }
err()   { _emit "$C_RED"    "[FAIL] " "$*"; }
skip()  { _emit "$C_DIM"    "[SKIP] " "$*"; }
dry()   { _emit "$C_DIM"    "[DRY-RUN]" "$*"; }
head_() {
  printf '\n%b== %s ==%b\n' "$C_BOLD$C_GREEN" "$*" "$C_RESET"
  if [ -n "${LOGFILE:-}" ]; then printf '\n== %s ==\n' "$*" >> "$LOGFILE" 2>/dev/null || true; fi
}
section() { printf '\n%b%s%b\n' "$C_BOLD$C_GREEN" "$*" "$C_RESET"; }

# Run a mutating command, or echo it in dry-run mode.
run() {
  if [ "$DRY_RUN" = true ]; then dry "$*"; return 0; fi
  "$@"
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] This script must run as root. Use: sudo bash $0"
    exit 1
  fi
}

check_os() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "[FAIL] apt-get not found. This script targets Debian/Ubuntu only."
    exit 1
  fi
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "Detected OS: ${PRETTY_NAME:-unknown}"
  fi
}

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  if [ "$DRY_RUN" = true ]; then
    dry "backup $f -> ${f}.bak.${TIMESTAMP}"
  else
    cp -a "$f" "${f}.bak.${TIMESTAMP}"
  fi
}

append_line() {
  local line="$1" file="$2"
  if [ -f "$file" ] && grep -qxF -- "$line" "$file" 2>/dev/null; then
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    dry "append to $file: $line"
  else
    printf '%s\n' "$line" >> "$file"
  fi
}

write_file() {
  local path="$1" content="$2"
  backup_file "$path"
  if [ "$DRY_RUN" = true ]; then
    dry "write $path"
  else
    printf '%s\n' "$content" > "$path"
  fi
}

set_sshd() {
  local key="$1" value="$2" file="/etc/ssh/sshd_config"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$file"; then
    run sed -ri "s|^[[:space:]]*#?[[:space:]]*(${key})[[:space:]].*|\1 ${value}|" "$file"
  else
    append_line "${key} ${value}" "$file"
  fi
}

set_logindef() {
  local key="$1" value="$2" file="/etc/login.defs"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$file"; then
    run sed -ri "s|^[[:space:]]*#?[[:space:]]*(${key})[[:space:]].*|\1\t${value}|" "$file"
  else
    append_line "${key} ${value}" "$file"
  fi
}

apt_install() {
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

detect_cloud_provider() {
  local provider="none"
  if [ -r /sys/class/dmi/id/sys_vendor ]; then
    local vendor; vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    case "$vendor" in
      *amazon*) provider="AWS" ;;
      *microsoft*) provider="Azure" ;;
      *google*) provider="GCP" ;;
      *hetzner*) provider="Hetzner" ;;
      *digitalocean*) provider="DigitalOcean" ;;
    esac
  fi
  echo "$provider"
}

detect_ssh_port() {
  local p
  p="$( { grep -hEi '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true; } | awk '{print $2}' | tail -n1 )"
  echo "${p:-22}"
}

mark() {
  case "$1" in
    applied) APPLIED+=("$2") ;;
    skipped) SKIPPED+=("$2") ;;
    failed)  FAILED+=("$2") ;;
  esac
}

# ---- Module metadata (order, labels, and the live on/off state) ----
MOD_ORDER=(updates ssh firewall fail2ban sysctl auditd timesync login_policy \
           disable_filesystems coredumps shared_memory aide remove_packages \
           session_timeout process_accounting clamav)

declare -A MOD_LABEL=(
  [updates]="Patching: unattended security upgrades"
  [ssh]="SSH hardening (key-only, no root password, strong ciphers)"
  [firewall]="Host firewall (ufw, default deny inbound)"
  [fail2ban]="Brute-force protection (fail2ban)"
  [sysctl]="Kernel and network hardening (sysctl)"
  [auditd]="Audit logging (auditd + rules)"
  [timesync]="Time synchronisation (chrony)"
  [login_policy]="Password and login policy"
  [disable_filesystems]="Disable unused filesystems and protocols"
  [coredumps]="Disable core dumps"
  [shared_memory]="Shared Memory Hardening (edits fstab, off by default)"
  [aide]="File integrity monitoring (AIDE)"
  [remove_packages]="Remove legacy insecure packages"
  [session_timeout]="Idle shell timeout"
  [process_accounting]="Process accounting and activity history"
  [clamav]="Anti-malware (clamav, heavy, off by default)"
)

declare -A MOD_ENABLED=(
  [updates]=$ENABLE_UPDATES
  [ssh]=$ENABLE_SSH
  [firewall]=$ENABLE_FIREWALL
  [fail2ban]=$ENABLE_FAIL2BAN
  [sysctl]=$ENABLE_SYSCTL
  [auditd]=$ENABLE_AUDITD
  [timesync]=$ENABLE_TIMESYNC
  [login_policy]=$ENABLE_LOGIN_POLICY
  [disable_filesystems]=$ENABLE_DISABLE_FILESYSTEMS
  [coredumps]=$ENABLE_COREDUMPS
  [shared_memory]=$ENABLE_SHARED_MEMORY
  [aide]=$ENABLE_AIDE
  [remove_packages]=$ENABLE_REMOVE_PACKAGES
  [session_timeout]=$ENABLE_SESSION_TIMEOUT
  [process_accounting]=$ENABLE_PROCESS_ACCOUNTING
  [clamav]=$ENABLE_CLAMAV
)

# ---- Banner ----
show_banner() {
  printf '%b' "$C_GREEN$C_BOLD"
  cat <<'BANNER'
 ___                        _  _             _          _           
/ __| ___ _ ___ _____ _ _  | || |__ _ _ _ __| |___ _ _ (_)_ _  __ _ 
\__ \/ -_) '_\ V / -_) '_| | __ / _` | '_/ _` / -_) ' \| | ' \/ _` |
|___/\___|_|  \_/\___|_|   |_||_\__,_|_| \__,_\___|_||_|_|_||_\__, |
                                                              |___/ 
BANNER
  printf '%b' "$C_RESET"
  printf '%b  ISO 27001 hardening baseline for Debian / Ubuntu%b\n' "$C_DIM" "$C_RESET"
  printf '%b  maintained by Abhishek Chougule %b\n\n' "$C_GREEN" "$C_RESET"
}

# ---- Interactive prompts ----
warn_risky_ports() {
  local p
  for p in $ALLOWED_TCP_PORTS; do
    case "$p" in
      3306) warn "Port 3306 (database) will be open to all sources. If the DB lives on this host with the app, you usually do not need it public. Consider restricting it to a specific IP." ;;
      5432) warn "Port 5432 (Postgres) will be open to all sources. Consider restricting it to a specific IP." ;;
      6379) warn "Port 6379 (Redis) should almost never be public. Restrict it to 127.0.0.1 or a specific IP." ;;
      9200) warn "Port 9200 (Elasticsearch) without auth can leak data. Ensure it is secured or restricted." ;;
      27017) warn "Port 27017 (MongoDB) without auth is highly risky. Consider restricting it to a specific IP." ;;
      8000) warn "Port 8000 (Frappe backend) open publicly bypasses nginx and TLS. In production, keep it internal on 127.0.0.1." ;;
      25)   warn "Port 25 (SMTP) is plaintext. Keep only if this host receives inbound mail, and make sure it is not an open relay." ;;
      143)  warn "Port 143 (IMAP) is plaintext. Prefer 993 (IMAPS)." ;;
    esac
  done
}

prompt_mode() {
  section "Run mode"
  printf '  %b1%b  Preview only (dry-run, makes no changes)\n' "$C_GREEN" "$C_RESET"
  printf '  %b2%b  Apply changes\n' "$C_GREEN" "$C_RESET"
  printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
  local input=""; read -r input
  case "$input" in 2) DRY_RUN=false ;; *) DRY_RUN=true ;; esac
}

choose_modules() {
  local input="" i key tok k mark
  while true; do
    section "Select modules  (type numbers to toggle, then press Enter to run)"
    i=1
    for key in "${MOD_ORDER[@]}"; do
      if [ "${MOD_ENABLED[$key]}" = true ]; then
        mark="${C_GREEN}[x]${C_RESET}"
      else
        mark="[ ]"
      fi
      printf '  %2d  %b  %s\n' "$i" "$mark" "${MOD_LABEL[$key]}"
      i=$((i + 1))
    done
    printf '\n  %ba%b all on    %bn%b all off    %bEnter%b run selection\n' \
      "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET"
    printf '%bToggle:%b ' "$C_CYAN" "$C_RESET"
    read -r input
    [ -z "$input" ] && break
    case "$input" in
      a|A) for k in "${MOD_ORDER[@]}"; do MOD_ENABLED[$k]=true; done ;;
      n|N) for k in "${MOD_ORDER[@]}"; do MOD_ENABLED[$k]=false; done ;;
      *)
        for tok in $input; do
          if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#MOD_ORDER[@]}" ]; then
            k="${MOD_ORDER[$((tok - 1))]}"
            if [ "${MOD_ENABLED[$k]}" = true ]; then MOD_ENABLED[$k]=false; else MOD_ENABLED[$k]=true; fi
          fi
        done ;;
    esac
  done
}

prompt_scope() {
  local input="" k

  section "What to run"

  printf '  %b1%b  Run Production Recommended\n' "$C_GREEN" "$C_RESET"
  printf '      Safe defaults for production servers\n'
  printf '      Recommended for Frappe, ERPNext, Nginx, Node.js and application servers\n\n'

  printf '  %b2%b  Run ALL Hardening Modules\n' "$C_GREEN" "$C_RESET"
  printf '      Includes every available module\n'
  printf '      Enables optional modules such as Shared Memory Hardening and ClamAV\n\n'

  printf '  %b3%b  Select Specific Modules\n' "$C_GREEN" "$C_RESET"
  printf '      Choose modules individually\n\n'

  printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
  read -r input

  case "$input" in

    ""|1)
        SELECTED_PROFILE="Production Recommended"
        # Reset all modules
        for k in "${MOD_ORDER[@]}"; do
            MOD_ENABLED[$k]=false
        done

        # Production Recommended
        MOD_ENABLED[updates]=true
        MOD_ENABLED[ssh]=true
        MOD_ENABLED[firewall]=true
        MOD_ENABLED[fail2ban]=true
        MOD_ENABLED[sysctl]=true
        MOD_ENABLED[auditd]=true
        MOD_ENABLED[timesync]=true
        MOD_ENABLED[login_policy]=true
        MOD_ENABLED[disable_filesystems]=true
        MOD_ENABLED[coredumps]=true
        MOD_ENABLED[aide]=true
        MOD_ENABLED[remove_packages]=true
        MOD_ENABLED[session_timeout]=true
        MOD_ENABLED[process_accounting]=true

        # Leave optional modules disabled
        MOD_ENABLED[shared_memory]=false
        MOD_ENABLED[clamav]=false
        ;;

    2)
        SELECTED_PROFILE="ALL Hardening Modules"
        # Enable every module
        for k in "${MOD_ORDER[@]}"; do
            MOD_ENABLED[$k]=true
        done
        ;;

    3)
        SELECTED_PROFILE="Custom Modules"
        choose_modules
        ;;

    *)
        SELECTED_PROFILE="Production Recommended"
        warn "Invalid selection. Using Production Recommended."

        for k in "${MOD_ORDER[@]}"; do
            MOD_ENABLED[$k]=false
        done

        MOD_ENABLED[updates]=true
        MOD_ENABLED[ssh]=true
        MOD_ENABLED[firewall]=true
        MOD_ENABLED[fail2ban]=true
        MOD_ENABLED[sysctl]=true
        MOD_ENABLED[auditd]=true
        MOD_ENABLED[timesync]=true
        MOD_ENABLED[login_policy]=true
        MOD_ENABLED[disable_filesystems]=true
        MOD_ENABLED[coredumps]=true
        MOD_ENABLED[aide]=true
        MOD_ENABLED[remove_packages]=true
        MOD_ENABLED[session_timeout]=true
        MOD_ENABLED[process_accounting]=true
        ;;
  esac
}

prompt_ssh_port() {
  local current input=""
  current="$(detect_ssh_port)"
  section "SSH port"
  printf '  Current SSH port is %b%s%b. Press Enter to keep it, or type a new port.\n' "$C_BOLD" "$current" "$C_RESET"
  printf '  Changing it is a safe migration: the old and new port both stay open until you confirm.\n'
  printf '%bSSH port [%s]:%b ' "$C_CYAN" "$current" "$C_RESET"
  read -r input
  if [ -z "$input" ]; then
    SSH_PORT=""
  elif [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
    SSH_PORT="$input"
  else
    warn "Invalid port '${input}'. Keeping current port ${current}."
    SSH_PORT=""
  fi
}

prompt_server_role() {
  section "Server Type"
  printf '  %b1%b  Frappe / ERPNext (80, 443)\n' "$C_GREEN" "$C_RESET"
  printf '  %b2%b  Node.js (80, 443)\n' "$C_GREEN" "$C_RESET"
  printf '  %b3%b  Docker (80, 443)\n' "$C_GREEN" "$C_RESET"
  printf '  %b4%b  Database (3306)\n' "$C_GREEN" "$C_RESET"
  printf '  %b5%b  Mail Server (25, 465, 587, 993, 995)\n' "$C_GREEN" "$C_RESET"
  printf '  %b6%b  Web Server (80, 443)\n' "$C_GREEN" "$C_RESET"
  printf '  %b7%b  Custom (Choose your own ports)\n\n' "$C_GREEN" "$C_RESET"

  printf '%bChoose [7]:%b ' "$C_CYAN" "$C_RESET"
  local input=""
  read -r input
  SKIP_PORTS_PROMPT=true
  case "$input" in
    1|2|3|6) ALLOWED_TCP_PORTS="80 443" ;;
    4) ALLOWED_TCP_PORTS="3306" ;;
    5) ALLOWED_TCP_PORTS="25 465 587 993 995" ;;
    *) SKIP_PORTS_PROMPT=false ;;
  esac
}

prompt_allowed_ports() {
  local input="" tok valid
  section "Allowed inbound TCP ports"
  printf '  SSH is allowed automatically. List every other port your services need.\n'
  printf '  Default: %b%s%b\n' "$C_BOLD" "$ALLOWED_TCP_PORTS" "$C_RESET"
  printf '%bPorts [Enter = default]:%b ' "$C_CYAN" "$C_RESET"
  read -r input
  if [ -n "$input" ]; then
    valid=1
    for tok in $input; do [[ "$tok" =~ ^[0-9]+$ ]] || valid=0; done
    if [ "$valid" -eq 1 ]; then
      ALLOWED_TCP_PORTS="$input"
    else
      warn "Some entries were not numbers. Keeping: ${ALLOWED_TCP_PORTS}"
    fi
  fi
}

summary_confirm() {
  local cur input="" key first
  cur="$(detect_ssh_port)"
  section "Summary"
  if [ "$DRY_RUN" = true ]; then
    printf '  Mode:          %bPreview (dry-run, no changes)%b\n' "$C_YELLOW" "$C_RESET"
  else
    printf '  Mode:          %bApply%b\n' "$C_RED" "$C_RESET"
  fi
  printf '  Profile:       %b%s%b\n\n' "$C_BOLD" "$SELECTED_PROFILE" "$C_RESET"

  local enabled_cnt=0 disabled_cnt=0
  for key in "${MOD_ORDER[@]}"; do
    if [ "${MOD_ENABLED[$key]}" = true ]; then ((enabled_cnt++)); else ((disabled_cnt++)); fi
  done
  printf '  Modules Enabled : %d\n' "$enabled_cnt"
  printf '  Modules Disabled: %d\n\n' "$disabled_cnt"

  if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "$cur" ]; then
    printf '  SSH port:      %s to %s (safe migration)\n' "$cur" "$SSH_PORT"
  else
    printf '  SSH port:      %s (unchanged)\n' "${SSH_PORT:-$cur}"
  fi
  printf '  Allowed ports: SSH + %s\n\n' "${ALLOWED_TCP_PORTS:-none}"

  printf '  %bModules%b\n\n' "$C_BOLD" "$C_RESET"
  for key in "${MOD_ORDER[@]}"; do
    if [ "${MOD_ENABLED[$key]}" = true ]; then
      printf '   ✓ %s\n' "${MOD_LABEL[$key]%% (*}"
    fi
  done

  printf '\n  %bDisabled%b\n\n' "$C_BOLD" "$C_RESET"
  for key in "${MOD_ORDER[@]}"; do
    if [ "${MOD_ENABLED[$key]}" = false ]; then
      printf '   • %s\n' "${MOD_LABEL[$key]%% (*}"
    fi
  done
  printf '\n'
  warn_risky_ports
  printf '%bProceed? [y/N]:%b ' "$C_YELLOW" "$C_RESET"
  read -r input
  case "$input" in
    y|Y|yes|YES) return 0 ;;
    *) _log ""; info "Cancelled. Nothing was changed."; exit 0 ;;
  esac
}

# =====================================================================
# Modules
# =====================================================================
mod_updates() {
  head_ "1. Patching and automatic security upgrades"
  run apt-get update -y || { err "apt-get update failed"; mark failed updates; return; }
  apt_install unattended-upgrades apt-listchanges

  write_file /etc/apt/apt.conf.d/20auto-upgrades \
'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";'

  local mailline="// Unattended-Upgrade::Mail \"\";"
  [ -n "$ADMIN_EMAIL" ] && mailline="Unattended-Upgrade::Mail \"${ADMIN_EMAIL}\";"
  local auto_reboot="false"
  [ "$AUTO_REBOOT" = true ] && auto_reboot="true"
  
  write_file /etc/apt/apt.conf.d/51hardening-unattended \
"Unattended-Upgrade::Automatic-Reboot \"${auto_reboot}\";
Unattended-Upgrade::Automatic-Reboot-Time \"02:00\";
Unattended-Upgrade::Remove-Unused-Dependencies \"true\";
${mailline}"

  if [ "$APPLY_UPGRADES_NOW" = true ]; then
    warn "Applying full package upgrade now. Services may restart."
    run env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  else
    info "Skipping immediate full upgrade (APPLY_UPGRADES_NOW=false). Ongoing security patches are enabled."
  fi
  ok "Unattended security upgrades configured."
  mark applied updates
}

mod_ssh() {
  head_ "2. SSH hardening"
  local cfg="/etc/ssh/sshd_config"
  if [ ! -f "$cfg" ]; then skip "sshd_config not found, skipping SSH."; mark skipped ssh; return; fi
  backup_file "$cfg"

  # SSH port change, done as a safe migration with no lockout window.
  local current_port; current_port="$(detect_ssh_port)"
  if [ -n "$SSH_PORT" ] && [ "$SSH_PORT" != "$current_port" ]; then
    SSH_MIGRATE_OLD_PORT="$current_port"
    warn "Changing SSH port from ${current_port} to ${SSH_PORT}. sshd will listen on BOTH ports during the transition, so you are not locked out."
    write_file /etc/ssh/sshd_config.d/99-hardening-port.conf \
"Port ${current_port}
Port ${SSH_PORT}"
    warn "FINISH THE SWITCH after you confirm SSH works on ${SSH_PORT}: remove the 'Port ${current_port}' line from /etc/ssh/sshd_config.d/99-hardening-port.conf, run 'sudo ufw delete allow ${current_port}/tcp', then 'sudo systemctl restart ssh'."
  else
    # Normalise so the firewall and fail2ban use the real port.
    [ -z "$SSH_PORT" ] && SSH_PORT="$current_port"
  fi

  # Anti-lockout: detect whether any account has an authorized_keys file.
  local keys_found=0 home
  if [ -s /root/.ssh/authorized_keys ]; then keys_found=1; fi
  if [ -d /home ]; then
    for home in /home/*; do
      [ -s "${home}/.ssh/authorized_keys" ] && keys_found=1
    done
  fi

  # Anti-lockout: detect a non-root user in the sudo/admin group.
  local sudo_user_exists=0
  if getent group sudo >/dev/null 2>&1 && [ -n "$(getent group sudo | cut -d: -f4)" ]; then sudo_user_exists=1; fi
  if getent group admin >/dev/null 2>&1 && [ -n "$(getent group admin | cut -d: -f4)" ]; then sudo_user_exists=1; fi

  set_sshd PubkeyAuthentication yes
  set_sshd PermitEmptyPasswords no
  set_sshd X11Forwarding no
  set_sshd MaxAuthTries 4
  set_sshd LoginGraceTime 30
  set_sshd ClientAliveInterval 300
  set_sshd ClientAliveCountMax 2
  set_sshd IgnoreRhosts yes
  set_sshd HostbasedAuthentication no
  set_sshd AllowAgentForwarding no
  set_sshd AllowTcpForwarding no
  set_sshd PermitTunnel no
  set_sshd GatewayPorts no
  set_sshd Banner /etc/issue.net

  # PermitRootLogin: only fully disable if a sudo user exists, else key-only root.
  if [ "$sudo_user_exists" -eq 1 ]; then
    set_sshd PermitRootLogin no
    info "A non-root sudo user exists, setting PermitRootLogin no."
  else
    set_sshd PermitRootLogin prohibit-password
    warn "No non-root sudo user found. Set PermitRootLogin prohibit-password (key-only root) to avoid lockout. Create a sudo user, then change to 'no'."
  fi

  # PasswordAuthentication: only disable if keys exist anywhere.
  if [ "$keys_found" -eq 1 ]; then
    set_sshd PasswordAuthentication no
    info "SSH keys found, disabling password authentication."
  else
    warn "No authorized_keys found for any account. Leaving password auth ENABLED to avoid lockout. Add your public key, then re-run."
  fi

  # Modern strong algorithms (drop-in keeps it readable and reversible).
  write_file /etc/ssh/sshd_config.d/99-hardening-crypto.conf \
'KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com'

  write_file /etc/issue.net \
'Authorized access only. All activity on this system is logged and monitored.'

  # Validate before restart. A broken config must never reach a restart.
  if [ "$DRY_RUN" = true ]; then
    dry "validate with: sshd -t"
    dry "restart ssh service"
  else
    if sshd -t; then
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart
      ok "SSH hardened and service restarted. Open a NEW session to confirm access before closing this one."
    else
      err "sshd -t failed. Restoring backup and NOT restarting."
      cp -a "${cfg}.bak.${TIMESTAMP}" "$cfg"
      mark failed ssh
      return
    fi
  fi
  mark applied ssh
}

mod_firewall() {
  head_ "3. Host firewall (ufw)"
  local cloud; cloud="$(detect_cloud_provider)"
  if [ "$cloud" != "none" ]; then
    warn "Cloud provider detected (${cloud}). Ensure your cloud security groups allow SSH before applying UFW."
  fi
  apt_install ufw
  [ -z "$SSH_PORT" ] && SSH_PORT="$(detect_ssh_port)"

  # Open every plausible SSH port (current, target, and any in-progress migration)
  # so neither a port change nor module ordering can lock us out.
  local ssh_ports sp
  ssh_ports="$(printf '%s\n' "$(detect_ssh_port)" "$SSH_PORT" "${SSH_MIGRATE_OLD_PORT:-}" | grep -E '^[0-9]+$' | sort -un | xargs)"
  info "Allowing SSH on port(s) ${ssh_ports} before enabling the firewall."

  run ufw default deny incoming
  run ufw default allow outgoing
  for sp in $ssh_ports; do
    run ufw allow "${sp}/tcp"
  done

  local port
  for port in $ALLOWED_TCP_PORTS; do
    run ufw allow "${port}/tcp"
  done

  run ufw logging on
  if [ "$DRY_RUN" = false ]; then
    if ufw status | grep -q "Status: active"; then
      info "UFW already enabled."
    else
      run ufw --force enable
    fi
  else
    dry "ufw --force enable (or skipped if active)"
  fi
  if [ "$DRY_RUN" = true ]; then
    dry "ufw status verbose"
  else
    ufw status verbose | tee -a "$LOGFILE"
  fi
  ok "Firewall configured."
  printf "  SSH: %s\n" "$ssh_ports"
  printf "  TCP: %s\n" "${ALLOWED_TCP_PORTS:-none}"
  mark applied firewall
}

mod_fail2ban() {
  head_ "4. Brute-force protection (fail2ban)"
  if pkg_installed fail2ban; then
    info "fail2ban already installed."
    if systemctl is-enabled fail2ban >/dev/null 2>&1; then
      info "fail2ban already enabled."
    fi
    if systemctl is-active fail2ban >/dev/null 2>&1; then
      info "fail2ban already running."
    fi
  else
    apt_install fail2ban
  fi
  [ -z "$SSH_PORT" ] && SSH_PORT="$(detect_ssh_port)"
  write_file /etc/fail2ban/jail.local \
"[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ${SSH_PORT}"
  run systemctl enable fail2ban
  run systemctl restart fail2ban
  ok "fail2ban active on SSH."
  mark applied fail2ban
}

mod_sysctl() {
  head_ "5. Kernel and network hardening (sysctl)"
  if command -v aa-status >/dev/null 2>&1; then
    if aa-status 2>/dev/null | grep -q "apparmor module is loaded."; then
      info "AppArmor is loaded and active."
    else
      warn "AppArmor is installed but not active."
    fi
  else
    warn "AppArmor is not installed (aa-status missing)."
  fi
  write_file /etc/sysctl.d/99-hardening.conf \
'# Network
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
# Kernel
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0'
  run sysctl --system >/dev/null 2>&1 || run sysctl -p /etc/sysctl.d/99-hardening.conf
  ok "Kernel and network parameters hardened."
  mark applied sysctl
}

mod_auditd() {
  head_ "6. Audit logging (auditd)"
  apt_install auditd audispd-plugins
  write_file /etc/audit/rules.d/hardening.rules \
'## Time changes
-a always,exit -F arch=b64 -S adjtimex,settimeofday -k time-change
-a always,exit -F arch=b32 -S adjtimex,settimeofday -k time-change
-w /etc/localtime -p wa -k time-change
## Identity
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity
## Sudoers
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
## Logins and sessions
-w /var/log/lastlog -p wa -k logins
-w /var/log/faillog -p wa -k logins
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session
## Network environment
-w /etc/hosts -p wa -k system-locale
-w /etc/network/ -p wa -k system-locale
## MAC policy
-w /etc/apparmor/ -p wa -k MAC-policy
-w /etc/apparmor.d/ -p wa -k MAC-policy
## Kernel modules
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,delete_module -k modules'
  run systemctl enable auditd
  run augenrules --load 2>/dev/null || true
  run systemctl restart auditd 2>/dev/null || run service auditd restart
  ok "auditd configured and rules loaded."
  mark applied auditd
}

mod_timesync() {
  head_ "7. Time synchronisation (chrony)"
  apt_install chrony
  run systemctl enable chrony 2>/dev/null || run systemctl enable chronyd 2>/dev/null || true
  run systemctl restart chrony 2>/dev/null || run systemctl restart chronyd 2>/dev/null || true
  ok "chrony installed and enabled."
  mark applied timesync
}

mod_login_policy() {
  head_ "8. Password and login policy"
  set_logindef PASS_MAX_DAYS 90
  set_logindef PASS_MIN_DAYS 1
  set_logindef PASS_WARN_AGE 7
  set_logindef UMASK 027
  set_logindef ENCRYPT_METHOD SHA512

  apt_install libpam-pwquality
  write_file /etc/security/pwquality.conf \
'minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
minclass = 4
maxrepeat = 3
gecoscheck = 1
enforcing = 1'

  # faillock values are written passively. Enabling pam_faillock in the PAM
  # stack is intentionally left manual, since editing common-auth wrongly can
  # block all logins. Enable it deliberately with: pam-auth-update
  write_file /etc/security/faillock.conf \
'deny = 5
unlock_time = 900
fail_interval = 900'
  warn "faillock values written. To activate lockout, enable pam_faillock deliberately (pam-auth-update or edit the PAM stack with care)."
  ok "Password and login policy applied."
  mark applied login_policy
}

mod_disable_filesystems() {
  head_ "9. Disable unused filesystems and network protocols"
  # squashfs is intentionally NOT disabled, since Ubuntu snaps depend on it.
  write_file /etc/modprobe.d/hardening-fs.conf \
'install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install udf /bin/true'
  write_file /etc/modprobe.d/hardening-net.conf \
'install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true'
  ok "Unused filesystems and protocols disabled (effective on next module load or reboot)."
  mark applied disable_filesystems
}

mod_coredumps() {
  head_ "10. Disable core dumps"
  write_file /etc/security/limits.d/99-hardening-coredump.conf \
'* hard core 0
* soft core 0'
  if [ -d /etc/systemd ]; then
    backup_file /etc/systemd/coredump.conf
    write_file /etc/systemd/coredump.conf \
'[Coredump]
Storage=none
ProcessSizeMax=0'
  fi
  ok "Core dumps disabled."
  mark applied coredumps
}

mod_shared_memory() {
  head_ "11. Harden /dev/shm mount"
  warn "This edits /etc/fstab. A wrong fstab entry can stop the server booting. A backup is taken first."
  backup_file /etc/fstab
  if grep -Eq '[[:space:]]/dev/shm[[:space:]]' /etc/fstab 2>/dev/null; then
    skip "/dev/shm already present in fstab. Review it manually rather than auto-editing."
    mark skipped shared_memory
    return
  fi
  append_line 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' /etc/fstab
  run mount -o remount /dev/shm 2>/dev/null || true
  ok "/dev/shm set to noexec,nosuid,nodev."
  mark applied shared_memory
}

mod_aide() {
  head_ "12. File integrity monitoring (AIDE)"
  apt_install aide aide-common
  if [ "$DRY_RUN" = true ]; then
    dry "initialise AIDE database (aideinit). This can take several minutes."
  else
    info "Initialising AIDE database. This can take several minutes."
    if command -v aideinit >/dev/null 2>&1; then
      aideinit -y -f || aideinit || true
    else
      aide --init || true
    fi
    if [ -f /var/lib/aide/aide.db.new ]; then
      cp -a /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    fi
  fi
  ok "AIDE installed and database initialised. A daily check timer ships with aide-common."
  mark applied aide
}

mod_remove_packages() {
  head_ "13. Remove legacy insecure packages"
  local legacy="telnet rsh-client rsh-server talk talkd nis tftp tftpd xinetd ldap-utils prelink"
  local removed=0 p
  for p in $legacy; do
    if pkg_installed "$p"; then
      run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p"
      removed=1
    fi
  done
  if [ "$removed" -eq 1 ]; then
    run apt-get autoremove -y
    ok "Legacy insecure packages removed."
  else
    info "No legacy insecure packages were installed."
  fi
  mark applied remove_packages
}

mod_session_timeout() {
  head_ "14. Idle shell timeout"
  write_file /etc/profile.d/99-tmout.sh \
'# Auto-logout idle interactive shells after 15 minutes
TMOUT=900
readonly TMOUT
export TMOUT'
  ok "Idle shell timeout set to 15 minutes."
  mark applied session_timeout
}

mod_process_accounting() {
  head_ "15. Process accounting and activity history"
  apt_install acct sysstat
  run systemctl enable acct 2>/dev/null || run systemctl enable psacct 2>/dev/null || true
  run systemctl start acct 2>/dev/null || run systemctl start psacct 2>/dev/null || true
  if [ -f /etc/default/sysstat ]; then
    backup_file /etc/default/sysstat
    run sed -ri 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
  fi
  run systemctl enable sysstat 2>/dev/null || true
  run systemctl restart sysstat 2>/dev/null || true
  ok "Process accounting and sysstat enabled."
  mark applied process_accounting
}

mod_clamav() {
  head_ "16. Anti-malware (clamav)"
  warn "clamav downloads a large signature database and uses noticeable memory. Off by default for a reason."
  apt_install clamav clamav-daemon
  run systemctl stop clamav-freshclam 2>/dev/null || true
  run freshclam 2>/dev/null || true
  run systemctl enable clamav-freshclam 2>/dev/null || true
  run systemctl start clamav-freshclam 2>/dev/null || true
  ok "clamav installed and signatures updated."
  mark applied clamav
}


print_security_status() {
  local prof="${SELECTED_PROFILE:-Unknown}"
  local check="✓" cross="✗"

  printf '\n================================================\n\n'
  printf 'Security Status\n\n'

  printf '%s SSH Hardening\n' "$([ "${MOD_ENABLED[ssh]}" = true ] && echo "$check" || echo "$cross")"
  printf '%s Firewall\n' "$([ "${MOD_ENABLED[firewall]}" = true ] && echo "$check" || echo "$cross")"
  printf '%s Fail2Ban\n' "$([ "${MOD_ENABLED[fail2ban]}" = true ] && echo "$check" || echo "$cross")"
  printf '%s Auditd\n' "$([ "${MOD_ENABLED[auditd]}" = true ] && echo "$check" || echo "$cross")"
  printf '%s AIDE\n' "$([ "${MOD_ENABLED[aide]}" = true ] && echo "$check" || echo "$cross")"
  printf '%s Chrony\n\n' "$([ "${MOD_ENABLED[timesync]}" = true ] && echo "$check" || echo "$cross")"

  printf 'Profile\n'
  printf '%s\n\n' "$prof"
  printf '================================================\n\n'
}

generate_reports() {
  local json_file="/var/log/server-hardening-report.json"
  local md_file="/var/log/server-hardening-report.md"

  # Generate JSON
  cat > "$json_file" <<EOF
{
  "timestamp": "${TIMESTAMP}",
  "os": "${PRETTY_NAME:-Unknown}",
  "profile": "${SELECTED_PROFILE:-Unknown}",
  "dry_run": ${DRY_RUN},
  "modules_applied": [$(printf '"%s",' "${APPLIED[@]:-}" | sed 's/,$//')],
  "modules_skipped": [$(printf '"%s",' "${SKIPPED[@]:-}" | sed 's/,$//')],
  "modules_failed": [$(printf '"%s",' "${FAILED[@]:-}" | sed 's/,$//')]
}
EOF

  # Generate Markdown
  cat > "$md_file" <<EOF
# Server Hardening Report

- **Date:** $(date)
- **OS:** ${PRETTY_NAME:-Unknown}
- **Profile:** ${SELECTED_PROFILE:-Unknown}
- **Mode:** $([ "$DRY_RUN" = true ] && echo "Preview (Dry Run)" || echo "Applied")

## Security Status

- SSH Hardening: $([ "${MOD_ENABLED[ssh]}" = true ] && echo "✓" || echo "✗")
- Firewall: $([ "${MOD_ENABLED[firewall]}" = true ] && echo "✓" || echo "✗")
- Fail2Ban: $([ "${MOD_ENABLED[fail2ban]}" = true ] && echo "✓" || echo "✗")
- Auditd: $([ "${MOD_ENABLED[auditd]}" = true ] && echo "✓" || echo "✗")
- AIDE: $([ "${MOD_ENABLED[aide]}" = true ] && echo "✓" || echo "✗")
- Chrony: $([ "${MOD_ENABLED[timesync]}" = true ] && echo "✓" || echo "✗")

## Modules Applied
EOF
  if [ "${#APPLIED[@]}" -eq 0 ]; then
    echo "None" >> "$md_file"
  else
    local mod
    for mod in "${APPLIED[@]}"; do
      echo "- ${MOD_LABEL[$mod]%% (*}" >> "$md_file"
    done
  fi

  cat >> "$md_file" <<EOF

## Modules Skipped
EOF
  if [ "${#SKIPPED[@]}" -eq 0 ]; then
    echo "None" >> "$md_file"
  else
    local mod
    for mod in "${SKIPPED[@]}"; do
      echo "- ${MOD_LABEL[$mod]%% (*}" >> "$md_file"
    done
  fi

  if [ "${#FAILED[@]}" -gt 0 ]; then
    cat >> "$md_file" <<EOF

## Modules Failed
EOF
    local mod
    for mod in "${FAILED[@]}"; do
      echo "- ${MOD_LABEL[$mod]%% (*}" >> "$md_file"
    done
  fi

  info "Reports generated: ${json_file} and ${md_file}"
}

# =====================================================================
# Main
# =====================================================================

main() {
  require_root
  show_banner
  check_os

  local interactive=false
  if [ "$FORCE_INTERACTIVE" = true ]; then
    interactive=true
  elif [ "$FORCE_NONINTERACTIVE" = true ]; then
    interactive=false
  elif [ -t 0 ]; then
    interactive=true
  fi

  if [ "$interactive" = true ]; then
    [ "$MODE_SET" = false ] && prompt_mode
    prompt_scope
    prompt_ssh_port
    prompt_server_role
    if [ "${SKIP_PORTS_PROMPT:-false}" = false ]; then
      prompt_allowed_ports
    fi
    summary_confirm
  else
    info "Non-interactive run. Using configuration defaults from the CONFIG block."
    warn_risky_ports
  fi

  head_ "Server hardening run started"
  if [ "$DRY_RUN" = true ]; then
    warn "DRY-RUN mode. No changes will be made. Choose Apply (or pass --apply) to apply."
  else
    warn "APPLY mode. Changes WILL be made. Backups use the suffix .bak.${TIMESTAMP}"
  fi
  info "Log file: ${LOGFILE}"


  local mod
  for mod in "${MOD_ORDER[@]}"; do
    if [ "${MOD_ENABLED[$mod]}" = true ]; then
      "mod_${mod}"
    else
      skip "${MOD_LABEL[$mod]%% (*} (disabled in profile)"
      mark skipped "$mod"
    fi
  done

  head_ "Summary"

  local applied_title="Applied Modules"
  [ "$DRY_RUN" = true ] && applied_title="Modules Selected"
  printf '  %b%s%b\n\n' "$C_BOLD" "$applied_title" "$C_RESET"
  if [ "${#APPLIED[@]}" -eq 0 ]; then
    printf '   none\n'
  else
    for mod in "${APPLIED[@]}"; do
      printf '   ✓ %s\n' "${MOD_LABEL[$mod]%% (*}"
    done
  fi
  printf '\n'

  printf '  %bSkipped Modules%b\n\n' "$C_BOLD" "$C_RESET"
  if [ "${#SKIPPED[@]}" -eq 0 ]; then
    printf '   none\n'
  else
    for mod in "${SKIPPED[@]}"; do
      printf '   • %s\n' "${MOD_LABEL[$mod]%% (*}"
    done
  fi
  printf '\n'

  printf '=========================================\n'
  printf 'Hardening Completed Successfully\n'
  printf '=========================================\n\n'
  printf 'Applied : %d\n' "${#APPLIED[@]}"
  printf 'Skipped : %d\n' "${#SKIPPED[@]}"
  printf 'Failed  : %d\n\n' "${#FAILED[@]}"
  
  if [ "${#FAILED[@]}" -gt 0 ]; then
    err "Failed modules: ${FAILED[*]}"
  fi

  _log ""
  if [ "$DRY_RUN" = true ]; then
    warn "This was a preview. Nothing changed. Run again and choose Apply when ready."
  else
    warn "Done. Before closing this session, open a NEW SSH session and confirm you can still log in."
    print_security_status

    if [ -f /var/run/reboot-required ]; then
      warn "Reboot required"
    else
      ok "No reboot required"
    fi
    printf '================================================\n'
    generate_reports
  fi
}

main
