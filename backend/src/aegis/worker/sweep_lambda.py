"""Lambda entry point that settles and recovers workflow dispatch.

Invoked two ways, with the same code:

* by Step Functions after every worker task (success or failure), so the work a
  finished worker left behind - a retry after backoff, a job released at its
  time slice, a reaped crash - is dispatched immediately; and
* by a low-frequency EventBridge schedule, the only recovery path for a request
  that died between committing a job and publishing it.

Neither is a poller: with no work, nothing runs and Aurora stays paused.
"""

from __future__ import annotations

import asyncio
import math
import time
from typing import Any

from aegis.core.config import get_settings
from aegis.core.errors import DatabaseResuming
from aegis.core.logging import configure_logging, get_logger
from aegis.core.ssm_env import bootstrap_environment
from aegis.persistence.db import Database
from aegis.persistence.dispatch_outbox import DispatchOutbox
from aegis.persistence.jobs import JobQueue
from aegis.worker.dispatch import WorkflowDispatcher, build_dispatch_adapter

log = get_logger(__name__)

_BATCH = 25
_RESUME_RETRY_S = 4.0
# Step Functions Wait is cheap but a sweep that waits forever on a job that keeps
# failing is not; the caller bounds iterations and this bounds one wait.
_MAX_RETRY_WAIT_S = 900


async def _connect(db: Database, budget_s: float) -> None:
    """Connect, riding out an Aurora resume for at most ``budget_s``."""
    deadline = time.monotonic() + budget_s
    while True:
        try:
            await db.connect()
            return
        except DatabaseResuming:
            if time.monotonic() + _RESUME_RETRY_S >= deadline:
                raise
            await asyncio.sleep(_RESUME_RETRY_S)


async def run_sweep(event: dict[str, Any], *, resume_budget_s: float = 40.0) -> dict[str, Any]:
    settings = get_settings()
    configure_logging(settings.log_level, settings.log_format)
    db = Database(settings)
    await _connect(db, resume_budget_s)
    try:
        reaped = await JobQueue(db).reap_stale()
        outbox = DispatchOutbox(db)
        orphaned = await outbox.recover_orphaned(settings.workflow_dispatch_backend)
        dispatcher = WorkflowDispatcher(
            outbox,
            build_dispatch_adapter(settings),
            max_in_flight=settings.workflow_max_in_flight,
        )
        dispatched = await dispatcher.dispatch_batch(
            f"sweep-{event.get('source', 'schedule')}", limit=_BATCH
        )
        wait_s = await dispatcher.next_due_in_s()
    finally:
        await db.close()
    retry_in_s = None if wait_s is None else min(_MAX_RETRY_WAIT_S, max(1, math.ceil(wait_s)))
    log.info(
        "dispatch sweep complete",
        reaped=reaped,
        orphaned=orphaned,
        dispatched=dispatched,
        retry_in_s=retry_in_s,
    )
    return {
        "reaped": reaped,
        "orphaned": orphaned,
        "dispatched": dispatched,
        "retry_in_s": retry_in_s,
    }


def handler(event: dict[str, Any] | None, _context: object) -> dict[str, Any]:
    bootstrap_environment()
    return asyncio.run(run_sweep(event or {}))
