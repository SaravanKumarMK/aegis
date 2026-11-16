"""The on-demand worker has externally enforced, finite lifecycle controls."""

from __future__ import annotations

import asyncio
from types import SimpleNamespace
from typing import Any

import pytest

from aegis.worker import main as worker_main


class EmptyQueue:
    def __init__(self, _: Any) -> None:
        self.claims = 0
        self.destinations: list[str] = []

    async def claim(self, *_: Any, **kwargs: Any) -> None:
        self.claims += 1
        self.destinations.append(kwargs.get("dispatch_destination", "postgres"))


def bare_worker(*, max_jobs: int | None, max_seconds: float | None) -> Any:
    worker = worker_main.Worker.__new__(worker_main.Worker)
    worker.worker_id = "bounded-test"
    worker.concurrency = 1
    worker.max_jobs = max_jobs
    worker.max_seconds = max_seconds
    worker.stop_when_idle = True
    worker._monotonic = lambda: 0.0
    worker._stopping = asyncio.Event()
    worker._inflight = set()
    worker._db = object()
    worker._deadline = max_seconds
    worker._settings = SimpleNamespace(workflow_dispatch_backend="step_functions")
    return worker


@pytest.mark.asyncio
async def test_bounded_worker_exits_immediately_when_there_is_no_work(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    queue = EmptyQueue(object())
    monkeypatch.setattr(worker_main, "JobQueue", lambda _: queue)

    await bare_worker(max_jobs=5, max_seconds=None)._poll_loop()

    assert queue.claims == 1
    # Regression: the worker must claim the destination it was dispatched for.
    assert queue.destinations == ["step_functions"]


@pytest.mark.asyncio
async def test_time_budget_can_end_before_the_first_claim(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    queue = EmptyQueue(object())
    monkeypatch.setattr(worker_main, "JobQueue", lambda _: queue)
    worker = bare_worker(max_jobs=None, max_seconds=0.5)
    worker._monotonic = lambda: 1.0

    await worker._poll_loop()

    assert queue.claims == 0


def test_worker_cli_cannot_raise_agent_budgets() -> None:
    options = {
        option
        for action in worker_main.parser()._actions  # noqa: SLF001 - CLI contract test
        for option in action.option_strings
    }
    assert "--once" in options
    assert "--max-jobs" in options
    assert "--max-seconds" in options
    assert not any("budget" in option or "token" in option or "llm" in option for option in options)


async def _recorded_drain_timeout(
    monkeypatch: pytest.MonkeyPatch, *, stopping: bool, deadline: float | None
) -> float | None:
    seen: list[float | None] = []

    async def fake_wait(
        tasks: Any, timeout: float | None = None  # noqa: ASYNC109 - mirrors asyncio.wait
    ) -> tuple[set[Any], set[Any]]:
        seen.append(timeout)
        return set(tasks), set()

    class Container:
        async def aclose(self) -> None:
            return None

    monkeypatch.setattr(worker_main.asyncio, "wait", fake_wait)
    worker = bare_worker(max_jobs=1, max_seconds=deadline)
    worker._inflight = {object()}
    worker._horizon = None
    worker._container = Container()
    if stopping:
        worker._stopping.set()
    await worker._shutdown()
    return seen[0]


@pytest.mark.asyncio
async def test_planned_exit_lets_the_claimed_job_use_the_whole_time_budget(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Regression: a --once worker used to cancel its only job after 90 s and hand
    # it back, so every investigation restarted from its checkpoint each lap.
    assert await _recorded_drain_timeout(monkeypatch, stopping=False, deadline=3000) == 3000


@pytest.mark.asyncio
async def test_a_stop_signal_is_still_bounded_by_the_platform_grace_period(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert await _recorded_drain_timeout(monkeypatch, stopping=True, deadline=3000) == 90.0
