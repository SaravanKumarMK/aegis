-- Re-arm external dispatch whenever a job returns to the queue.
--
-- Under scale-to-zero there is no resident worker to notice that a job went
-- back to 'queued' (retry with backoff, graceful release at a time limit, or a
-- reaped crash). The outbox row for such a job was already 'dispatched', so
-- nothing would ever start another worker. This trigger makes the invariant
-- structural: every transition into 'queued' produces exactly one new pending
-- dispatch, whichever code path performed it.
--
-- `generation` distinguishes the dispatches of one job. Orchestrators that key
-- idempotency on a name (Step Functions) use job id for generation 0 and
-- job id + generation afterwards, so a retry is a new execution while a
-- duplicate of the same dispatch is still the same one.

ALTER TABLE workflow_dispatch_outbox
    ADD COLUMN IF NOT EXISTS generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0);

CREATE OR REPLACE FUNCTION aegis_rearm_dispatch_outbox()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE workflow_dispatch_outbox
       SET status        = 'pending',
           generation    = generation + 1,
           attempts      = 0,
           locked_by     = NULL,
           locked_at     = NULL,
           external_ref  = NULL,
           last_error    = NULL,
           run_after     = GREATEST(NEW.run_after, now()),
           updated_at    = now(),
           dispatched_at = NULL
     WHERE job_id = NEW.id
       AND status = 'dispatched';
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS workflow_jobs_rearm_dispatch ON workflow_jobs;
CREATE TRIGGER workflow_jobs_rearm_dispatch
AFTER UPDATE OF status ON workflow_jobs
FOR EACH ROW
WHEN (NEW.status = 'queued' AND OLD.status IS DISTINCT FROM 'queued')
EXECUTE FUNCTION aegis_rearm_dispatch_outbox();

-- Count in-flight dispatches without a table scan.
CREATE INDEX IF NOT EXISTS workflow_dispatch_outbox_dispatched_idx
    ON workflow_dispatch_outbox (destination, job_id)
    WHERE status = 'dispatched';
