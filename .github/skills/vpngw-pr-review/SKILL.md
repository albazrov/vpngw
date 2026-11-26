---
name: vpngw-pr-review
description: Review and fix VPN gateway pull requests against current runtime, locking, logging, deployment, and PR-flow invariants.
---

# vpngw PR review skill

Use this skill when reviewing a change to the VPN gateway, Telegram bot, recovery scripts, deployment, or branch promotion.

## Required invariants

- `vpngw-bot.service` is the only Telegram polling runtime.
- Manual bot switching and automatic starter recovery share the VPN switch lock.
- A lock-busy result is distinct from permission, missing-state, timeout, and runtime errors.
- VPN success requires CLI success, connectivity, and the requested GeoIP location.
- `/dev/shm/vpn_stats` is a real `root:root 0700` directory; do not restore world-writable mode.
- RAM-log writers and `vpn-log-sync.sh` share `vpn-log.lock`; hourly reports do not truncate the RAM log.
- `adguardvpn-cli status` update notices are emitted only as a separate hourly Telegram message.
- CLI/output parsers tolerate ANSI and ignore explicit no-update/up-to-date messages.
- Secrets must never appear in argv, logs, reports, tests, or generated documentation.
- Promotion remains `feature/fix -> dev -> test -> main`; do not push directly to protected branches.

## Review procedure

1. Read the full PR diff and all review comments.
2. Reproduce relevant tests locally with fake CLI/network data.
3. Verify major control flow, timeout, lock release, and rollback/error paths.
4. Update focused tests and directly related documentation.
5. Commit and push through a feature/fix branch; do not bypass branch protection.
6. Wait for all required checks and resolve every blocking comment.

## Required validation

- `bash -n` and ShellCheck for changed shell scripts.
- Shell regression tests, including `tests/test_vpn_runtime_locks.sh` and `tests/test_adguard_update_notice.sh`.
- Python bot tests and compile checks for Python changes.
- PR checks must be green before merge.
