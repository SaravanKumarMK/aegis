"""Durable claims and settlement for workflow dispatch requests."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Final

from aegis.core.logging import get_logger
from aegis.persistence.db import Database

log = get_logger(__name__)

DISPATCH_LEASE_SECONDS: Final = 120


@dataclass(frozen=True, slots=True)
class DispatchRecord:
    id: str
    job_id: str
    incident_id: str
    destination: str
    kind: str
    payload: dict[str, Any]
    attempts: int
    max_attempts: int
    lease_version: int
    # Which dispatch of the job this is: 0 for the first, +1 each time the job
    # returns to the queue (migration 013). Part of the external idempotency key.
    generation: int = 0

    @property
    def execution_name(self) -> str:
        return self.job_id if self.generation == 0 else f"{self.job_id}-g{self.generation}"


class DispatchOutbox:
    """Claims outbox rows with a renewable database lease."""

    __slots__ = ("_db",)

    def __init__(self, db: Database) -> None:
        self._db = db

    async def claim(self, dispatcher_id: str, destination: str) -> DispatchRecord | None:
        row = await self._db.fetchrow(
            """
            WITH next AS (
                SELECT id FROM workflow_dispatch_outbox
                 WHERE destination = $2
                   AND status = 'pending'
                   AND run_after <= now()
                 ORDER BY run_after, created_at
                 FOR UPDATE SKIP LOCKED
                 LIMIT 1
            )
            UPDATE workflow_dispatch_outbox o
               SET status = 'dispatching', locked_by = $1, locked_at = now(),
                   attempts = o.attempts + 1, updated_at = now()
                   , lease_version = o.lease_version + 1
              FROM next
             WHERE o.id = next.id
         RETURNING o.id, o.job_id, o.incident_id, o.destination,
                   o.attempts, o.max_attempts, o.lease_version, o.generation,
                   (SELECT kind FROM workflow_jobs WHERE id = o.job_id) AS kind,
                   (SELECT payload FROM workflow_jobs WHERE id = o.job_id) AS payload
            """,
            dispatcher_id,
            destination,
        )
        return DispatchRecord(**dict(row)) if row else None

    async def mark_dispatched(
        self,
        record_id: str,
        external_ref: str,
        *,
        dispatcher_id: str,
        lease_version: int,
    ) -> bool:
        result = await self._db.execute(
            """
            UPDATE workflow_dispatch_outbox
               SET status='dispatched', external_ref=$2, dispatched_at=now(),
                   locked_by=NULL, locked_at=NULL, last_error=NULL, updated_at=now()
             WHERE id=$1 AND status='dispatching'
               AND locked_by=$3 AND lease_version=$4
            """,
            record_id,
            external_ref[:1000],
            dispatcher_id,
            lease_version,
        )
        return result == "UPDATE 1"

    async def mark_failed(
        self,
        record_id: str,
        error: str,
        *,
        retry_in_s: int,
        dispatcher_id: str,
        lease_version: int,
    ) -> bool:
        result = await self._db.execute(
            """
            UPDATE workflow_dispatch_outbox
               SET status = CASE WHEN attempts >= max_attempts THEN 'failed' ELSE 'pending' END,
                   run_after = now() + make_interval(secs => $3),
                   last_error=$2, locked_by=NULL, locked_at=NULL, updated_at=now()
             WHERE id=$1 AND status='dispatching'
               AND locked_by=$4 AND lease_version=$5
            """,
            record_id,
            error[:2000],
            max(1, retry_in_s),
            dispatcher_id,
            lease_version,
        )
        return result == "UPDATE 1"

    async def in_flight(self, destination: str) -> int:
        """Dispatches handed to the orchestrator whose job has not finished.

        This is the number of workers that exist or are about to, so it is what
        the global concurrency cap bounds.
        """
        count = await self._db.fetchval(
            """
            SELECT count(*) FROM workflow_dispatch_outbox o
              JOIN workflow_jobs j ON j.id = o.job_id
             WHERE o.destination = $1 AND o.status = 'dispatched'
               AND j.status IN ('queued', 'running')
            """,
            destination,
        )
        return int(count or 0)

    async def next_due_in_s(self, destination: str) -> float | None:
        """Seconds until the earliest pending dispatch that is not yet due.

        Lets the orchestrator wait out a retry backoff instead of polling.
        """
        seconds = await self._db.fetchval(
            """
            SELECT EXTRACT(EPOCH FROM (min(run_after) - now()))
              FROM workflow_dispatch_outbox
             WHERE destination = $1 AND status = 'pending' AND run_after > now()
            """,
            destination,
        )
        return None if seconds is None else max(0.0, float(seconds))

    async def recover_stale(self, *, older_than_s: int = DISPATCH_LEASE_SECONDS) -> int:
        """Requeue dispatches whose owner died before recording the result."""
        result = await self._db.execute(
            """
            UPDATE workflow_dispatch_outbox
               SET status='pending', locked_by=NULL, locked_at=NULL,
                   run_after=now(), updated_at=now()
             WHERE status='dispatching'
               AND locked_at < now() - make_interval(secs => $1)
            """,
            older_than_s,
        )
        count = int(result.split()[-1]) if result.startswith("UPDATE") else 0
        if count:
            log.warning("recovered stale workflow dispatches", count=count)
        return count
