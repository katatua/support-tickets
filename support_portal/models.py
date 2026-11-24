"""Strict request/response models for the Apoio HTTP surface."""
from __future__ import annotations

from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .context import validate_opaque_identifier


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class VisibilityInput(StrEnum):
    REQUESTER = "requester"
    ACCOUNT = "account"


class MessageKindInput(StrEnum):
    PUBLIC = "public"
    INTERNAL = "internal"


class TransitionActionInput(StrEnum):
    START = "start"
    ASK_CUSTOMER = "ask_customer"
    CUSTOMER_REPLY = "customer_reply"
    RESOLVE = "resolve"
    CONFIRM = "confirm"
    REOPEN = "reopen"
    CANCEL = "cancel"


class PriorityInput(StrEnum):
    LOW = "low"
    NORMAL = "normal"
    HIGH = "high"
    URGENT = "urgent"


class ChangeRequestInput(StrictModel):
    text: str = Field(min_length=1, max_length=12_000)


class CreateTicketInput(StrictModel):
    account_id: UUID
    subject: str = Field(min_length=5, max_length=180)
    body: str = Field(min_length=10, max_length=20_000)
    visibility: VisibilityInput = VisibilityInput.REQUESTER
    category_id: UUID | None = None


class SaveDraftInput(StrictModel):
    body: str = Field(min_length=1, max_length=20_000)
    kind: MessageKindInput = MessageKindInput.PUBLIC
    expected_ticket_version: int = Field(ge=1)
    client_message_id: UUID


class UpdateDraftInput(StrictModel):
    body: str = Field(min_length=1, max_length=20_000)
    expected_ticket_version: int = Field(ge=1)
    expected_draft_version: int = Field(ge=1)


class PublishDraftInput(StrictModel):
    expected_ticket_version: int = Field(ge=1)
    expected_draft_version: int = Field(ge=1)


class AssignTicketInput(StrictModel):
    expected_version: int = Field(ge=1)
    team_id: UUID
    assignee_id: str

    @field_validator("assignee_id", mode="before")
    @classmethod
    def validate_assignee_identifier(cls, value: object) -> str:
        return validate_opaque_identifier(value)


class TriageTicketInput(StrictModel):
    expected_version: int = Field(ge=1)
    category_id: UUID
    priority: PriorityInput


class TransitionTicketInput(StrictModel):
    expected_version: int = Field(ge=1)
    action: TransitionActionInput
    reason: str | None = Field(default=None, max_length=2_000)
    resolution_summary: str | None = Field(default=None, max_length=20_000)


class AssistantReadTicketInput(StrictModel):
    ticket_id: UUID


class AssistantSearchInput(StrictModel):
    query: str = Field(min_length=1, max_length=200)
    limit: int = Field(default=10, ge=1, le=100)
