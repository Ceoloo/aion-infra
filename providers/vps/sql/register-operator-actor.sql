-- Register ONE operator account as a human approver actor (PROPOSED — not applied; needs owner approval AND confirmation of the identity).
-- Why: with the identity fix (aion-runtime PR #48) the approver is DERIVED from the authenticated principal's actorId, and that actor must already be a
-- registered *human* actor (approvals.decided_by is a FK to actors). Today the operator principal's actorId is not registered, so no decision can be recorded.
-- This registers exactly the actorId the operator principal already authenticates as — nothing is invented here; the owner must confirm the id is the
-- intended operator account (in .env.example it is only a template value).
-- IMPORTANT: a principal is a credential, not a person. If several people use this token, decided_by names the ACCOUNT.
--
-- Usage (on the host):   docker exec -i aion-postgres-1 psql -U postgres -d aion_data -X -v ON_ERROR_STOP=1 \
--                          -v actor_id='<principal.actorId from AION_GATEWAY_API_KEYS>' -v display_name='<who holds this account>' -f - < register-operator-actor.sql
-- Rollback:              register-operator-actor-rollback.sql (same -v actor_id), refuses if the actor has decided anything.
BEGIN;
SELECT set_config('aion.actor_id', :'actor_id', true), set_config('aion.display_name', :'display_name', true);
DO $$
BEGIN
  IF length(current_setting('aion.actor_id')) < 3 THEN RAISE EXCEPTION 'actor_id is required'; END IF;
  IF length(btrim(current_setting('aion.display_name'))) < 3 THEN RAISE EXCEPTION 'display_name is required (who holds this operator account)'; END IF;
  IF EXISTS (SELECT 1 FROM public.actors WHERE actor_id = current_setting('aion.actor_id')) THEN RAISE EXCEPTION 'actor % already exists — refusing to overwrite', current_setting('aion.actor_id'); END IF;
END $$;
INSERT INTO public.actors (actor_id, actor_type, name, permissions, allowed_tools, forbidden_capabilities, max_risk_level, escalation_conditions, metadata, created_at, updated_at)
VALUES (current_setting('aion.actor_id'), 'human', current_setting('aion.display_name'), '[]', '[]', '[]', 'R2', '[]',
        jsonb_build_object('registeredFor','approval decisions only','identityKind','operator account (shared credential, not a uniquely authenticated person)','registeredAt',now()),
        now(), now());
SELECT actor_id, actor_type, name, max_risk_level FROM public.actors WHERE actor_id = current_setting('aion.actor_id');
COMMIT;
