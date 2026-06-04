# VPS Claude Code Decision

## Purpose

This note keeps Claude Code as an explicit decision, not an automatic install.

The VPS AI workbench already has a confirmed Codex CLI lane. Claude Code can become a second AI CLI lane later, but it should not be installed or authenticated until the operator accepts the account, cost, and VPS sizing tradeoffs.

This is not an AI model migration. Claude Code runs a local CLI and uses Anthropic's external AI service.

## Current Decision

Do not install Claude Code automatically in this repository.

Reasons:

- The current VPS plan is 2GB memory, while the official Claude Code setup guide lists 4GB+ RAM as a system requirement.
- Claude Code authentication requires an eligible Anthropic or Claude account and may create local credential state on the VPS.
- Adding Claude Code increases the number of authenticated AI accounts on an internet-facing server.
- Codex CLI is already confirmed with `AI_CLI_STATUS: READY`, so Claude Code is optional rather than blocking.

## Official References Checked

- Setup: `https://code.claude.com/docs/en/setup`
- CLI reference: `https://code.claude.com/docs/en/cli-usage`
- Pricing: `https://docs.anthropic.com/en/docs/about-claude/pricing`

Relevant facts from those docs:

- Claude Code supports Ubuntu 20.04+.
- The setup guide lists 4GB+ RAM.
- Network access is required for AI processing.
- Claude Code requires a Pro, Max, Team, Enterprise, or Console account.
- `claude auth status` is the official auth status command.
- `claude -p` supports non-interactive use, including `--max-turns` and `--max-budget-usd`.

## Readiness Check

Run on the VPS:

```bash
bash /opt/ai-council/scripts/claude_code_readiness.sh
```

Expected current result on a 2GB VPS with Claude Code not installed:

```text
CLAUDE_CODE_READINESS_STATUS: NOT_READY
```

This is acceptable. It means Claude Code is intentionally not part of the active VPS lane yet.

## Manual Install Gate

Only proceed when all are true:

- Tanabe-san accepts Claude account or Anthropic Console usage.
- The VPS memory limit is accepted or upgraded to meet the official 4GB+ guidance.
- The bridge allowlist and `ai_exec` guardrails remain active.
- No API key, token, password, or secret is pasted into GitHub Issues or repository files.
- Claude Code is tested manually before any Issue bridge route uses it.

## Manual Setup Outline

Run as the operator user or with that user's home directory, not by committing credentials into this repository.

Native install option from the official setup guide:

```bash
sudo -H -u ai-council bash -lc 'curl -fsSL https://claude.ai/install.sh | bash'
```

Verify:

```bash
sudo -H -u ai-council bash -lc 'claude --version'
sudo -H -u ai-council bash -lc 'claude auth status'
bash /opt/ai-council/scripts/claude_code_readiness.sh
```

If using Anthropic Console billing, use the official `claude auth login --console` flow manually. Do not store API keys in this repository.

## Future Runner Design

If Claude Code becomes active, add it as a separate, reviewed job type such as `claude_exec`.

That future job should:

- run as `ai-council`
- use non-interactive `claude -p`
- set `--max-turns`
- set `--max-budget-usd` when using API billing
- keep `git push`, PR creation, dependency installation, and secrets creation disabled
- write evidence under `/var/log/ai-council/claude-code`
- remain separate from the already confirmed Codex `ai_exec` lane
