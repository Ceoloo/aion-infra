# Networking

The simplest secure design that keeps the database off the public internet and
exposes only the intended runtime ingress (aion-infra §35). No elaborate VPC
topology — a managed platform already isolates services; we add only the minimum
private path.

## Shape

```
Internet ──HTTPS(TLS)──▶ Cloud Run runtime ──Direct VPC egress──▶ [ VPC ]
                          (managed front door)   private ranges      │
                                                                     ▼
                                        Cloud SQL (PRIVATE IP) via Private
                                        Services Access peering (no public IP)
```

- **One VPC + one regional subnet** per environment. No default network, no NAT,
  no external IPs on anything.
- **Private Services Access (PSA)**: a reserved range peered to Google's
  service-producer network so Cloud SQL receives a **private** address.
- **Direct VPC egress** from Cloud Run onto the subnet (`egress =
  PRIVATE_RANGES_ONLY`) — the runtime reaches the private DB with no connector
  resource to run or pay for.
- **Deny-all ingress** baseline firewall documents the default-closed posture;
  no rule opens the database to the internet.

## Database exposure

- `ipv4_enabled = false` — **no public IP** on the Cloud SQL instance
  (aion-infra §13). It is reachable only from inside the VPC over the private
  path.
- `ssl_mode = ENCRYPTED_ONLY` — the instance refuses non-TLS connections.
- The runtime connects with `sslmode=require`. Because the path is already
  VPC-private, `require` (encrypted, no cert pinning) is an acceptable Phase 3
  posture; upgrading to `verify-ca` with the server CA is a documented,
  low-effort hardening step.

There is **no** public-Postgres fallback in this design, so the "public
connectivity unavoidable" tradeoff (§13) does not apply. If a future provider
constraint forced it, the mitigations (TLS, strong creds, IP allowlist, least
privilege, rotation) would be enforced and the tradeoff recorded.

## Runtime ingress

- Cloud Run provides the managed HTTPS front door with Google-managed
  certificates (§36) — no certificates to manage by hand.
- Invocation is **deny-by-default**: `allow_unauthenticated = false`. Callers
  need `roles/run.invoker`; smoke tests use an identity token. Making the
  service publicly reachable is an explicit opt-in, not the default.

## Administrative paths

- No SSH, no bastion, no VM — there is nothing to log into (serverless).
- Database administration uses Cloud SQL's authenticated admin path
  (break-glass), not a network-exposed port. See [runbook.md](runbook.md).

## Why not more

No multi-subnet tiering, no service mesh, no private DNS zones, no NAT gateway —
none is required by a single service talking to one database. Adding them would
be speculative infrastructure (aion-docs/engineering/principles.md #1).
