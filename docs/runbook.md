# Runbook

## Check The systemd Timer

```bash
sudo systemctl status ai-council-healthcheck.timer
sudo systemctl list-timers ai-council-healthcheck.timer
```

Expected result: the timer is loaded, active, and has a next run time.

## Check journalctl

```bash
sudo journalctl -u ai-council-healthcheck.service -n 100 --no-pager
sudo journalctl -u ai-council-healthcheck.timer -n 100 --no-pager
```

Look for the latest start time, exit status, and script error messages.

## Check Log Files

```bash
sudo ls -la /var/log/ai-council
sudo cat /var/log/ai-council/latest-report.md
```

Expected result: `latest-report.md` exists and contains either `STATUS: OK` or `STATUS: ERROR`.

## Run Manually

```bash
sudo /opt/ai-council/scripts/healthcheck.sh
sudo /opt/ai-council/scripts/report_status.sh
sudo systemctl start ai-council-healthcheck.service
```

After manual execution, check the report timestamp:

```bash
sudo grep -E "Generated At|Last Successful Run|STATUS:" /var/log/ai-council/latest-report.md
```

## GitHub Report Template

```md
## VPS healthcheck report

## Result
- STATUS:
- Checked at:

## Evidence
- latest-report.md:
- journalctl:
- timer status:

## Recovery action
- Action taken:
- Result:

## Unconfirmed
- VPS environment details:
- GitHub posting:
- secrets configuration:
```

