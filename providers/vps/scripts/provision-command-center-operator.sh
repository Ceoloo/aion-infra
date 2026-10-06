#!/usr/bin/env bash
set -euo pipefail

# Provision a dedicated AION Command Center operator principal on the VPS.
#
# This script is intentionally host-side:
# - real bearer/access secrets are generated on the VPS;
# - no real token is committed to Git or printed by default;
# - /opt/aion/.env remains the Runtime identity-plane source of truth;
# - the human actor is registered before approval use;
# - Runtime is NOT restarted automatically. A maintainer must explicitly
#   review the diff and recreate the service to activate the new principal.
#
# Usage:
#   sudo ./provision-command-center-operator.sh
#
# Optional overrides:
#   ENV_FILE=/opt/aion/.env
#   OUTPUT_FILE=/opt/aion/command-center.env
#   PRINCIPAL_ID=principal_command_center
#   ACTOR_ID=act_human_command_center
#   TENANT_ID=aion-systems
#   DISPLAY_NAME="AION Command Center Operator"

ENV_FILE="${ENV_FILE:-/opt/aion/.env}"
OUTPUT_FILE="${OUTPUT_FILE:-/opt/aion/command-center.env}"
PRINCIPAL_ID="${PRINCIPAL_ID:-principal_command_center}"
ACTOR_ID="${ACTOR_ID:-act_human_command_center}"
TENANT_ID="${TENANT_ID:-aion-systems}"
DISPLAY_NAME="${DISPLAY_NAME:-AION Command Center Operator}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-aion-postgres-1}"
POSTGRES_DB="${POSTGRES_DB:-aion_data}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"

fail() {
  echo "[command-center-provision] ERROR: $*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run as root so /opt/aion secrets remain root-owned"
[[ -f "${ENV_FILE}" ]] || fail "missing ${ENV_FILE}"

for value in "${PRINCIPAL_ID}" "${ACTOR_ID}" "${TENANT_ID}"; do
  [[ "${value}" =~ ^[A-Za-z0-9._:-]+$ ]] || fail "ids may contain only A-Z a-z 0-9 . _ : -"
done
[[ ${#DISPLAY_NAME} -ge 3 ]] || fail "DISPLAY_NAME must be at least 3 characters"

umask 077
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="${ENV_FILE}.before-command-center.${timestamp}"
cp --preserve=mode,ownership,timestamps "${ENV_FILE}" "${backup}"
chmod 600 "${backup}"

runtime_token="aion_cc_$(openssl rand -hex 32)"
console_token="cc_access_$(openssl rand -hex 32)"

export ENV_FILE PRINCIPAL_ID ACTOR_ID TENANT_ID runtime_token

python3 <<'PY'
import json
import os
from pathlib import Path

env_path = Path(os.environ["ENV_FILE"])
principal_id = os.environ["PRINCIPAL_ID"]
actor_id = os.environ["ACTOR_ID"]
tenant_id = os.environ["TENANT_ID"]
token = os.environ["runtime_token"]

lines = env_path.read_text().splitlines()
prefix = "AION_GATEWAY_API_KEYS="
index = next((i for i, line in enumerate(lines) if line.startswith(prefix)), None)
if index is None:
    raise SystemExit("AION_GATEWAY_API_KEYS is missing from the runtime env file")

raw = lines[index][len(prefix):].strip()
try:
    records = json.loads(raw)
except Exception as exc:
    raise SystemExit(f"AION_GATEWAY_API_KEYS is not valid JSON: {exc}")

if not isinstance(records, list):
    raise SystemExit("AION_GATEWAY_API_KEYS must be a JSON array")

new_record = {
    "token": token,
    "principalId": principal_id,
    "kind": "operator",
    "actorId": actor_id,
    "tenantIds": [tenant_id],
    "roles": ["invoke", "approve"],
}

filtered = []
for record in records:
    if not isinstance(record, dict):
        raise SystemExit("existing AION_GATEWAY_API_KEYS contains a non-object entry")
    if record.get("principalId") == principal_id:
        continue
    if record.get("actorId") == actor_id:
        continue
    filtered.append(record)

filtered.append(new_record)
lines[index] = prefix + json.dumps(filtered, separators=(",", ":"))
env_path.write_text("\n".join(lines) + "\n")
PY

chmod 600 "${ENV_FILE}"
chown root:root "${ENV_FILE}" "${backup}"

actor_type="$(
  docker exec -i "${POSTGRES_CONTAINER}"     psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -X -Atq     -v ON_ERROR_STOP=1 -v actor_id="${ACTOR_ID}"     -c "SELECT actor_type FROM public.actors WHERE actor_id = :'actor_id';"
)"

if [[ -n "${actor_type}" ]]; then
  [[ "${actor_type}" == "human" ]] || fail "actor ${ACTOR_ID} already exists but is type ${actor_type}, not human"
  echo "[command-center-provision] actor ${ACTOR_ID} already registered as human; leaving it unchanged"
else
  docker exec -i "${POSTGRES_CONTAINER}"     psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -X     -v ON_ERROR_STOP=1     -v actor_id="${ACTOR_ID}"     -v display_name="${DISPLAY_NAME}" <<'SQL'
BEGIN;
INSERT INTO public.actors (
  actor_id,
  actor_type,
  name,
  permissions,
  allowed_tools,
  forbidden_capabilities,
  max_risk_level,
  escalation_conditions,
  metadata,
  created_at,
  updated_at
)
VALUES (
  :'actor_id',
  'human',
  :'display_name',
  '[]',
  '[]',
  '[]',
  'R2',
  '[]',
  jsonb_build_object(
    'registeredFor', 'AION Command Center approval decisions',
    'identityKind', 'dedicated operator principal',
    'registeredAt', now()
  ),
  now(),
  now()
);
COMMIT;
SQL
  echo "[command-center-provision] registered human actor ${ACTOR_ID}"
fi

runtime_domain="$(
  awk -F= '/^AION_DOMAIN=/{sub(/^AION_DOMAIN=/,""); print; exit}' "${ENV_FILE}"
)"
[[ -n "${runtime_domain}" ]] || fail "AION_DOMAIN is missing from ${ENV_FILE}"

cat > "${OUTPUT_FILE}" <<EOF
# Generated ${timestamp}. Root-owned secret handoff for AION Command Center.
# Move these values into the Command Center deployment secret store, then delete
# this file from the VPS when the handoff is complete.
COMMAND_CENTER_ACCESS_TOKEN=${console_token}
AION_RUNTIME_BASE_URL=https://${runtime_domain}
AION_RUNTIME_API_KEY=${runtime_token}
AION_TENANT_ID=${TENANT_ID}
EOF
chmod 600 "${OUTPUT_FILE}"
chown root:root "${OUTPUT_FILE}"

unset runtime_token console_token

echo
echo "[command-center-provision] PREPARED — not activated"
echo "[command-center-provision] principal : ${PRINCIPAL_ID}"
echo "[command-center-provision] actor     : ${ACTOR_ID} (human)"
echo "[command-center-provision] tenant    : ${TENANT_ID}"
echo "[command-center-provision] roles     : invoke, approve"
echo "[command-center-provision] backup    : ${backup}"
echo "[command-center-provision] handoff   : ${OUTPUT_FILE} (0600; contains secrets)"
echo
echo "Review the AION_GATEWAY_API_KEYS change without printing tokens:"
echo "  python3 - <<'PY'"
echo "import json"
echo "from pathlib import Path"
echo "line=next(x for x in Path('${ENV_FILE}').read_text().splitlines() if x.startswith('AION_GATEWAY_API_KEYS='))"
echo "for r in json.loads(line.split('=',1)[1]):"
echo "    print({k:v for k,v in r.items() if k != 'token'})"
echo "PY"
echo
echo "Activation remains a human/maintainer gate."
echo "After review, recreate only the Runtime service using the approved VPS deployment procedure."
echo "Then verify /health/ready and test the new bearer principal before wiring GE-001."
