# Server Hardening

![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-00FF9C?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-00FF9C?style=flat-square)
![Standard](https://img.shields.io/badge/ISO%2027001-2022-00FF9C?style=flat-square)
![Safe by default](https://img.shields.io/badge/default-dry--run-00FF9C?style=flat-square)
![Maintained by](https://img.shields.io/badge/maintained%20by-AbhishekChougule-00FF9C?style=flat-square)

An interactive, CIS-aligned hardening script for Debian and Ubuntu servers, built for ISO 27001:2022 preparation. Dry-run by default, with anti-lockout guards on every step that could otherwise cut you off.

```
 ___                        _  _             _          _
/ __| ___ _ ___ _____ _ _  | || |__ _ _ _ __| |___ _ _ (_)_ _  __ _
\__ \/ -_) '_\ V / -_) '_| | __ / _` | '_/ _` / -_) ' \| | ' \/ _` |
|___/\___|_|  \_/\___|_|   |_||_\__,_|_| \__,_\___|_||_|_|_||_\__, |
                                                              |___/
  ISO 27001 hardening baseline for Debian / Ubuntu
  maintained by Abhishek Chougule
```

## Overview

`server-hardening.sh` applies a baseline of well understood Linux hardening controls and pairs each one with the kind of evidence an ISO 27001 auditor expects. It runs interactively, asking what to do before it does anything, or non-interactively for automation. Nothing changes until you explicitly choose Apply.

It is a single, self contained Bash script with no dependencies beyond a standard Debian or Ubuntu base.

## Features

Sixteen modules, each toggleable. The ones marked on by default are safe for most production hosts. Two are off by default because they carry extra risk or overhead.

| #  | Module | What it does | Default | ISO 27001:2022 |
|----|--------|--------------|---------|----------------|
| 1  | Patching | unattended-upgrades for security patches, auto-reboot off | on | A.8.8 |
| 2  | SSH hardening | key-only login, no root password, strong ciphers, idle timeout | on | A.8.2, A.8.5 |
| 3  | Firewall | ufw, default deny inbound, only listed ports plus SSH | on | A.8.20, A.8.22 |
| 4  | fail2ban | bans repeated failed logins | on | A.8.20 |
| 5  | sysctl | kernel and network hardening (spoofing, redirects, ASLR) | on | A.8.9 |
| 6  | auditd | audit logging of identity, sudoers, logins, modules | on | A.8.15, A.8.16 |
| 7  | Time sync | chrony, so log timestamps align | on | A.8.17 |
| 8  | Login policy | password aging, complexity, umask 027 | on | A.5.17, A.8.5 |
| 9  | Disable filesystems | unused filesystems and protocols off, keeps squashfs | on | A.8.9 |
| 10 | Core dumps | disabled | on | A.8.9 |
| 11 | /dev/shm | mount noexec, nosuid, nodev (edits fstab) | off | A.8.9 |
| 12 | AIDE | file integrity monitoring | on | A.8.7 |
| 13 | Remove packages | purge legacy insecure packages (telnet, rsh, tftp) | on | A.8.19 |
| 14 | Session timeout | idle shell logout after 15 minutes | on | A.8.5 |
| 15 | Process accounting | command and activity history (acct, sysstat) | on | A.8.15 |
| 16 | Anti-malware | clamav, heavy, downloads a signature database | off | A.8.7 |

## Safety model

This script touches SSH, the firewall, and PAM, so it is built to never lock you out:

- Dry-run by default. Nothing changes until you choose Apply or pass `--apply`.
- Every config file is backed up to `file.bak.TIMESTAMP` before editing.
- SSH password authentication is only disabled if an `authorized_keys` file already exists. No keys means password login stays on.
- Root login is only fully disabled if a non-root sudo user exists, otherwise it falls back to key-only root.
- Changing the SSH port is a safe migration: sshd listens on the old and new port at once, and the firewall opens both, so you test the new port before dropping the old.
- The firewall always allows SSH, whatever you put in the port list.
- sshd config is validated with `sshd -t` before any restart. A bad config restores the backup and aborts.

## Requirements

- Debian or Ubuntu (uses apt). It refuses to run anywhere else.
- Root (run with sudo).
- Bash 4 or newer, which is standard on supported releases.

## Quick start

```bash
git clone https://github.com/Abhishek-Chougule/server-hardening.git
cd server-hardening
sudo bash server-hardening.sh
```

The first run is a preview by default. Review it, then run again and choose Apply.

## Usage

```bash
sudo bash server-hardening.sh             # interactive, asks everything
sudo bash server-hardening.sh --apply     # interactive, Apply preselected
sudo bash server-hardening.sh --dry-run   # interactive, Preview preselected
sudo bash server-hardening.sh -y          # non-interactive, uses CONFIG defaults
sudo bash server-hardening.sh -y --apply  # non-interactive and applies (automation)
bash server-hardening.sh --help           # full help
```

| Flag | Effect |
|------|--------|
| `--apply` | apply changes (default is a dry-run preview) |
| `--dry-run` | force preview |
| `-y`, `--non-interactive` | skip all prompts, use the CONFIG block |
| `--interactive` | force prompts even without a terminal |
| `-h`, `--help` | show help |

When run from cron or a pipe (no terminal attached), it goes non-interactive automatically.

## Interactive flow

1. Mode: Preview or Apply.
2. Scope: run all modules, or select specific ones from a checkbox list (type numbers to toggle).
3. SSH port: keep the current port, or set a new one.
4. Allowed inbound TCP ports: defaults shown, editable.
5. Summary and confirmation. Answering no cancels with zero changes.

## Configuration

For non-interactive runs, edit the CONFIG block at the top of the script. The interactive prompts use these values as their defaults.

| Variable | Purpose | Default |
|----------|---------|---------|
| `DRY_RUN` | preview vs apply | `true` |
| `SSH_PORT` | listening port, blank keeps current | `""` |
| `ALLOWED_TCP_PORTS` | inbound TCP ports beyond SSH | `80 443 8000 3306 143 25` |
| `ADMIN_EMAIL` | unattended-upgrade report address | `""` |
| `APPLY_UPGRADES_NOW` | run a full upgrade during patching | `false` |
| `ENABLE_*` | per-module on or off | see Features |

## SSH port migration

Set `SSH_PORT`, or enter a port at the prompt, to change the SSH port without risk:

1. sshd is configured to listen on both the old and the new port.
2. The firewall opens both.
3. You confirm the new port works.
4. The script prints the exact commands to finish the switch: remove the old `Port` line, delete the old firewall rule, restart sshd.

## Firewall and ports

The firewall opens SSH plus whatever is in `ALLOWED_TCP_PORTS`. A few of the defaults are deliberately flagged on every run, because open to any source they are common audit findings:

- 3306 (database): if the database runs on this host with the app, you do not need it public. Restrict it to a specific IP if a remote app server needs access.
- 8000 (Frappe backend): in production keep it internal on 127.0.0.1 behind nginx.
- 25 (SMTP) and 143 (IMAP): plaintext. Prefer 587 and 993, and keep 25 only for inbound mail that is not an open relay.

Adjust the list to match what the host actually serves.

## Logs and backups

- Every run logs to `/var/log/server-hardening-TIMESTAMP.log`.
- Every edited file is backed up beside the original as `file.bak.TIMESTAMP`.

## What this does not do

ISO 27001 certifies a management system, not a server. This script handles the technical controls and their evidence, but it does not produce:

- a risk assessment or Statement of Applicability,
- security policies (access control, cryptography, backup, logging),
- internal audit or management review records.

Those sit outside this repository and are still required for certification. Treat this as the server side of the work, not the whole audit.

## Roadmap

- An Ansible role version of the same baseline, so an entire fleet is hardened identically and the configuration itself becomes audit evidence.

## Contributing

Issues and pull requests are welcome. Keep changes idempotent, preserve the dry-run and anti-lockout behavior, and make sure `shellcheck` passes clean before submitting.

## License

[LICENSE](https://github.com/Abhishek-Chougule/server-hardening/blob/main/LICENSE)

## Author

Abhishek Chougule
