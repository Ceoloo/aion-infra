-- Rollback of register-operator-actor.sql: removes the actor row ONLY if it has decided nothing and nothing else references it.
BEGIN;
SELECT set_config('aion.actor_id', :'actor_id', true);
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.approvals WHERE decided_by = current_setting('aion.actor_id')) THEN
    RAISE EXCEPTION 'actor % has decided approvals; not removing (audit history references it)', current_setting('aion.actor_id'); END IF;
END $$;
DELETE FROM public.actors WHERE actor_id = current_setting('aion.actor_id') AND actor_type = 'human';
COMMIT;
