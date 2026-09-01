# ADR-0001: AION Runtime Host Ownership

- **Status:** Accepted — **implemented** (extracted to
  [Ceoloo/aion-runtime](https://github.com/Ceoloo/aion-runtime); the
  `aion-infra/runtime/` fixture is removed and all provider profiles consume the
  aion-runtime image). Ratified into the constitution as **aion-docs ADR-002**
  (PR: Ceoloo/aion-docs#2).
- **Date:** 2026-09-01
- **Decision owner:** Ceoloo (Founder / CEO)
- **Scope:** cross-repo (aion-infra + aion-core + aion-data + aion-docs). This
  copy is the aion-infra record; the ratified constitutional version is
  aion-docs ADR-002.
- **Supersedes:** Phase 3 architecture-debt item 6 ("runtime host ownership
  undecided"), now **resolved and implemented**.

## Context

AION Core is a library/kernel and AION Data is a persistence package; neither is
a long-running service. Phase 3 needed a thin process — a **composition root** —
that wires a real Core `Orchestrator` to AION Data's Postgres adapters, exposes
health, and is packaged as the immutable image the infrastructure deploys.

Phase 3 built that host as `aion-infra/runtime/`, explicitly labelled a
**verification fixture**, because it creates a boundary tension:

- The [dependency rules](https://github.com/Ceoloo/aion-docs/blob/main/repositories/dependency-rules.md)
  forbid `aion-infra` **code** from depending on `aion-core`/`aion-data`
  (infra "runs on" the platform; it does not import it).
- `aion-core` is deliberately **database-agnostic** — it must not import a
  Postgres layer, so the host (which imports `@aion/data`) cannot live in core.
- `aion-data` is orchestration-agnostic — the host wires an orchestrator, so it
  cannot live in data.
- The host is **not a product**; putting the platform runtime in `aion-products`
  would blur the platform/product seam.

The host therefore has no correct home in any existing repository. It needs one
before Phase 4 attaches a real product runtime.

## Decision

**Create a dedicated `aion-runtime` package/repository as the canonical owner of
the AION runtime host (composition root).**

- `aion-runtime` depends on `@aion/core` and `@aion/data` — both **downward**
  dependencies, which the dependency rules permit (the same direction
  `aion-products` is allowed to use).
- It owns: config validation, the Core⇄Data wiring, HTTP health/readiness,
  structured logging, graceful shutdown, the migration entrypoint, and the
  release-metadata surface — i.e. the
  [deployment contract](../../contracts/deployment-contract.md)'s runtime side.
- `aion-infra` consumes it **only as a built image**, never as a code
  dependency. Infra owns provisioning, provider profiles, secret injection,
  networking, and deployment mechanics — nothing that imports Core or Data.
- The current `aion-infra/runtime/` is the **seed/reference** of `aion-runtime`
  and is superseded once the dedicated package exists.

## Alternatives considered

| Option | Verdict | Why |
|---|---|---|
| `aion-core/runtime` subpackage | **Rejected** | Core must stay database-agnostic; the host imports `@aion/data` (Postgres), which core must never do. |
| `aion-products` composition root | **Rejected** | The platform runtime is not a product; this blurs the platform/product boundary. (A *product* may later have its own composition root — that is different.) |
| Keep it in `aion-infra/runtime/` permanently | **Rejected** | Violates the dependency rules — infra code would import core/data. Acceptable only as the current interim fixture. |
| A dedicated `aion-runtime` package/repo | **Accepted** | Depends on core+data downward (allowed); single clear owner; infra consumes only the image; every purity rule holds. |

## Consequences

**Positive**

- Every dependency rule holds: core/data stay pure, infra imports neither, and
  the runtime has one accountable owner.
- The [deployment contract](../../contracts/deployment-contract.md) is unchanged
  — it is already host- and provider-neutral, so `aion-runtime` slots in behind
  the same contract and every provider profile keeps working with no change.
- Portability is unaffected: `aion-runtime` produces the one image all profiles
  deploy.

**Negative / cost**

- A new small repository/package enters the build order (a lightweight addition
  at the Phase 3 → Phase 4 boundary, not a new phase).
- A one-time migration of `aion-infra/runtime/` into `aion-runtime`.

## Migration path

1. Create `Ceoloo/aion-runtime` (or an `aion-runtime` package) from the current
   `aion-infra/runtime/` sources (config, logger, control-plane, server, smoke,
   index, migrate) and `runtime/sql/grants.sql`.
2. It depends on `@aion/core` + `@aion/data` (pinned/tagged once those cut
   releases — see debt items 5, 9) and produces the immutable image.
3. `aion-infra` drops `runtime/` and keeps only the deployment contract + the
   provider profiles, which build/deploy the `aion-runtime` image by tag.
4. No change to Core, Data, product code, the contract, or any provider profile.

Until step 1 lands, `aion-infra/runtime/` remains the **interim fixture** — kept
minimal, provider-neutral, and clearly labelled — exactly as it is today.

## Ratification (aion-docs)

Because this decision shapes a cross-repo boundary, the same content should be
recorded as an ADR in `aion-docs/adr/` and reflected in
`aion-docs/roadmap/build-order.md` (adding `aion-runtime` as a small unit at the
Phase 3→4 boundary) and `aion-docs/repositories/` (a one-line ownership entry).
aion-infra does not modify aion-docs; this file is the ready-to-copy source.
