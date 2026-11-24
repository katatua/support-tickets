"""Structural types for the pinned D0 SH Connect request port.

The implementation is injected by the host. No HTTP adapter, credential handling,
or approval operation is implemented in this package.
"""
from __future__ import annotations

from typing import Protocol, TypedDict


class ChangeRequestReadback(TypedDict):
    id: str
    body: str
    revision: int
    content_hash: str
    state: str


class ShConnectChangeRequestPort(Protocol):
    def propose_change_request(
        self, *, installation_id: str, text: str, idempotency_key: str
    ) -> ChangeRequestReadback: ...

    def read_change_request(
        self, *, installation_id: str, request_id: str
    ) -> ChangeRequestReadback: ...
