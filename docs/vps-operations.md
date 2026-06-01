# VPS Operations

## Entry

Work starts from GitHub Issues in `crazyathlete220-stack/ai-council`. Phase 0 is driven by Issue #4, and later phases should continue to use GitHub Issues or PRs as the visible task entry.

## Read

Codex reads the Issue, repository files, and existing docs before changing files. Tanabe-san and ChatGPT review the PR before any VPS execution. VPS-side checks are read from `/var/log/ai-council/latest-report.md` and `journalctl` after Phase 1 setup.

## Execute

On the VPS, Tanabe-san manually runs:

```bash
sudo bash scripts/bootstrap_vps.sh
```

After setup, systemd runs `scripts/report_status.sh` once per day through `ai-council-healthcheck.timer`. Manual execution remains available with:

```bash
sudo systemctl start ai-council-healthcheck.service
```

## Evidence

The latest healthcheck result is stored at:

```text
/var/log/ai-council/latest-report.md
```

systemd execution evidence is available through:

```bash
sudo journalctl -u ai-council-healthcheck.service --no-pager
sudo journalctl -u ai-council-healthcheck.timer --no-pager
```

Phase 0 does not post results to GitHub. Reports remain local to the VPS.

## Recovery

When the timer or report stops updating, inspect the timer, the service, the journal, and the latest report in that order. Then run the service manually and compare the new report timestamp with the previous one.

## Visibility

Tanabe-san confirms the current state by checking:

- PR contents and validation results on GitHub
- `systemctl status ai-council-healthcheck.timer`
- `/var/log/ai-council/latest-report.md`
- `journalctl` output for the service

VPS execution remains unconfirmed until Tanabe-san runs the setup manually on the VPS.

