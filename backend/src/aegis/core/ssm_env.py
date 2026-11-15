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
    for prefix in filter(None, (p.strip() for p in os.environ.get("AEGIS_SSM_PREFIX", "").split(","))):
        loaded += load_ssm_environment(prefix, region=region)
    return loaded


def load_ssm_environment(prefix: str, *, region: str, client: Any | None = None) -> list[str]:
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
            Path=prefix, WithDecryption=True, PaginationConfig={"MaxItems": _MAX_PARAMETERS}
        )
        for page in pages:
            for parameter in page["Parameters"]:
                name = str(parameter["Name"]).rsplit("/", 1)[-1].upper()
                if name not in os.environ:
                    os.environ[name] = str(parameter["Value"])
                    loaded.append(name)
    except Exception as exc:
        raise ConfigError(
            "could not read deployment secrets from SSM",
            context={"prefix": prefix, "error_type": type(exc).__name__},
        ) from exc
    return loaded
