#!/usr/bin/env bash
#
# server-user-management.sh
# Server User Management
# Version 1.0.0
# Maintained by Abhishek Chougule
#
# Target OS: Debian / Ubuntu
#

set -uo pipefail

# =====================================================================
# CONFIG
# =====================================================================
DRY_RUN=true
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="/var/log"
LOGFILE="${LOG_DIR}/server-user-management-${TIMESTAMP}.log"
LOGFILE_MD="${LOG_DIR}/server-user-management-${TIMESTAMP}.md"
LOGFILE_JSON="${LOG_DIR}/server-user-management-${TIMESTAMP}.json"

# Track actions for reporting
declare -A REPORT_DATA=()

# Colors
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[38;2;0;255;156m'
  C_RED=$'\033[38;2;255;90;90m'
  C_YELLOW=$'\033[38;2;240;200;60m'
  C_CYAN=$'\033[38;2;90;200;250m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''
fi

# =====================================================================
# Logging & Helpers
# =====================================================================
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

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  if [ "$DRY_RUN" = true ]; then
    dry "backup $f -> ${f}.bak.${TIMESTAMP}"
  else
    cp -a "$f" "${f}.bak.${TIMESTAMP}"
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

record_action() {
  local key="$1"
  local val="$2"
  REPORT_DATA["$key"]="$val"
}

# =====================================================================
# UI Functions
# =====================================================================
show_banner() {
  printf '%b' "$C_GREEN$C_BOLD"
  cat <<'BANNER'
=========================================
Server User Management
Version 1.0.0
Maintained by Abhishek Chougule
=========================================
BANNER
  printf '%b' "$C_RESET"
}

prompt_mode() {
  section "Run mode"
  printf '  %b1%b  Preview only (dry-run, makes no changes)\n' "$C_GREEN" "$C_RESET"
  printf '  %b2%b  Apply changes\n' "$C_GREEN" "$C_RESET"
  printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
  local input=""
  read -r input
  case "$input" in 2) DRY_RUN=false ;; *) DRY_RUN=true ;; esac
}

# =====================================================================
# Module: Frappe / Bench Detection
# =====================================================================
FRAPPE_FOUND=false
BENCH_USER=""
BENCH_DIR=""
COMP_BENCH=false
COMP_SUPERVISOR=false
COMP_NGINX=false
COMP_REDIS=false
COMP_MARIADB=false

detect_components() {
  command -v bench >/dev/null 2>&1 && COMP_BENCH=true
  command -v supervisorctl >/dev/null 2>&1 && COMP_SUPERVISOR=true
  command -v nginx >/dev/null 2>&1 && COMP_NGINX=true
  command -v redis-cli >/dev/null 2>&1 && COMP_REDIS=true
  command -v mysql >/dev/null 2>&1 && COMP_MARIADB=true
}

detect_benches() {
  info "Searching for Bench installations..."
  local benches=()
  while IFS= read -r -d '' b; do
    benches+=("$b")
  done < <(find /home -maxdepth 2 -type d -name "*bench*" -print0 2>/dev/null)

  if [ ${#benches[@]} -gt 0 ]; then
    FRAPPE_FOUND=true
    info "Detected Benches:"
    for b in "${benches[@]}"; do
      printf "  ✓ %s\n" "$b"
    done
    printf '\n%bIs this a Frappe Server?%b\n' "$C_GREEN" "$C_RESET"
    printf '  %b1%b  Yes\n' "$C_GREEN" "$C_RESET"
    printf '  %b2%b  No\n' "$C_GREEN" "$C_RESET"
    printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
    local input=""
    read -r input
    if [[ "$input" == "2" ]]; then
      FRAPPE_FOUND=false
      return
    fi
    
    # Bench Users
    local users=()
    for b in "${benches[@]}"; do
      u=$(stat -c '%U' "$b")
      if [[ ! " ${users[*]} " =~ " ${u} " ]]; then
        users+=("$u")
      fi
    done
    
    printf '\n%bDetected Bench Users:%b\n' "$C_GREEN" "$C_RESET"
    local i=1
    for u in "${users[@]}"; do
      printf '  %b%d.%b %s\n' "$C_GREEN" "$i" "$C_RESET" "$u"
      ((i++))
    done
    printf '  %b%d.%b Enter manually\n' "$C_GREEN" "$i" "$C_RESET"
    printf '%bChoose Bench User [1]:%b ' "$C_CYAN" "$C_RESET"
    read -r input
    if [[ -z "$input" ]]; then input=1; fi
    if [[ "$input" -ge 1 ]] && [[ "$input" -le ${#users[@]} ]]; then
      BENCH_USER="${users[$((input-1))]}"
    else
      printf '%bEnter Bench User manually:%b ' "$C_CYAN" "$C_RESET"
      read -r BENCH_USER
    fi
    
    detect_components
    head_ "Bench Environment"
    if $COMP_BENCH; then printf "  ✓ bench [Installed]\n"; fi
    if $COMP_SUPERVISOR; then printf "  ✓ Supervisor [Installed]\n"; fi
    if $COMP_NGINX; then printf "  ✓ Nginx [Installed]\n"; fi
    if $COMP_REDIS; then printf "  ✓ Redis [Installed]\n"; fi
    if $COMP_MARIADB; then printf "  ✓ MariaDB [Installed]\n"; fi
  fi
}

# =====================================================================
# Modules
# =====================================================================

mod_create_user() {
  head_ "Create New User"
  printf '%bUsername (Example: abhishek):%b ' "$C_CYAN" "$C_RESET"
  local username; read -r username
  if [[ -z "$username" ]]; then err "Username cannot be empty."; return; fi
  if id "$username" &>/dev/null; then err "User $username already exists."; return; fi
  
  printf '%bFull Name (Example: Abhishek Chougule):%b ' "$C_CYAN" "$C_RESET"
  local fullname; read -r fullname

  # Primary Group
  printf '\n%bAvailable Primary Groups:%b\n' "$C_GREEN" "$C_RESET"
  local groups=("developer" "devops" "users" "custom")
  for i in "${!groups[@]}"; do
    printf '  %b%d.%b %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "${groups[$i]}"
  done
  printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
  local pg_sel; read -r pg_sel
  local primary_group="developer"
  if [[ "$pg_sel" == "4" ]]; then
    printf '%bEnter Custom Primary Group:%b ' "$C_CYAN" "$C_RESET"
    read -r primary_group
  elif [[ -n "$pg_sel" ]] && [[ "$pg_sel" -ge 1 ]] && [[ "$pg_sel" -le 3 ]]; then
    primary_group="${groups[$((pg_sel-1))]}"
  fi

  if ! getent group "$primary_group" >/dev/null; then
    run groupadd "$primary_group"
  fi

  # Additional Groups
  printf '\n%bAvailable Additional Groups:%b\n' "$C_GREEN" "$C_RESET"
  local avail_groups=("devops" "developer" "sudo" "docker" "www-data" "adm" "custom")
  for i in "${!avail_groups[@]}"; do
    printf '  [%b%d%b] %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "${avail_groups[$i]}"
  done
  printf '%bChoose comma separated (Example: 1,3,4):%b ' "$C_CYAN" "$C_RESET"
  local ag_sel; read -r ag_sel
  local additional_groups=""
  if [[ -n "$ag_sel" ]]; then
    IFS=',' read -ra ag_arr <<< "$ag_sel"
    for idx in "${ag_arr[@]}"; do
      idx=$(echo "$idx" | xargs)
      if [[ "$idx" == "7" ]]; then
        printf '%bEnter Custom Additional Group:%b ' "$C_CYAN" "$C_RESET"
        local custom_ag; read -r custom_ag
        if [[ -n "$custom_ag" ]]; then
          additional_groups+="${custom_ag},"
          if ! getent group "$custom_ag" >/dev/null; then run groupadd "$custom_ag"; fi
        fi
      elif [[ "$idx" -ge 1 ]] && [[ "$idx" -le 6 ]]; then
        local g="${avail_groups[$((idx-1))]}"
        additional_groups+="${g},"
        if ! getent group "$g" >/dev/null; then run groupadd "$g"; fi
      fi
    done
    additional_groups="${additional_groups%,}"
  fi

  # Password
  printf '\n%bCreate Password:%b\n' "$C_GREEN" "$C_RESET"
  printf '  %b1%b  Generate random password\n' "$C_GREEN" "$C_RESET"
  printf '  %b2%b  Enter manually\n' "$C_GREEN" "$C_RESET"
  printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
  local pwd_sel; read -r pwd_sel
  local password=""
  if [[ "$pwd_sel" == "2" ]]; then
    read -s -p "$(printf '%bPassword:%b ' "$C_CYAN" "$C_RESET")" password; echo ""
    read -s -p "$(printf '%bConfirm Password:%b ' "$C_CYAN" "$C_RESET")" pwd_conf; echo ""
    if [[ "$password" != "$pwd_conf" ]]; then err "Passwords do not match."; return; fi
  else
    password=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    info "Generated Password: $password"
  fi

  # Execution
  local ucmd="useradd -m -c \"$fullname\" -g \"$primary_group\" -s /bin/bash"
  if [[ -n "$additional_groups" ]]; then
    ucmd+=" -G \"$additional_groups\""
  fi
  ucmd+=" \"$username\""
  
  if [ "$DRY_RUN" = true ]; then
    dry "$ucmd"
    dry "echo '$username:$password' | chpasswd"
  else
    eval "$ucmd"
    echo "$username:$password" | chpasswd
    ok "User $username created successfully."
  fi
  
  record_action "User Created" "$username"
  if [[ -n "$additional_groups" ]]; then record_action "Groups Assigned" "$primary_group, $additional_groups"; else record_action "Groups Assigned" "$primary_group"; fi

  mod_install_ssh_key "$username"
}

mod_create_group() {
  head_ "Create New Group"
  printf '%bGroup Name:%b ' "$C_CYAN" "$C_RESET"
  local grp; read -r grp
  if [[ -z "$grp" ]]; then err "Group name cannot be empty."; return; fi
  if getent group "$grp" >/dev/null; then err "Group $grp already exists."; return; fi
  run groupadd "$grp"
  ok "Group $grp created."
  record_action "Group Created" "$grp"
}

mod_devops_policy() {
  head_ "Configure DevOps Policy"
  if [[ -z "$BENCH_USER" ]]; then
    printf '%bEnter Target Bench User (e.g., frappe, tbuat):%b ' "$C_CYAN" "$C_RESET"
    read -r BENCH_USER
  fi
  if [[ -z "$BENCH_USER" ]]; then err "No bench user selected."; return; fi
  
  printf '\nConfigure DevOps Policy for user %b%s%b?\n' "$C_BOLD" "$BENCH_USER" "$C_RESET"
  printf '  %b1%b  Yes\n' "$C_GREEN" "$C_RESET"
  printf '  %b2%b  No\n' "$C_GREEN" "$C_RESET"
  printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
  local ans; read -r ans
  if [[ "$ans" == "2" ]]; then return; fi

  local file="/etc/sudoers.d/devops"
  local conf="%devops ALL=(${BENCH_USER}) NOPASSWD: ALL"
  
  if [ "$DRY_RUN" = true ]; then
    dry "echo '$conf' > $file"
    dry "chmod 440 $file"
  else
    echo "$conf" > "$file"
    chmod 440 "$file"
    if visudo -c -f "$file" >/dev/null 2>&1; then
      ok "DevOps Policy configured."
      record_action "DevOps Policy" "Installed"
    else
      err "visudo check failed for DevOps policy. Rolling back."
      rm -f "$file"
    fi
  fi
}

mod_developer_policy() {
  head_ "Configure Developer Policy"
  if [[ -z "$BENCH_USER" ]]; then
    printf '%bEnter Target Bench User (e.g., frappe, tbuat):%b ' "$C_CYAN" "$C_RESET"
    read -r BENCH_USER
  fi
  if [[ -z "$BENCH_USER" ]]; then err "No bench user selected."; return; fi

  printf '\nConfigure Developer Policy for user %b%s%b?\n' "$C_BOLD" "$BENCH_USER" "$C_RESET"
  printf '  %b1%b  Yes\n' "$C_GREEN" "$C_RESET"
  printf '  %b2%b  No\n' "$C_GREEN" "$C_RESET"
  printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
  local ans; read -r ans
  if [[ "$ans" == "2" ]]; then return; fi

  if $FRAPPE_FOUND; then
    printf '\n%bDeveloper Permissions%b\n' "$C_GREEN" "$C_RESET"
    printf "  ✓ Become Bench User (%s)\n" "$BENCH_USER"
    if $COMP_BENCH; then printf "  ✓ bench build\n  ✓ bench migrate\n  ✓ bench restart\n"; fi
    if $COMP_SUPERVISOR; then printf "  ✓ supervisorctl\n"; fi
    if $COMP_NGINX; then printf "  ✓ nginx reload\n"; fi
  fi

  local file="/etc/sudoers.d/developer"
  local cmds="/bin/su - ${BENCH_USER}"
  if $COMP_SUPERVISOR; then cmds+=", /usr/bin/supervisorctl restart *, /usr/bin/supervisorctl status"; fi
  if $COMP_NGINX; then cmds+=", /usr/sbin/nginx -s reload, /usr/sbin/nginx -t"; fi
  if $COMP_BENCH; then cmds+=", /usr/local/bin/bench *"; fi

  local conf="%developer ALL=(root) NOPASSWD: ${cmds}"

  if [ "$DRY_RUN" = true ]; then
    dry "echo '$conf' > $file"
    dry "chmod 440 $file"
  else
    echo "$conf" > "$file"
    chmod 440 "$file"
    if visudo -c -f "$file" >/dev/null 2>&1; then
      ok "Developer Policy configured."
      record_action "Developer Policy" "Installed"
    else
      err "visudo check failed for Developer policy. Rolling back."
      rm -f "$file"
    fi
  fi
}

mod_install_ssh_key() {
  local target_user="${1:-}"
  if [[ -z "$target_user" ]]; then
    head_ "Install SSH Public Key"
    printf '%bUsername to install key for:%b ' "$C_CYAN" "$C_RESET"
    read -r target_user
  else
    printf '\n%bInstall SSH Public Key?%b\n' "$C_GREEN" "$C_RESET"
    printf '  %b1%b  Yes\n' "$C_GREEN" "$C_RESET"
    printf '  %b2%b  No\n' "$C_GREEN" "$C_RESET"
    printf '%bChoose [1]:%b ' "$C_CYAN" "$C_RESET"
    local p; read -r p
    if [[ "$p" == "2" ]]; then return; fi
  fi
  
  if ! id "$target_user" &>/dev/null; then err "User $target_user does not exist."; return; fi
  
  printf '%bPaste SSH Public Key:%b\n' "$C_CYAN" "$C_RESET"
  local pubkey; read -r pubkey
  
  if [[ ! "$pubkey" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ]]; then
    err "Invalid SSH key format. Must be ssh-ed25519, ssh-rsa, or ecdsa."
    return
  fi
  
  local uhome
  uhome=$(eval echo "~$target_user")
  
  if [ "$DRY_RUN" = true ]; then
    dry "mkdir -p $uhome/.ssh"
    dry "echo '$pubkey' >> $uhome/.ssh/authorized_keys"
    dry "chown -R $target_user:$target_user $uhome/.ssh"
    dry "chmod 700 $uhome/.ssh && chmod 600 $uhome/.ssh/authorized_keys"
  else
    mkdir -p "$uhome/.ssh"
    echo "$pubkey" >> "$uhome/.ssh/authorized_keys"
    chown -R "$target_user:$target_user" "$uhome/.ssh"
    chmod 700 "$uhome/.ssh"
    chmod 600 "$uhome/.ssh/authorized_keys"
    ok "SSH Key installed for $target_user."
  fi
  record_action "SSH Key" "Installed"
}

mod_user_info() {
  head_ "User Information"
  printf '%bUsername:%b ' "$C_CYAN" "$C_RESET"
  local u; read -r u
  if ! id "$u" &>/dev/null; then err "User $u does not exist."; return; fi
  id "$u"
  chage -l "$u" | head -n 3
}

mod_lock_user() {
  head_ "Lock User"
  printf '%bUsername:%b ' "$C_CYAN" "$C_RESET"
  local u; read -r u
  if ! id "$u" &>/dev/null; then err "User $u does not exist."; return; fi
  run passwd -l "$u"
  ok "User $u locked."
}

mod_unlock_user() {
  head_ "Unlock User"
  printf '%bUsername:%b ' "$C_CYAN" "$C_RESET"
  local u; read -r u
  if ! id "$u" &>/dev/null; then err "User $u does not exist."; return; fi
  run passwd -u "$u"
  ok "User $u unlocked."
}

mod_delete_user() {
  head_ "Delete User"
  printf '%bUsername:%b ' "$C_CYAN" "$C_RESET"
  local u; read -r u
  if ! id "$u" &>/dev/null; then err "User $u does not exist."; return; fi
  printf '%bDelete home directory as well? [y/N]:%b ' "$C_CYAN" "$C_RESET"
  local d; read -r d
  if [[ "$d" =~ ^[Yy] ]]; then
    run userdel -r "$u"
    ok "User $u and home directory deleted."
  else
    run userdel "$u"
    ok "User $u deleted."
  fi
}

# =====================================================================
# Main Loop & Verification
# =====================================================================
generate_reports() {
  if [ "$DRY_RUN" = true ]; then
    dry "JSON Report -> $LOGFILE_JSON"
    dry "MD Report -> $LOGFILE_MD"
    dry "Log file -> $LOGFILE"
    return
  fi

  # JSON
  echo "{" > "$LOGFILE_JSON"
  echo "  \"timestamp\": \"$TIMESTAMP\"," >> "$LOGFILE_JSON"
  echo "  \"mode\": \"$(if $DRY_RUN; then echo 'Dry-Run'; else echo 'Apply'; fi)\"," >> "$LOGFILE_JSON"
  echo "  \"actions\": {" >> "$LOGFILE_JSON"
  local keys=("${!REPORT_DATA[@]}")
  for i in "${!keys[@]}"; do
    local k="${keys[$i]}"
    local v="${REPORT_DATA[$k]}"
    if [[ $i -eq $((${#keys[@]}-1)) ]]; then
      echo "    \"$k\": \"$v\"" >> "$LOGFILE_JSON"
    else
      echo "    \"$k\": \"$v\"," >> "$LOGFILE_JSON"
    fi
  done
  echo "  }" >> "$LOGFILE_JSON"
  echo "}" >> "$LOGFILE_JSON"

  # MD
  {
    echo "# Server User Management Report"
    echo "- **Date**: $TIMESTAMP"
    echo "- **Mode**: $(if $DRY_RUN; then echo 'Dry-Run'; else echo 'Apply'; fi)"
    echo ""
    echo "## Actions Performed"
    for k in "${keys[@]}"; do
      echo "- **$k**: ${REPORT_DATA[$k]}"
    done
  } > "$LOGFILE_MD"

  info "Reports generated at:"
  info "  JSON: $LOGFILE_JSON"
  info "  MD:   $LOGFILE_MD"
  info "  LOG:  $LOGFILE"
}

show_verification() {
  head_ "Verification"
  for k in "${!REPORT_DATA[@]}"; do
    printf "  %b%-20s%b ✓ %s\n" "$C_GREEN" "$k" "$C_RESET" "${REPORT_DATA[$k]}"
  done
  if [[ -n "${REPORT_DATA['User Created']:-}" ]]; then
    printf '\n%bLogin Test%b\n' "$C_BOLD" "$C_RESET"
    printf "  ssh %s@SERVER\n" "${REPORT_DATA['User Created']}"
  fi
  generate_reports
}

main_menu() {
  while true; do
    printf '\n%bMain Menu%b\n' "$C_BOLD" "$C_RESET"
    printf '  %b1.%b Create New User\n' "$C_GREEN" "$C_RESET"
    printf '  %b2.%b Create New Group\n' "$C_GREEN" "$C_RESET"
    printf '  %b3.%b Configure DevOps Policy\n' "$C_GREEN" "$C_RESET"
    printf '  %b4.%b Configure Developer Policy\n' "$C_GREEN" "$C_RESET"
    printf '  %b5.%b Install SSH Public Key\n' "$C_GREEN" "$C_RESET"
    printf '  %b6.%b User Information\n' "$C_GREEN" "$C_RESET"
    printf '  %b7.%b Lock User\n' "$C_GREEN" "$C_RESET"
    printf '  %b8.%b Unlock User\n' "$C_GREEN" "$C_RESET"
    printf '  %b9.%b Delete User\n' "$C_GREEN" "$C_RESET"
    printf ' %b10.%b Exit\n' "$C_GREEN" "$C_RESET"
    printf '\n%bChoose [10]:%b ' "$C_CYAN" "$C_RESET"
    local opt; read -r opt
    [[ -z "$opt" ]] && opt=10

    case "$opt" in
      1) mod_create_user ;;
      2) mod_create_group ;;
      3) mod_devops_policy ;;
      4) mod_developer_policy ;;
      5) mod_install_ssh_key "" ;;
      6) mod_user_info ;;
      7) mod_lock_user ;;
      8) mod_unlock_user ;;
      9) mod_delete_user ;;
      10) show_verification; exit 0 ;;
      *) warn "Invalid option." ;;
    esac
  done
}

# =====================================================================
# Entry Point
# =====================================================================
show_banner
prompt_mode
detect_benches
if [[ -n "$BENCH_USER" ]]; then record_action "Bench User" "$BENCH_USER"; fi
main_menu
