"""Hand a just-committed job to the orchestrator, inside the request that made it.

Scale-to-zero has no resident dispatcher polling the outbox, so the process that
commits the job is the cheapest wake-up. The job and its outbox row are already
durable when this runs; a failure here costs latency, never the job, because the
recovery sweep drains whatever is still pending.
"""

from __future__ import annotations

import asyncio
import os

from aegis.core.config import Settings
from aegis.core.logging import get_logger
from aegis.persistence.db import Database
from aegis.persistence.dispatch_outbox import DispatchOutbox
from aegis.worker.dispatch import WorkflowDispatcher, build_dispatch_adapter

log = get_logger(__name__)

# One request may add a handful of jobs (approval + resume); never drain the
# whole backlog from a user-facing path.
_KICK_BATCH = 3


class DispatchKick:
    __slots__ = ("_dispatcher", "_dispatcher_id", "_timeout_s")

    def __init__(self, dispatcher: WorkflowDispatcher, *, dispatcher_id: str, timeout_s: float):
        self._dispatcher = dispatcher
        self._dispatcher_id = dispatcher_id
        self._timeout_s = timeout_s

    async def __call__(self) -> int:
        """Dispatch up to a few due rows. Never raises: the request already succeeded."""
        try:
            return await asyncio.wait_for(
                self._dispatcher.dispatch_batch(self._dispatcher_id, limit=_KICK_BATCH),
                timeout=self._timeout_s,
            )
        except Exception as exc:  # noqa: BLE001 - the committed outbox row is the guarantee
            log.warning(
                "inline dispatch did not complete; recovery sweep will retry",
                error_type=type(exc).__name__,
            )
            return 0


async def kick_dispatch(app_state: object) -> None:
    """Call the app's dispatch kick, if the deployment has one."""
    kick = getattr(app_state, "dispatch_kick", None)
    if kick is not None:
        await kick()


def build_dispatch_kick(settings: Settings, db: Database) -> DispatchKick | None:
    """None unless an external orchestrator is configured (Postgres polling needs no kick)."""
    if settings.workflow_dispatch_backend != "step_functions":
        return None
    dispatcher = WorkflowDispatcher(
        DispatchOutbox(db),
        build_dispatch_adapter(settings),
        max_in_flight=settings.workflow_max_in_flight,
    )
    return DispatchKick(
        dispatcher,
        dispatcher_id=f"api-{os.getpid()}",
        timeout_s=settings.dispatch_kick_timeout_s,
    )
