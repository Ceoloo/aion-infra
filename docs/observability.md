# Observability

Minimal but sufficient (aion-infra §27). Provider-native first: Cloud Run and
Cloud SQL already emit logs and metrics; the runtime emits structured logs; the
`observability` module adds bounded retention and a few basic alerts. No
dashboards platform, no SIEM, no pager fabric.

## Structured logs (§28)

The reference runtime writes **one JSON object per line** to stdout/stderr, which
Cloud Logging ingests natively. Every line carries the observability spine AION
standardizes (aion-docs/engineering/observability-standards.md):

```json
{"timestamp":"…Z","level":"info","service":"aion-runtime","environment":"staging",
 "git_sha":"abc1234","service_version":"0.1.0","message":"http_request",
 "operation":"GET /health/ready","status":"200","latency_ms":2}
```

- Correlation fields (`run_id`, `mission_id`, `correlation_id`) are included when
  present (e.g. the boot smoke logs its `run_id`).
- **No secrets, no payloads** — failures log a non-secret reason
  (`database_unreachable`), never the connection string (§28, §40). Verified: the
  DB-down run logs `readiness_failed`/`db_pool_error` with zero credential
  leakage (see [phase-3.md](phase-3.md)).
- Deeper trace/telemetry (the full spine, per-run) is persisted by AION Data in
  `telemetry_records`; these operational logs are the infra-level complement.

## Health & readiness (§29)

| Endpoint | Meaning | Used by |
|---|---|---|
| `GET /health/live` | process is up; **no dependency work** | Cloud Run liveness probe (restarts a wedged process) |
| `GET /health/ready` | can serve — checks DB connectivity | Cloud Run startup probe (withholds traffic until ready) |

Readiness fails (503) when the database is unreachable and recovers when it
returns, without redeploying (§62). Health checks never trigger business
execution.

## Release metadata (§22)

`GET /` and every log line expose `git_sha`, `service_version`, `build_time`,
`environment`, so a production incident is traceable to the exact source commit.

## Alerts (§30 — basic only)

The `observability` module wires (when an ops email is configured):

| Alert | Condition |
|---|---|
| Runtime unavailable | no Cloud Run instances/successful requests for 5 min |
| Database unavailable | Cloud SQL `up` metric < 1 for 3 min |
| Backup failed | Cloud SQL backup-failure log entry |

Log retention is bounded per environment (staging 30 days, production 60) via the
`_Default` log bucket (§40) — verbose logs are not kept forever, and no sensitive
business payloads are stored in logs.

## Alerts (VPS provider — host-level, not Cloud Run)

The GCP `observability` module above has no equivalent on the VPS provider
(no managed alerting product exists there). Instead: `providers/vps/scripts/
monitor-runtime.sh` on a 60s systemd timer, running on the HOST — not inside
any container, so it has no dependency on `aion-runtime` being reachable.
Checks: container missing/restarting/unhealthy, external `/health/ready`
non-200, and the monitor's own ability to reach the Docker daemon (a
distinct failure mode, never conflated with "target is fine"). Debounced
(N consecutive bad polls before alerting, configurable), deduplicated
(re-notifies at a configurable cadence while an incident stays open rather
than once per poll), recreate-aware (a container recreate resets the
restart-count baseline instead of counting a fresh healthy instance as
still-failing), and sends a recovery notice on return to health. Built
2026-09-20 in direct response to a 6-day undetected crash-loop (aion-infra#12)
— see [docs/audit-2026-09-20-vps-execution-readiness.md](audit-2026-09-20-vps-execution-readiness.md)
and [runbook.md](runbook.md) "Runtime failure detection".

Alert delivery started as log-only by design (no destination should be
assumed authorized) and, as of 2026-09-20, is wired to the existing
ntfy.sh channel the backup system (below) already uses — reused rather
than standing up a new one, with the user's explicit sign-off. Delivery
remains opt-in and swappable (`ALERT_WEBHOOK_URL`/`ALERT_FORMAT` in
`/opt/aion/.env.monitor`); log-only was, and remains, a valid operating
state on its own, not a disabled feature pretending to be enabled.

## What is deliberately not built

No custom metrics pipeline, tracing backend, dashboards platform, or alert
sprawl. If the operating model later justifies a tracing/metrics backend, it is
chosen via ADR (aion-docs/engineering/observability-standards.md — the emission
*shape* is fixed; the backend is deferred).
