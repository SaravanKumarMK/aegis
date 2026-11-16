"""Scale-to-zero recovery properties that need real Postgres triggers and locking."""

from __future__ import annotations

import pytest

from aegis.persistence.db import Database
from aegis.persistence.dispatch_outbox import DispatchOutbox
from aegis.persistence.jobs import LEASE_SECONDS, JobQueue

pytestmark = [pytest.mark.integration, pytest.mark.asyncio]


async def _dispatch_once(db: Database, job_id: str) -> None:
    """Drive the outbox row for ``job_id`` through claim -> dispatched."""
    # Settle exactly this job's row, whatever else is pending in a shared database.
    row = await db.fetchrow(
        "UPDATE workflow_dispatch_outbox SET status='dispatching', locked_by='dispatcher-test', "
        "locked_at=now(), attempts=attempts+1, lease_version=lease_version+1 "
        "WHERE job_id=$1 AND status='pending' RETURNING id, lease_version",
        job_id,
    )
    assert row is not None
    assert await DispatchOutbox(db).mark_dispatched(
        row["id"],
        "ref",
        dispatcher_id="dispatcher-test",
        lease_version=row["lease_version"],
    )


async def _outbox(db: Database, job_id: str) -> dict[str, object]:
    row = await db.fetchrow(
        "SELECT status, generation, attempts, run_after > now() AS delayed "
        "FROM workflow_dispatch_outbox WHERE job_id=$1",
        job_id,
    )
    assert row is not None
    return dict(row)


async def test_planned_release_rearms_dispatch_and_refunds_the_attempt(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="rearm_release")
    assert job_id is not None
    await _dispatch_once(db, job_id)
    claimed = await queue.claim("worker-a", kinds=["rearm_release"])
    assert claimed is not None and claimed["attempts"] == 1

    assert await queue.release_own("worker-a") == 1

    job = await db.fetchrow("SELECT status, attempts FROM workflow_jobs WHERE id=$1", job_id)
    assert job is not None and job["status"] == "queued" and job["attempts"] == 0
    row = await _outbox(db, job_id)
    # Without the trigger this row would stay 'dispatched' and nothing would
    # ever start another worker for the released job.
    assert row["status"] == "pending" and row["generation"] == 1


async def test_failure_with_backoff_is_redispatched_after_the_delay_not_immediately(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="rearm_backoff")
    assert job_id is not None
    await _dispatch_once(db, job_id)
    claimed = await queue.claim("worker-a", kinds=["rearm_backoff"])
    assert claimed is not None

    assert await queue.fail(
        job_id,
        "transient",
        retry_in_s=120,
        worker_id="worker-a",
        lease_version=claimed["lease_version"],
    )

    row = await _outbox(db, job_id)
    assert row["status"] == "pending" and row["delayed"] is True
    wait = await DispatchOutbox(db).next_due_in_s("postgres")
    assert wait is not None and wait > 0


async def test_reaped_crash_is_redispatched_but_a_spent_job_is_parked(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="rearm_reap")
    assert job_id is not None
    await _dispatch_once(db, job_id)

    # Crash with attempts remaining: requeued, and a new dispatch is armed.
    assert await queue.claim("worker-a", kinds=["rearm_reap"]) is not None
    await db.execute(
        "UPDATE workflow_jobs SET locked_at=now()-make_interval(secs=>$2) WHERE id=$1",
        job_id,
        LEASE_SECONDS + 1,
    )
    assert await queue.reap_stale() >= 1
    assert (await _outbox(db, job_id))["status"] == "pending"

    # Crash on the final attempt: parked for an operator, never requeued, so a
    # crash loop cannot keep launching paid workers.
    await _dispatch_once(db, job_id)
    await db.execute(
        "UPDATE workflow_jobs SET status='running', locked_by='worker-b', "
        "attempts=max_attempts, locked_at=now()-make_interval(secs=>$2) WHERE id=$1",
        job_id,
        LEASE_SECONDS + 1,
    )
    assert await queue.reap_stale() >= 1
    job = await db.fetchrow("SELECT status FROM workflow_jobs WHERE id=$1", job_id)
    assert job is not None and job["status"] == "failed"
    assert (await _outbox(db, job_id))["status"] == "dispatched"


async def test_in_flight_counts_only_dispatched_unfinished_work(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    outbox = DispatchOutbox(db)
    before = await outbox.in_flight("postgres")
    job_id = await queue.enqueue(incident_id=clean_incident, kind="inflight_test")
    assert job_id is not None
    assert await outbox.in_flight("postgres") == before  # pending is not in flight

    await _dispatch_once(db, job_id)
    assert await outbox.in_flight("postgres") == before + 1

    claimed = await queue.claim("worker-a", kinds=["inflight_test"])
    assert claimed is not None
    assert await queue.complete(
        job_id, worker_id="worker-a", lease_version=claimed["lease_version"]
    )
    assert await outbox.in_flight("postgres") == before


async def test_concurrent_claims_cannot_overshoot_the_in_flight_ceiling(
    db: Database, clean_incident: str
) -> None:
    import asyncio

    queue = JobQueue(db)
    outbox = DispatchOutbox(db)
    for index in range(3):
        # One live job per (incident, kind), so each needs its own kind.
        assert await queue.enqueue(incident_id=clean_incident, kind=f"ceiling_{index}")

    ceiling = await outbox.in_flight("postgres") + 1
    claims = await asyncio.gather(
        *(outbox.claim(f"d{i}", "postgres", max_in_flight=ceiling) for i in range(3))
    )

    # Three racing dispatchers, one free slot: exactly one wins.
    assert sum(record is not None for record in claims) == 1


async def test_job_that_never_progresses_is_parked_at_the_redispatch_ceiling(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="ceiling_loop")
    assert job_id is not None
    await _dispatch_once(db, job_id)
    await db.execute(
        "UPDATE workflow_dispatch_outbox SET generation=25 WHERE job_id=$1", job_id
    )
    claimed = await queue.claim("worker-a", kinds=["ceiling_loop"])
    assert claimed is not None

    assert await queue.release_own("worker-a") == 1

    job = await db.fetchrow("SELECT status, last_error FROM workflow_jobs WHERE id=$1", job_id)
    assert job is not None and job["status"] == "failed"
    assert "ceiling" in str(job["last_error"])


async def test_app_role_gets_data_access_but_cannot_change_the_schema(db: Database) -> None:
    import asyncpg

    from aegis.core.errors import ConfigError
    from aegis.persistence.migrate_cli import grant_app_role

    role = "aegis_it_app"
    with pytest.raises(ConfigError):
        await grant_app_role(db, 'x"; DROP TABLE incidents; --')
    try:
        await grant_app_role(db, role)
        async with db.pool.acquire() as conn:
            await conn.execute(f"SET ROLE {role}")
            assert await conn.fetchval("SELECT count(*) FROM workflow_jobs") >= 0
            with pytest.raises(asyncpg.InsufficientPrivilegeError):
                await conn.execute("CREATE TABLE aegis_it_forbidden (id int)")
            with pytest.raises(asyncpg.InsufficientPrivilegeError):
                await conn.execute("DROP TABLE workflow_jobs")
            # Immutable audit history and the migration ledger stay out of reach.
            with pytest.raises(asyncpg.InsufficientPrivilegeError):
                await conn.execute("UPDATE audit_log SET actor = actor WHERE false")
            with pytest.raises(asyncpg.InsufficientPrivilegeError):
                await conn.execute("DELETE FROM audit_log WHERE false")
            with pytest.raises(asyncpg.InsufficientPrivilegeError):
                await conn.execute("DELETE FROM schema_migrations WHERE false")
            await conn.execute("RESET ROLE")
    finally:
        await db.execute(f"DROP OWNED BY {role}")
        await db.execute(f"DROP ROLE IF EXISTS {role}")


async def test_orphaned_dispatch_is_rearmed_only_after_a_worker_could_have_booted(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    outbox = DispatchOutbox(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="orphan_test")
    assert job_id is not None
    await _dispatch_once(db, job_id)

    # Just dispatched: a worker may be starting, so recovery must leave it alone.
    await outbox.recover_orphaned("postgres")
    assert (await _outbox(db, job_id))["status"] == "dispatched"

    # Dispatched long ago, job still queued and due: nothing will ever claim it.
    await db.execute(
        "UPDATE workflow_dispatch_outbox SET dispatched_at=now()-interval '20 minutes' "
        "WHERE job_id=$1",
        job_id,
    )
    assert await outbox.recover_orphaned("postgres") >= 1
    row = await _outbox(db, job_id)
    assert row["status"] == "pending" and row["generation"] == 1


async def test_orphan_recovery_parks_a_job_that_keeps_getting_stranded(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="orphan_ceiling")
    assert job_id is not None
    await _dispatch_once(db, job_id)
    await db.execute(
        "UPDATE workflow_dispatch_outbox SET generation=25, "
        "dispatched_at=now()-interval '20 minutes' WHERE job_id=$1",
        job_id,
    )

    await DispatchOutbox(db).recover_orphaned("postgres")

    job = await db.fetchrow("SELECT status FROM workflow_jobs WHERE id=$1", job_id)
    assert job is not None and job["status"] == "failed"


async def test_queue_depth_counts_waiting_and_running_jobs(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    before = await queue.queue_depth()
    assert await queue.enqueue(incident_id=clean_incident, kind="depth_test") is not None
    assert await queue.queue_depth() == before + 1


async def test_job_requeued_while_its_dispatch_is_mid_handoff_is_still_rearmed(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    outbox = DispatchOutbox(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="rearm_midhandoff")
    assert job_id is not None
    # The dispatcher has claimed the row but has not yet recorded the result.
    record = await outbox.claim("dispatcher-a", "postgres")
    while record is not None and record.job_id != job_id:
        record = await outbox.claim("dispatcher-a", "postgres")
    assert record is not None
    claimed = await queue.claim("worker-a", kinds=["rearm_midhandoff"])
    assert claimed is not None
    assert await queue.release_own("worker-a") == 1

    row = await _outbox(db, job_id)
    assert row["status"] == "pending" and row["generation"] == 1
    # The late result of the old hand-off is refused by lease fencing.
    assert not await outbox.mark_dispatched(
        record.id, "late", dispatcher_id="dispatcher-a", lease_version=record.lease_version
    )
    assert (await _outbox(db, job_id))["status"] == "pending"


async def test_exhausted_dispatch_is_recovered_not_stranded(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    outbox = DispatchOutbox(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="failed_dispatch")
    assert job_id is not None
    await db.execute(
        "UPDATE workflow_dispatch_outbox SET status='failed', attempts=5, "
        "updated_at=now()-interval '20 minutes' WHERE job_id=$1",
        job_id,
    )

    assert await outbox.recover_orphaned("postgres") >= 1
    row = await _outbox(db, job_id)
    assert row["status"] == "pending" and row["generation"] == 1


async def test_parking_at_the_ceiling_leaves_an_audit_record(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="park_audit")
    assert job_id is not None
    await _dispatch_once(db, job_id)
    await db.execute(
        "UPDATE workflow_dispatch_outbox SET generation=25 WHERE job_id=$1", job_id
    )
    claimed = await queue.claim("worker-a", kinds=["park_audit"])
    assert claimed is not None
    assert await queue.release_own("worker-a") == 1

    assert (await _outbox(db, job_id))["status"] == "failed"
    audit = await db.fetchval(
        "SELECT count(*) FROM audit_log WHERE resource_id=$1 AND event_type='workflow.job_parked'",
        job_id,
    )
    assert audit == 1


async def test_dispatch_is_not_claimed_for_a_job_that_is_no_longer_waiting(
    db: Database, clean_incident: str
) -> None:
    queue = JobQueue(db)
    job_id = await queue.enqueue(incident_id=clean_incident, kind="gone_job")
    assert job_id is not None
    await db.execute("UPDATE workflow_jobs SET status='cancelled' WHERE id=$1", job_id)

    outbox = DispatchOutbox(db)
    seen: list[str] = []
    while (record := await outbox.claim("dispatcher-x", "postgres")) is not None:
        seen.append(record.job_id)
        await outbox.mark_failed(
            record.id, "cleanup", retry_in_s=3600, dispatcher_id="dispatcher-x",
            lease_version=record.lease_version,
        )
    assert job_id not in seen
