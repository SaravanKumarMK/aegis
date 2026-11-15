"""Scale-to-zero dispatch guarantees that need no infrastructure."""

from __future__ import annotations

import os
from typing import Any

import pytest

from aegis.core.config import Settings
from aegis.core.errors import ConfigError
from aegis.core.ssm_env import load_ssm_environment
from aegis.persistence.dispatch_outbox import DispatchRecord
from aegis.worker.dispatch import StepFunctionsDispatchAdapter, WorkflowDispatcher
from aegis.worker.kick import DispatchKick, kick_dispatch


def _record(job_id: str = "job_1", generation: int = 0, dispatch_id: str = "d1") -> DispatchRecord:
    return DispatchRecord(
        id=dispatch_id,
        job_id=job_id,
        incident_id="inc_1",
        destination="step_functions",
        kind="investigate",
        payload={},
        attempts=1,
        max_attempts=5,
        lease_version=1,
        generation=generation,
    )


def test_first_dispatch_keeps_the_job_id_and_retries_get_a_new_identity() -> None:
    assert _record(generation=0).execution_name == "job_1"
    assert _record(generation=2).execution_name == "job_1-g2"


class _CapturingSfn:
    def __init__(self) -> None:
        self.names: list[str] = []

    def start_execution(self, **kwargs: Any) -> dict[str, str]:
        self.names.append(kwargs["name"])
        return {"executionArn": f"arn:aws:states:::execution:m:{kwargs['name']}"}


@pytest.mark.asyncio
async def test_a_requeued_job_starts_a_new_execution_not_a_duplicate_of_the_old() -> None:
    settings = Settings(
        step_functions_state_machine_arn="arn:aws:states:us-west-2:1:stateMachine:aegis",
        workflow_dispatch_attempts=1,
        otel_traces_enabled=False,
    )
    client = _CapturingSfn()
    adapter = StepFunctionsDispatchAdapter(settings, client=client)

    await adapter.dispatch(_record(generation=0))
    await adapter.dispatch(_record(generation=1))

    assert client.names == ["job_1", "job_1-g1"]


class _Outbox:
    def __init__(self, records: list[DispatchRecord], in_flight: int) -> None:
        self.records = records
        self._in_flight = in_flight
        self.claims = 0
        self.dispatched: list[str] = []

    async def recover_stale(self) -> int:
        return 0

    async def in_flight(self, _destination: str) -> int:
        return self._in_flight

    async def next_due_in_s(self, _destination: str) -> float | None:
        return 12.5

    async def claim(self, _id: str, _destination: str) -> DispatchRecord | None:
        self.claims += 1
        return self.records.pop(0) if self.records else None

    async def mark_dispatched(self, record_id: str, _ref: str, **_: Any) -> bool:
        self.dispatched.append(record_id)
        return True

    async def mark_failed(self, *_: Any, **__: Any) -> bool:
        raise AssertionError("dispatch should not fail in this test")


class _Adapter:
    destination = "step_functions"

    def __init__(self) -> None:
        self.calls = 0

    async def dispatch(self, record: DispatchRecord) -> str:
        self.calls += 1
        return f"ref:{record.id}"


@pytest.mark.asyncio
async def test_concurrency_ceiling_defers_dispatch_instead_of_starting_workers() -> None:
    records = [_record(dispatch_id=f"d{i}", job_id=f"job_{i}") for i in range(4)]
    outbox = _Outbox(records, in_flight=5)
    adapter = _Adapter()
    dispatcher = WorkflowDispatcher(outbox, adapter, max_in_flight=5)  # type: ignore[arg-type]

    assert await dispatcher.dispatch_batch("t", limit=10) == 0
    # Rows were never claimed, so they remain pending for the next settle.
    assert outbox.claims == 0 and adapter.calls == 0


@pytest.mark.asyncio
async def test_ceiling_only_admits_the_remaining_capacity() -> None:
    records = [_record(dispatch_id=f"d{i}", job_id=f"job_{i}") for i in range(4)]
    outbox = _Outbox(records, in_flight=3)
    adapter = _Adapter()
    dispatcher = WorkflowDispatcher(outbox, adapter, max_in_flight=5)  # type: ignore[arg-type]

    assert await dispatcher.dispatch_batch("t", limit=10) == 2
    assert adapter.calls == 2 and len(outbox.records) == 2


@pytest.mark.asyncio
async def test_next_due_reports_backoff_so_the_orchestrator_waits_not_polls() -> None:
    dispatcher = WorkflowDispatcher(_Outbox([], 0), _Adapter())  # type: ignore[arg-type]
    assert await dispatcher.next_due_in_s() == 12.5


class _ExplodingDispatcher:
    async def dispatch_batch(self, *_: Any, **__: Any) -> int:
        raise RuntimeError("states endpoint unreachable")


@pytest.mark.asyncio
async def test_inline_kick_never_fails_the_request_that_already_committed() -> None:
    kick = DispatchKick(
        _ExplodingDispatcher(),  # type: ignore[arg-type]
        dispatcher_id="api-1",
        timeout_s=1.0,
    )
    assert await kick() == 0


@pytest.mark.asyncio
async def test_kick_dispatch_is_a_noop_without_an_orchestrator() -> None:
    class _State:
        dispatch_kick = None

    await kick_dispatch(_State())


class _Paginator:
    def __init__(self, parameters: list[dict[str, str]]) -> None:
        self._parameters = parameters

    def paginate(self, **_: Any) -> list[dict[str, Any]]:
        return [{"Parameters": self._parameters}]


class _Ssm:
    def __init__(self, parameters: list[dict[str, str]], *, fail: bool = False) -> None:
        self._parameters = parameters
        self._fail = fail

    def get_paginator(self, _name: str) -> _Paginator:
        if self._fail:
            raise RuntimeError("AccessDeniedException")
        return _Paginator(self._parameters)


def test_ssm_loader_never_overrides_an_explicit_environment_variable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("ALERT_INGEST_TOKEN", "from-operator")
    monkeypatch.delenv("FIREBASE_PROJECT_ID", raising=False)
    client = _Ssm(
        [
            {"Name": "/aegis/zero/ALERT_INGEST_TOKEN", "Value": "from-ssm"},
            {"Name": "/aegis/zero/firebase_project_id", "Value": "demo-project"},
        ]
    )

    loaded = load_ssm_environment("/aegis/zero/", region="us-west-2", client=client)

    assert loaded == ["FIREBASE_PROJECT_ID"]
    assert os.environ["ALERT_INGEST_TOKEN"] == "from-operator"
    monkeypatch.delenv("FIREBASE_PROJECT_ID", raising=False)


def test_ssm_loader_fails_closed_when_secrets_cannot_be_read() -> None:
    with pytest.raises(ConfigError, match="SSM"):
        load_ssm_environment("/aegis/zero", region="us-west-2", client=_Ssm([], fail=True))


def test_ssm_loader_rejects_a_relative_prefix() -> None:
    with pytest.raises(ConfigError, match="absolute"):
        load_ssm_environment("aegis/zero", region="us-west-2", client=_Ssm([]))


def test_dualstack_endpoint_is_opt_in() -> None:
    off = Settings(aws_region="us-west-2", otel_traces_enabled=False)
    on = Settings(aws_region="us-west-2", aws_dualstack_endpoints=True, otel_traces_enabled=False)
    assert off.dualstack_endpoint("states") is None
    assert on.dualstack_endpoint("states") == "https://states.us-west-2.api.aws"
