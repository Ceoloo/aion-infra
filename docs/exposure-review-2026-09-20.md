# Exposure review — customer identifiers and credentials in public repositories (2026-09-20)

Sanitized: no secret value and no customer name is reproduced here. **No repository history was rewritten and no
repository visibility was changed.**

## The "top note", in sanitized form
While documenting the stale-approval review, an earlier commit of mine (`7cb7c82`, on the PR #13 branch of this
**public** repo) copied a real client's business name, a lead's first and last name, and a CRM opportunity id into a
doc. The branch head was redacted in `85370f5`; the commit remains in history. That prompted a full scan, which found
the same class of identifier was already present in **four other public repositories** (below).

## What was scanned
11 repositories under the owner account (10 public, 1 private), every branch, tag and pull-request ref
(`git clone --mirror`, 449 refs / 623 commits in total), all added **and removed** lines, plus the text of every PR
title/body, issue, and PR/issue comment (GitHub API).
- **Live secrets:** an *exact-value* search for 14 secret values currently in use on the VPS — GHL private-integration
  token, both gateway bearer tokens, DB passwords (app, migrator, superuser, URL-embedded), OpenRouter key, Backblaze
  key id + application key, ntfy topic, GPG passphrase.
- **Generic credential shapes:** GHL PIT, Supabase secret keys and JWTs, OpenRouter/OpenAI keys, AWS/GitHub/Slack
  tokens, private-key blocks, Backblaze keys, bearer literals, DB URLs with passwords; and committed `.env`, key, or
  `.tfvars` files.
- **Identifiers:** client business name, lead first/last name, lead email, GHL location id, CRM contact/opportunity/
  pipeline/stage ids (values taken from production, matched exactly).

## Result 1 — no active credential was exposed
**0 of 14** live secret values appear anywhere in any repo, history, or PR/issue text. Consequently **this exposure
does not require rotating or revoking anything**, and none was done. (For the record, making a repo private or
rewriting history would not invalidate a credential; had one been found, rotation would have come first.)

One credential-*shaped* hit: `AION-Wealth-OS` commit `4407289` (2026-09-12) added `.env.production`, still present at
`main`. Its only secret-looking value is a Supabase JWT whose decoded claims are `role=anon`, in a `NEXT_PUBLIC_`
variable, for project `aion-wealth-os` — a *publishable* key that ships to browsers by design. It is safe only if
that project enforces Row Level Security: the project's security advisors (read-only) report **no RLS-disabled
tables**, only two WARNs — the `SECURITY DEFINER` function `public.delete_my_data()` is callable by signed-in users
(likely intentional self-service, confirm), and Auth leaked-password protection is off. Advisors do not prove the
policies themselves are correct.

## Result 2 — customer/CRM identifiers are exposed in five public repos
Not credentials: they cannot read or write CRM data without a token. The harm is identifying a client and a lead
publicly, and giving an attacker record ids to aim at should a token ever leak.

| Repo | What | Where | In `main` HEAD? | Commits |
|---|---|---|---|---|
| aion-runtime | client name, lead first + last name, location id, contact/opportunity/pipeline/stage ids | `src/ghl-live-capability-proof.ts`, `src/ghl-live-acceptance.ts`, `src/adapters/ghl/fake-ghl-backend.ts`; PR titles/bodies/review comments | **Yes** | 3–9 per class |
| aion-docs | client name, lead name, location id, contact/opportunity ids | `roadmap/ghl-readonly-governed-write.md`, `roadmap/pre-ol-validation.md`, `roadmap/production-golive.md`; PR text | **Yes** | 3–8 per class |
| aion-products | client name, lead name, contact/opportunity/pipeline/stage ids | `workforce-control/src/pages/NewMission.tsx`; PR text | **Yes** | 1–2 |
| aion-core | contact/opportunity ids; client name in PR text | `tests/orchestration/opportunity-entity-routing.test.ts`; PR titles/bodies | **Yes** (test file) | 3 |
| aion-infra | client name, lead first + last name, opportunity id | `docs/audit-2026-09-20-followup-slices.md` (my commit `7cb7c82`) | No — history only | 2 |

The lead's **email address appears in no repository**. aion-runtime PR #46 (draft) removes the ids from the two live-proof
sources at its head (`src/adapters/ghl/fake-ghl-backend.ts` still holds an opportunity id), but `main` and history still
contain them until it merges and history is dealt with.
Also out of scope of a repo scan: container images built from these sources carry the same literals if the image is
public.

## Not covered by this review
GitHub Actions logs, forks/clones and search-engine caches, objects unreachable from any ref, secrets that were
rotated *before* today (only currently-live values were matched), and non-GitHub copies.

## What removing this actually takes (decisions for you; nothing done)
1. **Stop the bleeding at `main`** — small PRs replacing literals with fixtures/placeholders: aion-runtime (PR #46),
   aion-docs (3 roadmap files), aion-products (`NewMission.tsx`), aion-core (1 test), aion-infra (already redacted).
2. **History rewrite** (`git filter-repo`, force-push) only removes commits you can rewrite. **PR refs
   (`refs/pull/*`) and cached views cannot be rewritten by the owner** — purging those needs GitHub Support. A rewrite
   also invalidates every clone and open PR, so it is a real cost for modest gain given these are identifiers.
3. **Make the repos private** stops new public reads; it cannot recall copies already taken. Worth weighing against
   any need for them to be public (e.g. ghcr image visibility, Vercel).
4. A **contractual/privacy check** with the affected client on whether the name/lead exposure needs disclosure.
Recommended order: 1 (now), 4 (your judgment), then 3 or 2 only if 4 says the exposure is material.

## If a live credential is ever found (contingency, prepared not executed)
| Credential | Revoke/rotate | Then update |
|---|---|---|
| GHL PIT | regenerate in GHL (Private Integrations) | `GHL_API_KEY` in `/opt/aion/.env`; recreate runtime |
| Gateway tokens | mint new tokens in `AION_GATEWAY_API_KEYS` | Copilot `AION_RUNTIME_API_KEY`, Operator Console config; recreate runtime + copilot |
| DB passwords | `ALTER ROLE … PASSWORD` | `.env` (`AION_APP_PASSWORD`, `AION_MIGRATOR_PASSWORD`, URLs); recreate runtime |
| OpenRouter key | revoke in OpenRouter | Copilot env |
| B2 key | delete in Backblaze, mint new | `/root/.backup-secrets/b2.env`, rclone config |
| ntfy topic | pick a new topic | `ntfy.env`, `.env.monitor` |
Always run `validate-env.sh` before the recreate (the 2026-09-14 outage was a malformed `AION_GATEWAY_API_KEYS`).
