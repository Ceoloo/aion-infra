# aion-infra — Design Specs

Forward-looking **infrastructure** designs for capabilities that are contracted
in aion-docs but not yet provisioned. Each spec fixes the *required capability*
and the *seam*, and defers the vendor/backend to an ADR at point of need —
consistent with aion-infra's posture that AION is **cloud-portable, not
cloud-abstracted** ([deployment contract](../../contracts/deployment-contract.md)).

Nothing here provisions anything. These become real components only when a
mission requires them, and only via the provider profiles under
[`providers/`](../../providers/).

| Spec | Drives | Priority | Status |
|---|---|---|---|
| [agent-trace-pipeline.md](agent-trace-pipeline.md) | [agent-trace-schema](https://github.com/Ceoloo/aion-docs/blob/main/engineering/agent-trace-schema.md) | P0 | Design |
| [programmatic-execution-sandbox.md](programmatic-execution-sandbox.md) | [core programmatic-execution spec](https://github.com/Ceoloo/aion-core/blob/main/docs/design/programmatic-execution-and-a2a.md) | P1 | Design |

## Ground rules

- **The workload does not import a provider SDK for its ordinary function.** New
  observability/sandbox capability is added as infrastructure around the
  workload, or as an opt-in adapter component — never baked into the base image.
- **Fix the seam, defer the vendor.** OTLP for traces; the
  `PlanExecutionAdapter` boundary for sandboxing. Backends/engines are ADR-chosen.
- **No secrets, no payloads leave the workload.** References and hashes only.
- **Minimal but sufficient.** No speculative platform; provision against real
  mission need.
