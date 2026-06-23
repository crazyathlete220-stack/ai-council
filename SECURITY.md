# Security Policy

## Threat model: this project executes remote-triggered work

ai-council lets a GitHub Issue (or PR) become a job that runs a CLI on a VPS.
**Treat this as remote code execution by design.** Anyone who can open a
triggering Issue in a repository wired to a live VPS deployment can cause that
VPS to run work. Operators are responsible for the security of their own
deployment.

## Operator hardening checklist

Before running any live deployment:

- **Keep your deployment repository private**, or at minimum restrict who can
  open triggering Issues.
- **Use the trigger allowlist.** The GitHub bridge only acts on Issues from
  authorized users. The allowlist lives outside this repository so each
  operator controls it.
- **Never put secrets in the repository or in Issues.** GitHub tokens, SSH
  private keys, API keys, and passwords are configured on the VPS only. Job
  output is redacted for common token patterns before being posted back.
- **Keep the built-in guardrails on.** `ai_exec` does not run `git push`,
  create PRs, install dependencies, or create secrets. Input size, run time,
  concurrency, and rate limits are enforced and should not be loosened without
  cause.
- **Set cost stops.** The rate/time/size limits are indirect cost controls;
  pair them with a hard budget cap on any paid API or account you connect.
- **Harden the VPS** (least-privilege user, restricted shell, no broad
  filesystem or network access for the runner user).

## Reporting a vulnerability

Please report security issues privately via this repository's **GitHub Security
Advisories** ("Report a vulnerability"), not as a public Issue. Do not include
secrets or live host details in the report.
