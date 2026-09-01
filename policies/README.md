# Policies

Lightweight, high-value guardrails for Phase 3 (aion-infra §52 — do not block on
a huge security-tool stack). These are the checks the pipeline runs and the
accepted limitations, recorded rather than hidden.

## Static IaC / repo checks (in `validate.yml`)

| Check | Tool | Enforcement | Why |
|---|---|---|---|
| Terraform format | `terraform fmt -check -recursive providers` | **blocking** | Reviewable, consistent IaC (§9). |
| Terraform validate | `terraform validate` | **blocking** | Config is internally valid before plan/apply (§60 IAC_VALIDATE). |
| IaC security scan | `tfsec` | advisory (soft-fail) | Surfaces misconfigurations; advisory in Phase 3, findings triaged here. |
| Committed secrets | `gitleaks` | **blocking** | Enforces "no secrets in the repo — ever" (§14, §67, NO_PUBLIC_SECRET). |
| Runtime typecheck/build | `tsc` | **blocking** | The deployability fixture compiles against the real workload. |
| Terraform plan (staging) | `terraform plan` | visibility | PRs show intended change; runs only when cloud auth is configured (§23). |

## Deploy-time guardrails (in `deploy.yml`)

- **Production human gate** — the `production` GitHub Environment requires
  reviewer approval before the deploy job runs (§25, §64). Configure it under
  Settings → Environments → production → Required reviewers.
- **Trusted ref only** — production deploys refuse any ref other than `main`
  (§26), reinforced by the OIDC provider's `attribute.ref` binding in bootstrap.
- **Migration-before-deploy, fail-closed** — a failed migration job stops the
  deploy before the service is rolled (§18, §46, §63).
- **Immutable artifact** — images are tagged by commit SHA; the running commit
  is identifiable via `/health` (§21–22).

## Accepted limitations (Phase 3)

- `tfsec` is advisory, not blocking: a first pass may flag intentional Phase 3
  choices (e.g. public Cloud Run ingress with authenticated invoker). Findings
  are reviewed per-PR; blocking enforcement is a later hardening step.
- No container image vulnerability scanning gate yet (§52). Recommended
  follow-up: enable Artifact Registry vulnerability scanning and gate on
  critical CVEs.
- Live `plan`/`apply` and restore verification require cloud credentials not
  available at build time — see `docs/phase-3.md` → "Live verification".

## Supply chain (aion-infra §51)

- Dependencies are locked (`package-lock.json`, committed Terraform provider
  lock files) and builds use them.
- GitHub Actions are pinned to trusted major versions.
- No `curl | sh` in any pipeline step.
- The deployed git SHA is always identifiable.
