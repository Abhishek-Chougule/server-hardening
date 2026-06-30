# Server Hardening

![Platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-00FF9C?style=flat-square)
![Shell](https://img.shields.io/badge/shell-bash-00FF9C?style=flat-square)
![Standard](https://img.shields.io/badge/ISO%2027001-2022-00FF9C?style=flat-square)
![Safe by
default](https://img.shields.io/badge/default-dry--run-00FF9C?style=flat-square)
![Reports](https://img.shields.io/badge/reports-JSON%20%7C%20Markdown-00FF9C?style=flat-square)
![Maintained
by](https://img.shields.io/badge/maintained%20by-AbhishekChougule-00FF9C?style=flat-square)

An interactive, CIS-aligned Linux hardening toolkit for Debian and
Ubuntu servers, built for ISO 27001:2022 preparation.

## Overview

`server-hardening.sh` provides guided hardening profiles,
production-safe defaults, automatic audit report generation, and
anti-lockout safeguards. It is designed for production servers including
Frappe, ERPNext, Node.js, Docker, web, database, and mail servers.

Key characteristics:

-   Dry-run by default
-   Interactive or fully automated execution
-   Production-safe SSH and firewall changes
-   Automatic configuration backups
-   JSON and Markdown compliance reports
-   ISO 27001:2022 aligned
-   CIS-inspired hardening baseline

## Features

### Hardening Profiles

  Profile                  Description
  ------------------------ ------------------------------------
  Production Recommended   Safe production defaults (default)
  All Hardening Modules    Enables every available module
  Custom                   Select modules individually

### Server Role Presets

  Server Type        Default Ports
  ------------------ --------------------
  Frappe / ERPNext   80 443
  Node.js            80 443
  Docker             80 443
  Database           3306
  Mail Server        25 465 587 993 995
  Web Server         80 443
  Custom             User Defined

## Modules

1.  Patching
2.  SSH Hardening
3.  Firewall (UFW)
4.  Fail2Ban
5.  Kernel & Network Hardening
6.  Auditd
7.  Chrony Time Sync
8.  Password Policy
9.  Disable Unused Filesystems
10. Disable Core Dumps
11. Shared Memory Hardening
12. AIDE
13. Remove Legacy Packages
14. Session Timeout
15. Process Accounting
16. ClamAV

## Safety

-   Dry-run by default
-   Automatic backups (`.bak.TIMESTAMP`)
-   SSH anti-lockout protection
-   Safe SSH port migration
-   Firewall always permits SSH
-   `sshd -t` validation before restart
-   Cloud firewall reminder (AWS, Azure, GCP, Hetzner, DigitalOcean)

## Quick Start

``` bash
git clone https://github.com/Abhishek-Chougule/server-hardening.git
cd server-hardening
sudo bash server-hardening.sh
```

## Usage

``` bash
sudo bash server-hardening.sh
sudo bash server-hardening.sh --apply
sudo bash server-hardening.sh --dry-run
sudo bash server-hardening.sh -y
sudo bash server-hardening.sh -y --apply
sudo bash server-hardening.sh --production --apply
sudo bash server-hardening.sh --all --apply
sudo bash server-hardening.sh --custom --apply
sudo bash server-hardening.sh --ports "80 443"
sudo bash server-hardening.sh --auto-reboot
bash server-hardening.sh --help
```

## Command Line Options

  Option                  Description
  ----------------------- --------------------------------
  --apply                 Apply changes
  --dry-run               Preview only
  -y, --non-interactive   Use CONFIG defaults
  --interactive           Force interactive mode
  --production            Production Recommended profile
  --all                   Enable all modules
  --custom                Use default module selections
  --ports                 Override allowed TCP ports
  --auto-reboot           Enable unattended reboot
  -h, --help              Show help

## Interactive Workflow

1.  Choose Preview or Apply
2.  Select Hardening Profile
3.  Select SSH Port
4.  Select Server Type
5.  Review Firewall Ports
6.  Review Summary
7.  Confirm

## Reports

Every successful Apply run generates:

    /var/log/server-hardening-<timestamp>.log
    /var/log/server-hardening-report.json
    /var/log/server-hardening-report.md

These reports include:

-   Timestamp
-   Operating System
-   Execution Mode
-   Hardening Profile
-   Applied Modules
-   Skipped Modules
-   Failed Modules

## Security Summary

After completion the script displays an overall security status
including:

-   SSH Hardening
-   Firewall
-   Fail2Ban
-   Auditd
-   AIDE
-   Chrony
-   Selected Profile

## Requirements

-   Debian or Ubuntu
-   Bash 4+
-   Root privileges
-   apt package manager

## Roadmap

-   Ansible Role
-   CIS Benchmark Score
-   HTML Report
-   OpenSCAP Integration
-   Lynis Integration
-   Compliance Dashboard
-   Rollback Support

## Contributing

Pull requests are welcome. Please keep changes idempotent and preserve
the anti-lockout safeguards.

## License

See LICENSE.

## Author

**Abhishek Chougule**
