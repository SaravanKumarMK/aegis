"""Load deployment secrets from SSM Parameter Store into the environment.

A Lambda has no ECS-style secret injection and no NAT gateway, so secrets are
read once per cold start over the IPv6 dual-stack SSM endpoint. Standard
SecureString parameters are free, and their values never enter Terraform state.

Only names already declared as settings are honoured, and an existing
environment variable always wins, so local development and tests are unaffected.
"""

from __future__ import annotations

import os
from typing import Any

from aegis.core.errors import ConfigError

_MAX_PARAMETERS = 50


def bootstrap_environment() -> list[str]:
    """Entry-point hook: load ``AEGIS_SSM_PREFIX`` parameters when configured."""
    # Comma-separated so a component loads only the paths its IAM role may read:
    # the API role sees /api, the worker role /api and /worker (model keys).
    region = os.environ.get("AWS_REGION", "us-east-1")
    loaded: list[str] = []
    raw = os.environ.get("AEGIS_SSM_PREFIX", "")
    # Only names the application declares as settings may be set: a parameter
    # named PYTHONPATH, LD_PRELOAD or AWS_ENDPOINT_URL must never reach the process.
    from aegis.core.config import Settings

    allowed = {name.upper() for name in Settings.model_fields}
    for prefix in filter(None, (p.strip() for p in raw.split(","))):
        loaded += load_ssm_environment(prefix, region=region, allowed=allowed)
    return loaded


def load_ssm_environment(
    prefix: str,
    *,
    region: str,
    client: Any | None = None,
    allowed: set[str] | None = None,
) -> list[str]:
    """Populate ``os.environ`` from ``<prefix>/<ENV_NAME>`` parameters.

    Returns the names loaded. Fails closed: an unreadable prefix is a boot error,
    never a silent fall-through to an unauthenticated configuration.
    """
    prefix = prefix.rstrip("/")
    if not prefix.startswith("/"):
        raise ConfigError("AEGIS_SSM_PREFIX must be an absolute parameter path")
    if client is None:
        import boto3
        from botocore.config import Config  # type: ignore[import-untyped]

        client = boto3.session.Session(region_name=region).client(
            "ssm",
            endpoint_url=f"https://ssm.{region}.api.aws",
            config=Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 2}),
        )
    loaded: list[str] = []
    try:
        pages = client.get_paginator("get_parameters_by_path").paginate(
            Path=prefix, WithDecryption=True
        )
        seen = 0
        for page in pages:
            for parameter in page["Parameters"]:
                seen += 1
                # A silently truncated list would let a missing setting fall back
                # to its default (e.g. a disabled control), so too many is fatal.
                if seen > _MAX_PARAMETERS:
                    raise ConfigError("too many SSM parameters under the prefix")
                name = str(parameter["Name"]).rsplit("/", 1)[-1].upper()
                if allowed is not None and name not in allowed:
                    raise ConfigError(
                        "SSM parameter is not a declared setting", context={"parameter": name}
                    )
                if name not in os.environ:
                    os.environ[name] = str(parameter["Value"])
                    loaded.append(name)
    except ConfigError:
        raise
    except Exception as exc:
        raise ConfigError(
            "could not read deployment secrets from SSM",
            context={"prefix": prefix, "error_type": type(exc).__name__},
        ) from exc
    return loaded
