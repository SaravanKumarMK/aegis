"""One-off schema migration command for deploy jobs and operator runbooks."""

from __future__ import annotations

import asyncio
import os
import re

from aegis.core.config import get_settings
from aegis.core.errors import ConfigError
from aegis.core.logging import configure_logging, get_logger
from aegis.core.ssm_env import bootstrap_environment
from aegis.persistence.db import Database
from aegis.persistence.migrate import run_migrations

log = get_logger(__name__)


_ROLE_RE = re.compile(r"[a-z_][a-z0-9_]{0,62}")


async def grant_app_role(db: Database, role: str) -> None:
    """Create the IAM-authenticated runtime role with data access and nothing else.

    Runs as the migration owner after the schema exists. The application never
    issues DDL, so the role gets DML on current and future tables, sequence use
    and function execution - no CREATE, no ownership. The name is validated
    before being quoted into DDL, which cannot take bind parameters.
    """
    if not _ROLE_RE.fullmatch(role):
        raise ConfigError("AEGIS_APP_DB_ROLE must be a simple lowercase identifier")
    quoted = f'"{role}"'
    async with db.transaction() as conn:
        if not await conn.fetchval("SELECT 1 FROM pg_roles WHERE rolname = $1", role):
            await conn.execute(f"CREATE ROLE {quoted} LOGIN")
        # rds_iam exists only on RDS/Aurora; local databases authenticate by password.
        if await conn.fetchval("SELECT 1 FROM pg_roles WHERE rolname = 'rds_iam'"):
            await conn.execute(f"GRANT rds_iam TO {quoted}")
        await conn.execute(f"GRANT USAGE ON SCHEMA public TO {quoted}")
        await conn.execute(
            f"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {quoted}"
        )
        await conn.execute(f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {quoted}")
        await conn.execute(f"GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO {quoted}")
        await conn.execute(
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE "
            f"ON TABLES TO {quoted}"
        )
        await conn.execute(
            "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES "
            f"TO {quoted}"
        )
    log.info("application database role granted", role=role)


async def migrate() -> int:
    bootstrap_environment()
    settings = get_settings()
    configure_logging(settings.log_level, settings.log_format)
    db = Database(settings)
    try:
        await db.connect()
        applied = await run_migrations(db)
        if app_role := os.environ.get("AEGIS_APP_DB_ROLE", ""):
            await grant_app_role(db, app_role)
        log.info("migration command complete", applied=len(applied))
        return 0
    finally:
        await db.close()


def main() -> int:
    return asyncio.run(migrate())


if __name__ == "__main__":
    raise SystemExit(main())
