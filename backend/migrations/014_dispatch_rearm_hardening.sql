-- Harden the re-arm trigger after independent review of 013.
--
-- * A job can return to 'queued' while its outbox row is still 'dispatching'
--   (a slow mark_dispatched, a worker that fails fast) or 'failed' (dispatch
--   attempts exhausted). 013 re-armed only 'dispatched', stranding those jobs.
--   Every non-pending state is now re-armed, and lease_version is bumped so an
--   in-flight mark_dispatched/mark_failed from the previous hand-off is refused
--   by its fencing instead of overwriting the new pending row.
-- * Parking a job at the redispatch ceiling used to be silent: the calling
--   statement reported success, no audit row existed and the outbox row still
--   said 'dispatched'. It now writes an audit record and settles the outbox row.

CREATE OR REPLACE FUNCTION aegis_rearm_dispatch_outbox()
RETURNS TRIGGER AS $$
DECLARE
    current_generation INTEGER;
BEGIN
    SELECT generation INTO current_generation
      FROM workflow_dispatch_outbox
     WHERE job_id = NEW.id
       AND status IN ('dispatched', 'dispatching', 'failed');

    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF current_generation >= 25 THEN
        UPDATE workflow_jobs
           SET status = 'failed',
               last_error = 'redispatch ceiling reached without completing',
               updated_at = now()
         WHERE id = NEW.id;
        UPDATE workflow_dispatch_outbox
           SET status = 'failed',
               last_error = 'redispatch ceiling reached without completing',
               updated_at = now()
         WHERE job_id = NEW.id;
        INSERT INTO audit_log
            (incident_id, actor, actor_type, event_type, resource_type, resource_id, detail)
        VALUES
            (NEW.incident_id, 'aegis-dispatch', 'system', 'workflow.job_parked',
             'workflow_job', NEW.id,
             jsonb_build_object('reason', 'redispatch ceiling reached',
                                'generation', current_generation));
        RETURN NEW;
    END IF;

    UPDATE workflow_dispatch_outbox
       SET status        = 'pending',
           generation    = generation + 1,
           attempts      = 0,
           lease_version = lease_version + 1,
           locked_by     = NULL,
           locked_at     = NULL,
           external_ref  = NULL,
           last_error    = NULL,
           run_after     = GREATEST(NEW.run_after, now()),
           updated_at    = now(),
           dispatched_at = NULL
     WHERE job_id = NEW.id
       AND status IN ('dispatched', 'dispatching', 'failed');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
