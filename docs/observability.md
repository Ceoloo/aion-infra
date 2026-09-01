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

## What is deliberately not built

No custom metrics pipeline, tracing backend, dashboards platform, or alert
sprawl. If the operating model later justifies a tracing/metrics backend, it is
chosen via ADR (aion-docs/engineering/observability-standards.md — the emission
*shape* is fixed; the backend is deferred).
