"""Fail-closed adapter for the authenticated Sovharn request context.

The app never reads tenant, actor, installation or environment from client headers
or request bodies. A trusted D0 middleware must attach the resolved context to
request.state.sovharn_context before app routes can operate.

The draft source ref is pinned in d0-contract.lock.json. This local adapter is not
runtime compatibility evidence until that exact contract is published and consumed.
"""
from __future__ import annotations

from dataclasses import dataclass
from collections.abc import Mapping
from typing import Any
from uuid import UUID


class ContextUnavailable(RuntimeError):
    """The verified D0 request context is missing or does not match this app."""


@dataclass(frozen=True)
class RequestContext:
    owner_org_id: UUID
    application_id: str
    installation_id: UUID
    environment_id: UUID
    environment_kind: str
    data_tenant_id: UUID
    actor_id: UUID
    actor_kind: str
    delegation_ref: str | None
    policy_revision: str
    correlation_id: UUID

    @classmethod
    def from_trusted_state(cls, state: Any) -> "RequestContext":
        """Parse only the object installed by trusted server middleware."""
        raw = getattr(state, "sovharn_context", None)
        if not isinstance(raw, Mapping):
            raise ContextUnavailable("Authenticated Sovharn context is unavailable.")

        required = {
            "owner_org_id", "application_id", "installation_id", "environment_id",
            "environment_kind", "data_tenant_id", "actor_id", "actor_kind",
            "delegation_ref", "policy_revision", "correlation_id",
        }
        if set(raw.keys()) != required:
            raise ContextUnavailable("Authenticated Sovharn context has an unsupported schema.")

        try:
            context = cls(
                owner_org_id=UUID(str(raw["owner_org_id"])),
                application_id=_required_text(raw["application_id"]),
                installation_id=UUID(str(raw["installation_id"])),
                environment_id=UUID(str(raw["environment_id"])),
                environment_kind=_required_text(raw["environment_kind"]),
                data_tenant_id=UUID(str(raw["data_tenant_id"])),
                actor_id=UUID(str(raw["actor_id"])),
                actor_kind=_required_text(raw["actor_kind"]),
                delegation_ref=_optional_text(raw["delegation_ref"]),
                policy_revision=_required_text(raw["policy_revision"]),
                correlation_id=UUID(str(raw["correlation_id"])),
            )
        except (ValueError, TypeError, AttributeError) as exc:
            raise ContextUnavailable("Authenticated Sovharn context is malformed.") from exc

        if context.environment_kind not in {"test", "production"}:
            raise ContextUnavailable("Unsupported installation environment.")
        if context.actor_kind not in {"user", "service"}:
            raise ContextUnavailable("Unsupported actor kind.")
        return context

    def assert_binding(
        self,
        *,
        application_id: str,
        installation_id: UUID,
        environment_id: UUID,
        environment_kind: str,
    ) -> None:
        """Ensure the trusted context belongs to this exact app installation."""
        if (
            self.application_id != application_id
            or self.installation_id != installation_id
            or self.environment_id != environment_id
            or self.environment_kind != environment_kind
        ):
            raise ContextUnavailable("Request context is outside this app installation.")


def _required_text(value: object) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("required text")
    return value


def _optional_text(value: object) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise ValueError("optional text")
    return value

