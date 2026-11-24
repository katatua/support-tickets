"""Deterministic support ticket rules; persistence and identity are injected separately."""
from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import datetime
from enum import StrEnum
from hashlib import sha256
import json
from typing import Any, Iterable, Mapping
from uuid import UUID


class DomainError(Exception):
    code = "DOMAIN_ERROR"
    status_code = 400

    def __init__(self, message: str):
        super().__init__(message)
        self.message = message


class NotFound(DomainError):
    code = "NOT_FOUND"
    status_code = 404


class Forbidden(DomainError):
    code = "FORBIDDEN"
    status_code = 403


class Conflict(DomainError):
    code = "CONFLICT"
    status_code = 409


class PreconditionFailed(DomainError):
    code = "VERSION_CONFLICT"
    status_code = 412


class ValidationError(DomainError):
    code = "VALIDATION_ERROR"
    status_code = 422


class ActorKind(StrEnum):
    USER = "user"
    SERVICE = "service"


class Role(StrEnum):
    PLATFORM_ADMIN = "platform_admin"
    COORDINATOR = "coordinator"
    AGENT = "agent"
    CUSTOMER_ADMIN = "customer_admin"
    CUSTOMER_MEMBER = "customer_member"
    AUDITOR = "auditor"


class TicketStatus(StrEnum):
    NEW = "new"
    TRIAGED = "triaged"
    IN_PROGRESS = "in_progress"
    WAITING_CUSTOMER = "waiting_customer"
    RESOLVED = "resolved"
    CLOSED = "closed"
    CANCELLED = "cancelled"


class Priority(StrEnum):
    LOW = "low"
    NORMAL = "normal"
    HIGH = "high"
    URGENT = "urgent"


class Visibility(StrEnum):
    REQUESTER = "requester"
    ACCOUNT = "account"


class MessageKind(StrEnum):
    PUBLIC = "public"
    INTERNAL = "internal"


class ScanState(StrEnum):
    PENDING = "pending"
    CLEAN = "clean"
    REJECTED = "rejected"


class TransitionAction(StrEnum):
    TRIAGE = "triage"
    START = "start"
    ASK_CUSTOMER = "ask_customer"
    CUSTOMER_REPLY = "customer_reply"
    RESOLVE = "resolve"
    CONFIRM = "confirm"
    REOPEN = "reopen"
    CANCEL = "cancel"


@dataclass(frozen=True)
class ActorContext:
    """App ACL snapshot loaded by the server for one authenticated actor."""
    tenant_id: UUID
    actor_id: UUID
    actor_kind: ActorKind
    roles: frozenset[Role]
    account_ids: frozenset[UUID] = frozenset()
    team_ids: frozenset[UUID] = frozenset()
    active: bool = True


@dataclass(frozen=True)
class Ticket:
    id: UUID
    tenant_id: UUID
    account_id: UUID
    requester_id: UUID
    subject: str
    status: TicketStatus
    priority: Priority
    visibility: Visibility
    team_id: UUID | None
    assignee_id: UUID | None
    row_version: int
    updated_at: datetime
    category_id: UUID | None = None
    resolution_summary: str | None = None


@dataclass(frozen=True)
class Message:
    id: UUID
    tenant_id: UUID
    ticket_id: UUID
    author_id: UUID
    kind: MessageKind
    body: str
    client_message_id: UUID
    created_at: datetime


@dataclass(frozen=True)
class AttachmentRef:
    id: UUID
    tenant_id: UUID
    application_id: str
    environment_id: UUID
    owner_id: UUID
    scan_state: ScanState
    linked_message_id: UUID | None = None


@dataclass(frozen=True)
class TicketPage:
    items: tuple[Ticket, ...]
    next_cursor: tuple[datetime, UUID] | None
    has_more: bool


@dataclass(frozen=True)
class PublicMessageSurface:
    id: UUID
    body: str
    created_at: datetime


@dataclass(frozen=True)
class TicketSurface:
    """Safe ticket projection for customer search, export and assistant tools."""
    id: UUID
    subject: str
    status: TicketStatus
    priority: Priority
    updated_at: datetime
    messages: tuple[PublicMessageSurface, ...]


@dataclass(frozen=True)
class ChangeApproval:
    revision: int
    digest: str


def ticket_is_visible(actor: ActorContext, ticket: Ticket) -> bool:
    """Return only object-level access; callers use NOT_FOUND for all denials."""
    if not actor.active or actor.actor_kind is not ActorKind.USER:
        return False
    if actor.tenant_id != ticket.tenant_id:
        return False
    if actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR}:
        return True
    if Role.AGENT in actor.roles:
        return ticket.team_id in actor.team_ids
    if ticket.requester_id == actor.actor_id:
        return ticket.account_id in actor.account_ids
    return (
        ticket.visibility is Visibility.ACCOUNT
        and ticket.account_id in actor.account_ids
        and bool(actor.roles & {Role.CUSTOMER_ADMIN, Role.CUSTOMER_MEMBER})
    )


def require_visible_ticket(actor: ActorContext, ticket: Ticket) -> Ticket:
    if not ticket_is_visible(actor, ticket):
        raise NotFound("Ticket not found.")
    return ticket


def visible_messages(actor: ActorContext, ticket: Ticket, messages: Iterable[Message]) -> tuple[Message, ...]:
    require_visible_ticket(actor, ticket)
    if Role.AGENT in actor.roles or actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR}:
        return tuple(
            message for message in messages
            if message.ticket_id == ticket.id and message.tenant_id == ticket.tenant_id
        )
    return tuple(
        message for message in messages
        if message.ticket_id == ticket.id and message.tenant_id == ticket.tenant_id
        and message.kind is MessageKind.PUBLIC
    )


def customer_ticket_surface(
    actor: ActorContext, ticket: Ticket, messages: Iterable[Message]
) -> TicketSurface:
    """Build a customer-safe view. Internal notes are omitted even for staff callers."""
    require_visible_ticket(actor, ticket)
    public_messages = tuple(
        PublicMessageSurface(
            id=message.id,
            body=message.body,
            created_at=message.created_at,
        )
        for message in visible_messages(actor, ticket, messages)
        if message.kind is MessageKind.PUBLIC
    )
    return TicketSurface(
        id=ticket.id,
        subject=ticket.subject,
        status=ticket.status,
        priority=ticket.priority,
        updated_at=ticket.updated_at,
        messages=public_messages,
    )


def authorized_search(
    tickets: Iterable[Ticket],
    messages: Iterable[Message],
    *,
    actor: ActorContext,
    query: str,
    limit: int = 25,
) -> tuple[TicketSurface, ...]:
    """Search only authorized tickets and public content, without a hidden total."""
    if not 1 <= limit <= 100:
        raise ValidationError("limit must be between 1 and 100.")
    normalized = query.strip().casefold()
    if not 1 <= len(normalized) <= 200:
        raise ValidationError("Search query must contain 1 to 200 characters.")
    message_list = tuple(messages)
    results: list[TicketSurface] = []
    for ticket in tickets:
        if not ticket_is_visible(actor, ticket):
            continue
        surface = customer_ticket_surface(actor, ticket, message_list)
        if normalized in surface.subject.casefold() or any(
            normalized in message.body.casefold() for message in surface.messages
        ):
            results.append(surface)
    results.sort(key=lambda item: (item.updated_at, item.id), reverse=True)
    return tuple(results[:limit])


def assistant_ticket_context(
    actor: ActorContext, ticket: Ticket, messages: Iterable[Message]
) -> TicketSurface:
    """Give typed assistant tools only public conversation context."""
    return customer_ticket_surface(actor, ticket, messages)


def notification_payload(
    *, ticket: Ticket, recipient_actor_id: UUID, event: str
) -> Mapping[str, str | int]:
    """Return metadata only; message text and internal note content never leave here."""
    if event not in {"ticket_created", "public_reply", "status_changed", "assigned"}:
        raise ValidationError("Unsupported notification event.")
    return {
        "ticket_id": str(ticket.id),
        "recipient_actor_id": str(recipient_actor_id),
        "event": event,
        "row_version": ticket.row_version,
    }


def validate_new_ticket(subject: str, body: str) -> None:
    if not 5 <= len(subject.strip()) <= 180:
        raise ValidationError("Subject must contain 5 to 180 characters.")
    if not 10 <= len(body.strip()) <= 20_000:
        raise ValidationError("Description must contain 10 to 20,000 characters.")


def assert_expected_version(ticket: Ticket, expected_version: int) -> None:
    if expected_version < 1 or ticket.row_version != expected_version:
        raise PreconditionFailed("The ticket changed. Reload it and review the latest version.")


def assign_ticket(
    ticket: Ticket,
    *,
    actor: ActorContext,
    expected_version: int,
    team_id: UUID,
    assignee_id: UUID,
    active_team_members: Mapping[UUID, frozenset[UUID]],
    updated_at: datetime,
) -> Ticket:
    require_visible_ticket(actor, ticket)
    assert_expected_version(ticket, expected_version)
    can_assign = bool(actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR})
    can_take_self = (
        Role.AGENT in actor.roles
        and assignee_id == actor.actor_id
        and ticket.assignee_id in {None, actor.actor_id}
    )
    if not (can_assign or can_take_self):
        raise Forbidden("You cannot assign this ticket.")
    members = active_team_members.get(team_id, frozenset())
    if assignee_id not in members:
        raise ValidationError("The assignee must be an active member of the selected team.")
    if can_take_self and team_id not in actor.team_ids:
        raise Forbidden("You cannot take a ticket from this team.")
    return replace(
        ticket,
        team_id=team_id,
        assignee_id=assignee_id,
        row_version=ticket.row_version + 1,
        updated_at=updated_at,
    )


def triage_ticket(
    ticket: Ticket,
    *,
    actor: ActorContext,
    expected_version: int,
    category_id: UUID,
    category_active: bool,
    priority: Priority,
    updated_at: datetime,
) -> Ticket:
    require_visible_ticket(actor, ticket)
    assert_expected_version(ticket, expected_version)
    if not actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR}:
        raise Forbidden("Only a coordinator can triage tickets.")
    if ticket.status is not TicketStatus.NEW:
        raise Conflict("Only a new ticket can be triaged.")
    if not category_active:
        raise ValidationError("The selected category is inactive.")
    return replace(
        ticket,
        status=TicketStatus.TRIAGED,
        category_id=category_id,
        priority=priority,
        row_version=ticket.row_version + 1,
        updated_at=updated_at,
    )


def transition_ticket(
    ticket: Ticket,
    *,
    actor: ActorContext,
    action: TransitionAction,
    expected_version: int,
    updated_at: datetime,
    actor_is_active_team_member: bool = False,
    public_question_persisted: bool = False,
    resolution_summary: str | None = None,
    reason: str | None = None,
) -> Ticket:
    require_visible_ticket(actor, ticket)
    assert_expected_version(ticket, expected_version)
    staff = bool(actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR, Role.AGENT})
    customer = bool(actor.roles & {Role.CUSTOMER_ADMIN, Role.CUSTOMER_MEMBER})
    new_status: TicketStatus

    if action is TransitionAction.START:
        if ticket.status is not TicketStatus.TRIAGED or not staff:
            raise Conflict("Only a triaged ticket can be started by the support team.")
        if ticket.assignee_id is None or not actor_is_active_team_member:
            raise ValidationError("An active assignee is required before work starts.")
        if ticket.assignee_id != actor.actor_id and Role.COORDINATOR not in actor.roles and Role.PLATFORM_ADMIN not in actor.roles:
            raise Forbidden("Only the assignee or a coordinator can start this ticket.")
        new_status = TicketStatus.IN_PROGRESS
    elif action is TransitionAction.ASK_CUSTOMER:
        if ticket.status is not TicketStatus.IN_PROGRESS or not staff:
            raise Conflict("Only an in-progress ticket can wait for the customer.")
        if ticket.assignee_id != actor.actor_id or not actor_is_active_team_member:
            raise Forbidden("Only the active assignee can ask the customer.")
        if not public_question_persisted:
            raise ValidationError("A public question must be persisted before waiting for the customer.")
        new_status = TicketStatus.WAITING_CUSTOMER
    elif action is TransitionAction.CUSTOMER_REPLY:
        if ticket.status is not TicketStatus.WAITING_CUSTOMER or not customer:
            raise Conflict("This ticket is not waiting for an authorized customer reply.")
        new_status = TicketStatus.IN_PROGRESS
    elif action is TransitionAction.RESOLVE:
        if ticket.status is not TicketStatus.IN_PROGRESS or not staff:
            raise Conflict("Only an in-progress ticket can be resolved by support.")
        if ticket.assignee_id is None or not actor_is_active_team_member:
            raise ValidationError("An active assignee is required to resolve this ticket.")
        if ticket.assignee_id != actor.actor_id and Role.COORDINATOR not in actor.roles and Role.PLATFORM_ADMIN not in actor.roles:
            raise Forbidden("Only the assignee or a coordinator can resolve this ticket.")
        if len((resolution_summary or "").strip()) < 10:
            raise ValidationError("A resolution summary of at least 10 characters is required.")
        new_status = TicketStatus.RESOLVED
    elif action is TransitionAction.CONFIRM:
        if ticket.status is not TicketStatus.RESOLVED or not customer:
            raise Conflict("Only an authorized customer can confirm a resolved ticket.")
        new_status = TicketStatus.CLOSED
    elif action is TransitionAction.REOPEN:
        if ticket.status not in {TicketStatus.RESOLVED, TicketStatus.CLOSED}:
            raise Conflict("Only a resolved or closed ticket can be reopened.")
        if not reason or len(reason.strip()) < 5:
            raise ValidationError("A reason is required to reopen a ticket.")
        if not (customer or staff):
            raise Forbidden("You cannot reopen this ticket.")
        new_status = TicketStatus.IN_PROGRESS
    elif action is TransitionAction.CANCEL:
        if ticket.status in {TicketStatus.CLOSED, TicketStatus.CANCELLED}:
            raise Conflict("A final ticket cannot be cancelled.")
        if not actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR}:
            raise Forbidden("Only a coordinator can cancel this ticket.")
        if not reason or len(reason.strip()) < 5:
            raise ValidationError("A reason is required to cancel a ticket.")
        new_status = TicketStatus.CANCELLED
    elif action is TransitionAction.TRIAGE:
        if ticket.status is not TicketStatus.NEW or not actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR}:
            raise Conflict("The ticket cannot be triaged in its current state.")
        new_status = TicketStatus.TRIAGED
    else:
        raise ValidationError("Unsupported ticket transition.")

    summary = resolution_summary.strip() if action is TransitionAction.RESOLVE and resolution_summary else ticket.resolution_summary
    return replace(
        ticket,
        status=new_status,
        resolution_summary=summary,
        row_version=ticket.row_version + 1,
        updated_at=updated_at,
    )


def validate_attachment_for_publish(
    *,
    actor: ActorContext,
    ticket: Ticket,
    attachment: AttachmentRef,
    application_id: str,
    environment_id: UUID,
) -> None:
    require_visible_ticket(actor, ticket)
    if attachment.tenant_id != ticket.tenant_id or attachment.tenant_id != actor.tenant_id:
        raise NotFound("Attachment not found.")
    if attachment.application_id != application_id or attachment.environment_id != environment_id:
        raise NotFound("Attachment not found.")
    if attachment.owner_id != actor.actor_id:
        raise NotFound("Attachment not found.")
    if attachment.linked_message_id is not None:
        raise Conflict("This attachment has already been published.")
    if attachment.scan_state is not ScanState.CLEAN:
        raise ValidationError("Only a validated attachment can be published.")
    if not actor.roles & {Role.AGENT, Role.PLATFORM_ADMIN, Role.COORDINATOR,
                          Role.CUSTOMER_ADMIN, Role.CUSTOMER_MEMBER}:
        raise Forbidden("You cannot publish an attachment to this ticket.")


def canonical_payload_digest(payload: Any) -> str:
    canonical = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str)
    return sha256(canonical.encode("utf-8")).hexdigest()


def check_idempotent_replay(*, saved_digest: str, incoming_payload: Any) -> bool:
    """True means replay the saved receipt; mismatch fails without mutation."""
    if saved_digest != canonical_payload_digest(incoming_payload):
        raise Conflict("IDEMPOTENCY_CONFLICT: the same key was used with different content.")
    return True


def can_submit_change(
    *,
    current_revision: int,
    current_digest: str,
    approved: ChangeApproval | None,
) -> bool:
    """Submission requires an approval for the exact current immutable revision."""
    return bool(
        approved
        and approved.revision == current_revision
        and approved.digest == current_digest
    )


def delivery_label(*, raw_status: str, evidence: Mapping[str, Any] | None = None) -> str:
    """Project external evidence without treating executor claims as publication."""
    if raw_status == "CLAIMED_DONE":
        return "A aguardar confirmação"
    proof = evidence or {}
    if (
        raw_status == "verified_production"
        and proof.get("app_id") == "apoio"
        and proof.get("environment_kind") == "production"
        and bool(proof.get("candidate_digest"))
        and bool(proof.get("runtime_readback"))
    ):
        return "Disponível em produção"
    if raw_status in {"admitted", "running", "waiting_decision", "candidate_available", "verified_test"}:
        return "Em acompanhamento"
    return "Por confirmar"


def authorized_page(
    tickets: Iterable[Ticket],
    *,
    actor: ActorContext,
    limit: int = 25,
    after: tuple[datetime, UUID] | None = None,
) -> TicketPage:
    """Filter ACL before paging, sorting, counts or cursors."""
    if not 1 <= limit <= 100:
        raise ValidationError("limit must be between 1 and 100.")
    visible = [ticket for ticket in tickets if ticket_is_visible(actor, ticket)]
    visible.sort(key=lambda ticket: (ticket.updated_at, ticket.id), reverse=True)
    if after is not None:
        visible = [ticket for ticket in visible if (ticket.updated_at, ticket.id) < after]
    selected = visible[: limit + 1]
    has_more = len(selected) > limit
    items = tuple(selected[:limit])
    next_cursor = (items[-1].updated_at, items[-1].id) if has_more and items else None
    return TicketPage(items=items, next_cursor=next_cursor, has_more=has_more)

