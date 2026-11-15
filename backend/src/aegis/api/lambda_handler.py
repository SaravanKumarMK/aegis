"""AWS Lambda adapter for the unchanged FastAPI router/auth contract."""

from __future__ import annotations

import os

from mangum import Mangum

from aegis.core.ssm_env import load_ssm_environment

# Secrets must be in the environment before the app module builds its settings.
if _prefix := os.environ.get("AEGIS_SSM_PREFIX", ""):
    load_ssm_environment(_prefix, region=os.environ.get("AWS_REGION", "us-east-1"))

from aegis.api.app import app  # noqa: E402 - import order is the point

# Lifespan stays enabled: one warm Lambda execution environment owns one pool
# and one verifier, exactly as one service process does. Migrations are disabled
# by API_RUN_MIGRATIONS=false in the Lambda environment and run separately.
handler = Mangum(app, lifespan="auto")

__all__ = ["handler"]
