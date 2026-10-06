# Command Center operator provisioning

This runbook creates the dedicated Runtime identity used by AION Command Center.

## Identity

- principal: `principal_command_center`
- kind: `operator`
- actor: `act_human_command_center`
- tenant: `aion-systems`
- roles: `invoke`, `approve`

The Command Center does not receive `register` by default. Actor registration is performed by the provisioning script using the host's administrative database path before the Runtime credential is activated.

## Host-side provisioning

Run from a trusted checkout on the production VPS:

```bash
sudo providers/vps/scripts/provision-command-center-operator.sh
```

The script:

1. backs up `/opt/aion/.env`;
2. generates a new 256-bit Runtime bearer token on the host;
3. inserts/replaces only the dedicated Command Center principal in `AION_GATEWAY_API_KEYS`;
4. registers `act_human_command_center` as a durable human actor if it does not already exist;
5. generates a separate Command Center access token;
6. writes the four Command Center deployment values to `/opt/aion/command-center.env` with mode `0600`;
7. does **not** restart Runtime.

No real secret is committed or printed by default.

## Review before activation

Inspect principal metadata without printing tokens:

```bash
python3 - <<'PY'
import json
from pathlib import Path
line=next(x for x in Path('/opt/aion/.env').read_text().splitlines() if x.startswith('AION_GATEWAY_API_KEYS='))
for r in json.loads(line.split('=',1)[1]):
    print({k:v for k,v in r.items() if k != 'token'})
PY
```

Expected Command Center entry:

```json
{
  "principalId": "principal_command_center",
  "kind": "operator",
  "actorId": "act_human_command_center",
  "tenantIds": ["aion-systems"],
  "roles": ["invoke", "approve"]
}
```

Confirm the actor:

```bash
docker exec -i aion-postgres-1 psql -U postgres -d aion_data -X -c \
  "SELECT actor_id, actor_type, name FROM public.actors WHERE actor_id='act_human_command_center';"
```

## Activation gate

Provisioning alone does not activate the credential. A production maintainer must explicitly recreate the Runtime service using the approved VPS deployment procedure so the process reloads `AION_GATEWAY_API_KEYS`.

After activation:

1. verify `/health/live`;
2. verify `/health/ready`;
3. test a tenant-scoped read using the new bearer token;
4. copy the four values from `/opt/aion/command-center.env` into the Command Center deployment secret store;
5. delete `/opt/aion/command-center.env` after the secret handoff is complete.

Do not proceed to GE-001 until the Runtime principal authenticates and the human actor binding is verified.
