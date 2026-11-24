"""PostgreSQL transaction wrapper. The identity scope is set from trusted D0 state."""
from __future__ import annotations

from contextlib import contextmanager
import os
from typing import Iterator, Protocol, Any

from .context import RequestContext


class DatabaseUnavailable(RuntimeError):
    pass


class ConnectionLike(Protocol):
    def cursor(self) -> Any: ...
    def commit(self) -> None: ...
    def rollback(self) -> None: ...
    def close(self) -> None: ...


class PostgresDatabase:
    """Open one connection per request operation and scope every transaction."""

    def __init__(self, dsn: str | None = None, connect: Any | None = None):
        self.dsn = dsn or os.environ.get("APOIO_DATABASE_URL")
        self._connect = connect

    def _open(self) -> ConnectionLike:
        if self._connect is not None:
            return self._connect(self.dsn)
        if not self.dsn:
            raise DatabaseUnavailable("A base de dados do Apoio não está configurada.")
        try:
            import psycopg
        except ImportError as exc:
            raise DatabaseUnavailable("O controlador PostgreSQL não está instalado.") from exc
        try:
            return psycopg.connect(self.dsn)
        except Exception as exc:
            raise DatabaseUnavailable("A base de dados do Apoio está indisponível.") from exc

    @contextmanager
    def transaction(self, context: RequestContext) -> Iterator[Any]:
        connection = self._open()
        cursor = None
        try:
            cursor = connection.cursor()
            settings = (
                ("app.owner_org_id", str(context.owner_org_id)),
                ("app.application_id", context.application_id),
                ("app.installation_id", str(context.installation_id)),
                ("app.environment_id", context.environment_id),
                ("app.environment_kind", context.environment_kind),
                ("app.data_tenant_id", str(context.data_tenant_id)),
                ("app.actor_id", str(context.actor_id)),
                ("app.actor_kind", context.actor_kind),
                ("app.policy_revision", context.policy_revision),
                ("app.correlation_id", context.correlation_id),
            )
            for name, value in settings:
                cursor.execute("SELECT set_config(%s, %s, true)", (name, value))
            yield cursor
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            if cursor is not None:
                cursor.close()
            connection.close()
