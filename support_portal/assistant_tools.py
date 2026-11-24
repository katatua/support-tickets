"""Typed read-only tools for a contextual assistant; no model dependency is required."""
from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field
from uuid import UUID

from .context import RequestContext


class ReadTicketArgs(BaseModel):
    model_config = ConfigDict(extra="forbid")
    ticket_id: UUID


class SearchTicketsArgs(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    query: str = Field(min_length=1, max_length=200)
    limit: int = Field(default=10, ge=1, le=50)


TOOL_DEFINITIONS: tuple[dict[str, Any], ...] = (
    {
        "name": "read_ticket",
        "description": "Lê um pedido autorizado e apenas as mensagens públicas.",
        "input_schema": {"type": "object", "properties": {"ticket_id": {"type": "string", "format": "uuid"}}, "required": ["ticket_id"], "additionalProperties": False},
    },
    {
        "name": "search_tickets",
        "description": "Pesquisa pedidos autorizados e texto público, sem revelar contagens ocultas.",
        "input_schema": {"type": "object", "properties": {"query": {"type": "string", "minLength": 1, "maxLength": 200}, "limit": {"type": "integer", "minimum": 1, "maximum": 50}}, "required": ["query"], "additionalProperties": False},
    },
)


class AssistantTools:
    """Dispatch only named, typed, read-only tools against the authorized store."""

    def __init__(self, store: Any):
        self.store = store

    def execute(self, context: RequestContext, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "read_ticket":
            args = ReadTicketArgs.model_validate(arguments)
            return self.store.assistant_read(context, args.ticket_id)
        if name == "search_tickets":
            args = SearchTicketsArgs.model_validate(arguments)
            return self.store.list_tickets(context, query=args.query, limit=args.limit)
        raise ValueError("Unknown assistant tool.")
