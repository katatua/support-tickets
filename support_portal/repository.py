"""Persistent Apoio service. PostgreSQL RLS remains the final object boundary."""
from __future__ import annotations

from datetime import datetime
from hashlib import sha256
import json
from typing import Any
from uuid import UUID, uuid4

from .context import RequestContext
from .database import PostgresDatabase
from .domain import (
    ActorContext, ActorKind, ChangeApproval, Conflict, Forbidden, Message,
    MessageKind, NotFound, Priority, PreconditionFailed, Role, ScanState,
    Ticket, TicketStatus, TransitionAction, ValidationError, Visibility,
    assign_ticket, assert_expected_version, authorized_page,
    can_submit_change, canonical_payload_digest, check_idempotent_replay,
    customer_export_surface,
    require_visible_ticket, transition_ticket, triage_ticket, validate_new_ticket,
    visible_messages,
)


class RateLimited(ValidationError):
    code = "INTAKE_RATE_LIMITED"
    status_code = 429


def _dict(cursor: Any, row: Any) -> dict[str, Any] | None:
    if row is None:
        return None
    names = [column.name if hasattr(column, "name") else column[0] for column in cursor.description]
    if isinstance(row, dict):
        return row
    return dict(zip(names, row))


def _ticket(row: dict[str, Any]) -> Ticket:
    return Ticket(
        id=row["id"], tenant_id=row["tenant_id"], account_id=row["account_id"],
        requester_id=row["requester_id"], subject=row["subject"],
        status=TicketStatus(row["status"]), priority=Priority(row["priority"]),
        visibility=Visibility(row["visibility"]), team_id=row["team_id"],
        assignee_id=row["assignee_id"], row_version=int(row["row_version"]),
        updated_at=row["updated_at"], category_id=row["category_id"],
        resolution_summary=row["resolution_summary"],
    )


def _actor(cursor: Any, context: RequestContext) -> ActorContext:
    if context.actor_kind != ActorKind.USER.value:
        return ActorContext(
            tenant_id=context.data_tenant_id,
            actor_id=context.actor_id,
            actor_kind=ActorKind(context.actor_kind),
            roles=frozenset(),
            active=False,
        )

    roles: set[Role] = set()
    accounts: set[UUID] = set()
    teams: set[UUID] = set()
    cursor.execute(
        "SELECT account_id, role FROM support_portal.account_member "
        "WHERE tenant_id=%s AND actor_id=%s AND active",
        (context.data_tenant_id, context.actor_id),
    )
    for account_id, role in cursor.fetchall():
        accounts.add(account_id)
        roles.add(Role(role))

    cursor.execute(
        "SELECT role FROM support_portal.staff_membership "
        "WHERE tenant_id=%s AND actor_id=%s AND active",
        (context.data_tenant_id, context.actor_id),
    )
    for (role,) in cursor.fetchall():
        roles.add(Role(role))

    cursor.execute(
        "SELECT team_id, role FROM support_portal.team_member "
        "WHERE tenant_id=%s AND actor_id=%s AND active",
        (context.data_tenant_id, context.actor_id),
    )
    for team_id, role in cursor.fetchall():
        teams.add(team_id)
        roles.add(Role(role))

    return ActorContext(
        tenant_id=context.data_tenant_id,
        actor_id=context.actor_id,
        actor_kind=ActorKind.USER,
        roles=frozenset(roles),
        account_ids=frozenset(accounts),
        team_ids=frozenset(teams),
        active=bool(roles),
    )


def _as_json(value: Any) -> Any:
    if isinstance(value, (dict, list)):
        return value
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


class PostgresSupportStore:
    """Use a configured PostgreSQL database; no in-memory production fallback exists."""

    def __init__(self, database: PostgresDatabase | None = None):
        self.database = database or PostgresDatabase()

    def me(self, context: RequestContext) -> dict[str, Any]:
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            accounts: list[dict[str, str]] = []
            teams: list[dict[str, Any]] = []
            categories: list[dict[str, Any]] = []
            if actor.active:
                cursor.execute(
                    "SELECT id, name FROM support_portal.customer_account WHERE active ORDER BY name"
                )
                accounts = [{"id": str(row[0]), "name": row[1]} for row in cursor.fetchall()]
                cursor.execute(
                    "SELECT id, name FROM support_portal.category WHERE tenant_id=%s AND active ORDER BY name",
                    (context.data_tenant_id,),
                )
                categories = [{"id": str(row[0]), "name": row[1]} for row in cursor.fetchall()]
                if actor.roles & {Role.AGENT, Role.COORDINATOR, Role.PLATFORM_ADMIN}:
                    cursor.execute(
                        "SELECT id, name FROM support_portal.support_team WHERE tenant_id=%s AND active ORDER BY name",
                        (context.data_tenant_id,),
                    )
                    for team_id, team_name in cursor.fetchall():
                        cursor.execute(
                            """SELECT actor_id, role FROM support_portal.team_member
                               WHERE tenant_id=%s AND team_id=%s AND active ORDER BY actor_id""",
                            (context.data_tenant_id, team_id),
                        )
                        members = [{"actor_id": str(row[0]), "role": str(row[1])} for row in cursor.fetchall()]
                        teams.append({"id": str(team_id), "name": team_name, "members": members})
        return {
            "context": {
                "owner_org_id": str(context.owner_org_id),
                "application_id": context.application_id,
                "installation_id": str(context.installation_id),
                "environment_id": str(context.environment_id),
                "environment_kind": context.environment_kind,
                "data_tenant_id": str(context.data_tenant_id),
                "actor_id": str(context.actor_id),
                "actor_kind": context.actor_kind,
                "policy_revision": context.policy_revision,
                "correlation_id": str(context.correlation_id),
            },
            "capabilities": sorted(role.value for role in actor.roles),
            "account_ids": sorted(str(value) for value in actor.account_ids),
            "accounts": accounts,
            "categories": categories,
            "teams": teams,
        }

    def list_tickets(
        self,
        context: RequestContext,
        *,
        limit: int = 25,
        after: tuple[datetime, UUID] | None = None,
        query: str | None = None,
    ) -> dict[str, Any]:
        if not 1 <= limit <= 100:
            raise ValidationError("A página deve ter entre 1 e 100 pedidos.")
        normalized_query = query.strip() if query else ""
        if len(normalized_query) > 200:
            raise ValidationError("A pesquisa não pode exceder 200 caracteres.")
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            if not actor.active:
                return {"items": [], "next_cursor": None, "has_more": False}
            cursor.execute(
                """SELECT t.id, t.tenant_id, t.account_id, t.requester_id, t.subject,
                          t.status, t.priority, t.visibility, t.team_id, t.assignee_id,
                          t.row_version, t.updated_at, t.category_id, t.resolution_summary
                   FROM support_portal.ticket t
                   WHERE (%s::timestamptz IS NULL OR (t.updated_at, t.id) < (%s, %s))
                     AND (%s = '' OR t.subject ILIKE %s OR EXISTS (
                       SELECT 1 FROM support_portal.ticket_message m
                       WHERE m.ticket_id=t.id AND m.tenant_id=t.tenant_id
                         AND m.kind='public' AND m.body ILIKE %s
                     ))
                   ORDER BY t.updated_at DESC, t.id DESC LIMIT %s""",
                (
                    after[0] if after else None,
                    after[0] if after else None,
                    after[1] if after else None,
                    normalized_query,
                    f"%{normalized_query}%",
                    f"%{normalized_query}%",
                    limit + 1,
                ),
            )
            rows = [_dict(cursor, row) for row in cursor.fetchall()]
            rows = [row for row in rows if row is not None]
            page = authorized_page((_ticket(row) for row in rows), actor=actor, limit=limit, after=after)
        lookup = {item["id"]: item for item in rows}
        return {
            "items": [self._ticket_summary(lookup[item.id]) for item in page.items],
            "next_cursor": self._encode_cursor(page.next_cursor),
            "has_more": page.has_more,
        }

    def get_ticket(self, context: RequestContext, ticket_id: UUID, *, public_only: bool = False) -> dict[str, Any]:
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            record = self._load_ticket(cursor, ticket_id)
            if record is None:
                raise NotFound("Pedido não encontrado.")
            model = _ticket(record)
            require_visible_ticket(actor, model)
            cursor.execute(
                """SELECT id, tenant_id, ticket_id, author_id, kind, body, client_message_id, created_at
                   FROM support_portal.ticket_message WHERE ticket_id=%s ORDER BY created_at, id""",
                (ticket_id,),
            )
            messages = [
                Message(
                    id=row[0], tenant_id=row[1], ticket_id=row[2], author_id=row[3],
                    kind=MessageKind(row[4]), body=row[5], client_message_id=row[6], created_at=row[7],
                )
                for row in cursor.fetchall()
            ]
            visible = visible_messages(actor, model, messages)
            if public_only:
                surface = customer_export_surface(actor, model, visible)
                message_values = [
                    {"id": str(message.id), "body": message.body, "created_at": message.created_at.isoformat()}
                    for message in surface.messages
                ]
            else:
                message_values = [
                    {
                        "id": str(message.id), "kind": message.kind.value,
                        "body": message.body, "created_at": message.created_at.isoformat(),
                    }
                    for message in visible
                ]
            draft_values: list[dict[str, Any]] = []
            if not public_only:
                cursor.execute(
                    """SELECT id, kind, body, client_message_id, draft_version, updated_at, published_message_id
                       FROM support_portal.ticket_message_draft
                       WHERE ticket_id=%s AND author_id=%s ORDER BY updated_at DESC""",
                    (ticket_id, context.actor_id),
                )
                draft_values = [
                    {
                        "id": str(row[0]), "kind": str(row[1]), "body": row[2],
                        "client_message_id": str(row[3]), "version": int(row[4]),
                        "updated_at": row[5].isoformat(), "published_message_id": str(row[6]) if row[6] else None,
                    }
                    for row in cursor.fetchall()
                ]
            response = self._ticket_summary(record)
            response["messages"] = message_values
            response["drafts"] = draft_values
            response["can_reply"] = self._can_reply(actor, model)
            response["can_add_internal_note"] = self._can_add_note(actor, model)
            return response

    def create_ticket(
        self,
        context: RequestContext,
        *,
        account_id: UUID,
        subject: str,
        body: str,
        visibility: Visibility,
        idempotency_key: str,
        category_id: UUID | None = None,
    ) -> dict[str, Any]:
        validate_new_ticket(subject, body)
        if not idempotency_key or len(idempotency_key) > 160:
            raise ValidationError("É necessária uma chave de idempotência válida.")
        payload = {
            "operation": "create_ticket", "account_id": account_id,
            "subject": subject.strip(), "body": body.strip(),
            "visibility": visibility.value, "category_id": category_id,
        }
        digest = canonical_payload_digest(payload)
        limited = False
        response: dict[str, Any] | None = None
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            if not actor.active or account_id not in actor.account_ids or not actor.roles & {Role.CUSTOMER_ADMIN, Role.CUSTOMER_MEMBER}:
                raise NotFound("A conta não está disponível.")
            receipt = self._receipt(cursor, context, "create_ticket", idempotency_key, digest)
            if receipt is not None:
                return receipt
            cursor.execute(
                """INSERT INTO support_portal.ticket_intake_limit
                     (owner_org_id, application_id, installation_id, environment_id, tenant_id,
                      actor_id, window_started_at, ticket_count)
                   VALUES (%s,%s,%s,%s,%s,%s,clock_timestamp(),1)
                   ON CONFLICT (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, actor_id) DO UPDATE SET
                     window_started_at = CASE
                       WHEN support_portal.ticket_intake_limit.window_started_at < clock_timestamp() - interval '10 minutes'
                       THEN clock_timestamp() ELSE support_portal.ticket_intake_limit.window_started_at END,
                     ticket_count = CASE
                       WHEN support_portal.ticket_intake_limit.window_started_at < clock_timestamp() - interval '10 minutes'
                       THEN 1 ELSE support_portal.ticket_intake_limit.ticket_count + 1 END,
                     updated_at=clock_timestamp()
                   RETURNING ticket_count""",
                (
                    context.owner_org_id, context.application_id, context.installation_id,
                    context.environment_id, context.data_tenant_id, context.actor_id,
                ),
            )
            limited = int(cursor.fetchone()[0]) > 5
            if not limited:
                if category_id is not None:
                    cursor.execute(
                        "SELECT id FROM support_portal.category WHERE id=%s AND tenant_id=%s AND active",
                        (category_id, context.data_tenant_id),
                    )
                    if cursor.fetchone() is None:
                        raise ValidationError("A categoria selecionada não está disponível.")
                ticket_id = uuid4()
                cursor.execute(
                    """INSERT INTO support_portal.ticket
                         (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                          account_id, requester_id, subject, status, priority, visibility, category_id, created_by)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,'new','normal',%s,%s,%s)
                       RETURNING id, tenant_id, account_id, requester_id, subject, status, priority,
                                 visibility, team_id, assignee_id, row_version, updated_at, category_id,
                                 resolution_summary""",
                    (
                        ticket_id, context.owner_org_id, context.application_id, context.installation_id,
                        context.environment_id, context.data_tenant_id, account_id, context.actor_id,
                        subject.strip(), visibility.value, category_id, context.actor_id,
                    ),
                )
                record = _dict(cursor, cursor.fetchone())
                message_id = uuid4()
                cursor.execute(
                    """INSERT INTO support_portal.ticket_message
                         (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                          ticket_id, author_id, kind, body, client_message_id, body_sha256)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,'public',%s,%s,%s)""",
                    (
                        message_id, context.owner_org_id, context.application_id, context.installation_id,
                        context.environment_id, context.data_tenant_id, ticket_id, context.actor_id,
                        body.strip(), uuid4(), sha256(body.strip().encode()).hexdigest(),
                    ),
                )
                response = self._ticket_summary(record or {})
                self._save_receipt(cursor, context, "create_ticket", idempotency_key, digest, 201, response, ticket_id)
        if limited:
            raise RateLimited("Atingiu o limite temporário de novos pedidos. Tente novamente mais tarde.")
        return response or {}

    def save_draft(
        self,
        context: RequestContext,
        *,
        ticket_id: UUID,
        body: str,
        kind: MessageKind,
        expected_version: int,
        client_message_id: UUID,
    ) -> dict[str, Any]:
        text = body.strip()
        if not 1 <= len(text) <= 20_000:
            raise ValidationError("A resposta deve conter entre 1 e 20 000 caracteres.")
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            record = self._load_ticket(cursor, ticket_id, for_update=True)
            if record is None:
                raise NotFound("Pedido não encontrado.")
            ticket = _ticket(record)
            require_visible_ticket(actor, ticket)
            assert_expected_version(ticket, expected_version)
            if kind is MessageKind.INTERNAL and not self._can_add_note(actor, ticket):
                raise Forbidden("Só a equipa autorizada pode criar uma nota interna.")
            if kind is MessageKind.PUBLIC and not self._can_reply(actor, ticket):
                raise Forbidden("Não está autorizado a responder a este pedido.")
            cursor.execute(
                """SELECT id, author_id, kind, body, draft_version, updated_at, published_message_id
                   FROM support_portal.ticket_message_draft
                   WHERE tenant_id=%s AND ticket_id=%s AND client_message_id=%s""",
                (context.data_tenant_id, ticket_id, client_message_id),
            )
            existing = _dict(cursor, cursor.fetchone())
            if existing is not None:
                if (
                    existing["author_id"] != context.actor_id
                    or str(existing["kind"]) != kind.value
                    or existing["body"] != text
                ):
                    raise Conflict("IDEMPOTENCY_CONFLICT: o client_message_id foi usado com outro conteúdo.")
                return {
                    "id": str(existing["id"]), "version": int(existing["draft_version"]),
                    "updated_at": existing["updated_at"].isoformat(),
                    "state": "published" if existing["published_message_id"] else "draft",
                    "message_id": str(existing["published_message_id"]) if existing["published_message_id"] else None,
                    "client_message_id": str(client_message_id),
                }
            draft_id = uuid4()
            cursor.execute(
                """INSERT INTO support_portal.ticket_message_draft
                     (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                      ticket_id, author_id, kind, body, client_message_id)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                   RETURNING id, draft_version, updated_at""",
                (
                    draft_id, context.owner_org_id, context.application_id, context.installation_id,
                    context.environment_id, context.data_tenant_id, ticket_id, context.actor_id,
                    kind.value, text, client_message_id,
                ),
            )
            row = cursor.fetchone()
        return {
            "id": str(row[0]), "version": int(row[1]), "updated_at": row[2].isoformat(),
            "state": "draft", "client_message_id": str(client_message_id),
        }

    def update_draft(
        self,
        context: RequestContext,
        *,
        ticket_id: UUID,
        draft_id: UUID,
        body: str,
        expected_ticket_version: int,
        expected_draft_version: int,
    ) -> dict[str, Any]:
        text = body.strip()
        if not 1 <= len(text) <= 20_000:
            raise ValidationError("A resposta deve conter entre 1 e 20 000 caracteres.")
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            record = self._load_ticket(cursor, ticket_id, for_update=True)
            if record is None:
                raise NotFound("Pedido não encontrado.")
            ticket = _ticket(record)
            require_visible_ticket(actor, ticket)
            assert_expected_version(ticket, expected_ticket_version)
            cursor.execute(
                """UPDATE support_portal.ticket_message_draft
                   SET body=%s, draft_version=draft_version+1
                   WHERE id=%s AND ticket_id=%s AND author_id=%s
                     AND draft_version=%s AND published_message_id IS NULL
                   RETURNING draft_version, updated_at, client_message_id""",
                (text, draft_id, ticket_id, context.actor_id, expected_draft_version),
            )
            row = cursor.fetchone()
            if row is None:
                raise PreconditionFailed("O rascunho mudou ou já foi publicado.")
        return {
            "id": str(draft_id), "version": int(row[0]), "updated_at": row[1].isoformat(),
            "state": "draft", "client_message_id": str(row[2]),
        }

    def publish_draft(
        self,
        context: RequestContext,
        *,
        ticket_id: UUID,
        draft_id: UUID,
        expected_ticket_version: int,
        expected_draft_version: int,
        idempotency_key: str,
    ) -> dict[str, Any]:
        payload = {
            "operation": "publish_draft", "ticket_id": ticket_id, "draft_id": draft_id,
            "expected_ticket_version": expected_ticket_version,
            "expected_draft_version": expected_draft_version,
        }
        digest = canonical_payload_digest(payload)
        if not idempotency_key or len(idempotency_key) > 160:
            raise ValidationError("É necessária uma chave de idempotência válida.")
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            replay = self._receipt(cursor, context, "publish_draft", idempotency_key, digest)
            if replay is not None:
                return replay
            record = self._load_ticket(cursor, ticket_id, for_update=True)
            if record is None:
                raise NotFound("Pedido não encontrado.")
            ticket = _ticket(record)
            require_visible_ticket(actor, ticket)
            assert_expected_version(ticket, expected_ticket_version)
            cursor.execute(
                """SELECT id, author_id, kind, body, client_message_id, draft_version, published_message_id
                   FROM support_portal.ticket_message_draft
                   WHERE id=%s AND ticket_id=%s FOR UPDATE""",
                (draft_id, ticket_id),
            )
            draft = _dict(cursor, cursor.fetchone())
            if draft is None or draft["author_id"] != context.actor_id:
                raise NotFound("Rascunho não encontrado.")
            kind = MessageKind(draft["kind"])
            if draft["published_message_id"] is not None:
                cursor.execute(
                    """SELECT body_sha256, kind FROM support_portal.ticket_message
                       WHERE id=%s AND ticket_id=%s""",
                    (draft["published_message_id"], ticket_id),
                )
                published = cursor.fetchone()
                if published is None or str(published[0]).strip() != sha256(draft["body"].encode()).hexdigest() or str(published[1]) != kind.value:
                    raise Conflict("IDEMPOTENCY_CONFLICT: o client_message_id foi usado com outro conteúdo.")
                response = {
                    "ticket_id": str(ticket_id), "message_id": str(draft["published_message_id"]),
                    "row_version": ticket.row_version, "status": ticket.status.value,
                }
                self._save_receipt(cursor, context, "publish_draft", idempotency_key, digest, 200, response, ticket_id)
                return response
            if int(draft["draft_version"]) != expected_draft_version:
                raise PreconditionFailed("O rascunho mudou. Recarregue antes de publicar.")
            if kind is MessageKind.INTERNAL and not self._can_add_note(actor, ticket):
                raise Forbidden("Só a equipa autorizada pode publicar uma nota interna.")
            if kind is MessageKind.PUBLIC and not self._can_reply(actor, ticket):
                raise Forbidden("Não está autorizado a publicar esta resposta.")
            is_customer = bool(actor.roles & {Role.CUSTOMER_ADMIN, Role.CUSTOMER_MEMBER})
            if is_customer and ticket.status is not TicketStatus.WAITING_CUSTOMER:
                raise Conflict("Este pedido não está à espera de resposta do cliente.")
            message_digest = sha256(draft["body"].encode()).hexdigest()
            cursor.execute(
                """SELECT id, body_sha256, kind FROM support_portal.ticket_message
                   WHERE tenant_id=%s AND ticket_id=%s AND client_message_id=%s""",
                (context.data_tenant_id, ticket_id, draft["client_message_id"]),
            )
            existing_message = cursor.fetchone()
            if existing_message is not None:
                if str(existing_message[1]).strip() != message_digest or str(existing_message[2]) != kind.value:
                    raise Conflict("IDEMPOTENCY_CONFLICT: o client_message_id foi usado com outro conteúdo.")
                cursor.execute(
                    """UPDATE support_portal.ticket_message_draft
                       SET published_message_id=%s, draft_version=draft_version+1
                       WHERE id=%s AND draft_version=%s AND published_message_id IS NULL""",
                    (existing_message[0], draft_id, expected_draft_version),
                )
                if cursor.rowcount != 1:
                    raise PreconditionFailed("O rascunho mudou. Recarregue antes de publicar.")
                response = {
                    "ticket_id": str(ticket_id), "message_id": str(existing_message[0]),
                    "row_version": ticket.row_version, "status": ticket.status.value,
                }
                self._save_receipt(cursor, context, "publish_draft", idempotency_key, digest, 200, response, ticket_id)
                return response
            message_id = uuid4()
            new_status = ticket.status
            if kind is MessageKind.PUBLIC and ticket.status is TicketStatus.WAITING_CUSTOMER and is_customer:
                new_status = TicketStatus.IN_PROGRESS
            cursor.execute(
                """UPDATE support_portal.ticket SET status=%s, row_version=row_version+1
                   WHERE id=%s AND row_version=%s
                   RETURNING row_version, updated_at""",
                (new_status.value, ticket_id, expected_ticket_version),
            )
            changed = cursor.fetchone()
            if changed is None:
                raise PreconditionFailed("O pedido mudou. Recarregue antes de publicar.")
            cursor.execute(
                """INSERT INTO support_portal.ticket_message
                     (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                      ticket_id, author_id, kind, body, client_message_id, body_sha256)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (
                    message_id, context.owner_org_id, context.application_id, context.installation_id,
                    context.environment_id, context.data_tenant_id, ticket_id, context.actor_id,
                    kind.value, draft["body"], draft["client_message_id"],
                    message_digest,
                ),
            )
            cursor.execute(
                """UPDATE support_portal.ticket_message_draft
                   SET published_message_id=%s, draft_version=draft_version+1
                   WHERE id=%s AND draft_version=%s AND published_message_id IS NULL""",
                (message_id, draft_id, expected_draft_version),
            )
            if cursor.rowcount != 1:
                raise PreconditionFailed("O rascunho mudou. Recarregue antes de publicar.")
            if new_status is not ticket.status:
                cursor.execute(
                    """INSERT INTO support_portal.ticket_transition
                         (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                          ticket_id, from_status, to_status, actor_id, expected_version)
                       VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                    (uuid4(), context.owner_org_id, context.application_id, context.installation_id,
                     context.environment_id, context.data_tenant_id, ticket_id, ticket.status.value,
                     new_status.value, context.actor_id, expected_ticket_version),
                )
            recipient = ticket.assignee_id if actor.roles & {Role.CUSTOMER_ADMIN, Role.CUSTOMER_MEMBER} else ticket.requester_id
            if kind is MessageKind.PUBLIC and recipient and recipient != context.actor_id:
                self._notification(cursor, context, ticket_id, recipient, "public_reply", int(changed[0]))
            response = {
                "ticket_id": str(ticket_id), "message_id": str(message_id),
                "row_version": int(changed[0]), "status": new_status.value,
            }
            self._save_receipt(cursor, context, "publish_draft", idempotency_key, digest, 201, response, ticket_id)
        return response

    def assign_ticket(
        self,
        context: RequestContext,
        *,
        ticket_id: UUID,
        expected_version: int,
        team_id: UUID,
        assignee_id: str,
        idempotency_key: str,
    ) -> dict[str, Any]:
        payload = {"ticket_id": ticket_id, "expected_version": expected_version, "team_id": team_id, "assignee_id": assignee_id}
        digest = canonical_payload_digest(payload)
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            replay = self._receipt(cursor, context, "assign_ticket", idempotency_key, digest)
            if replay is not None:
                return replay
            record = self._load_ticket(cursor, ticket_id, for_update=True)
            if record is None:
                raise NotFound("Pedido não encontrado.")
            current = _ticket(record)
            require_visible_ticket(actor, current)
            cursor.execute(
                "SELECT actor_id FROM support_portal.team_member WHERE tenant_id=%s AND team_id=%s AND active",
                (context.data_tenant_id, team_id),
            )
            active_members = frozenset(row[0] for row in cursor.fetchall())
            assigned = assign_ticket(
                current, actor=actor, expected_version=expected_version,
                team_id=team_id, assignee_id=assignee_id,
                active_team_members={team_id: active_members}, updated_at=current.updated_at,
            )
            cursor.execute(
                """UPDATE support_portal.ticket SET team_id=%s, assignee_id=%s, row_version=row_version+1
                   WHERE id=%s AND row_version=%s RETURNING row_version, updated_at""",
                (assigned.team_id, assigned.assignee_id, ticket_id, expected_version),
            )
            updated = cursor.fetchone()
            if updated is None:
                raise PreconditionFailed("O pedido mudou. Recarregue antes de atribuir.")
            self._notification(cursor, context, ticket_id, assignee_id, "assigned", int(updated[0]))
            response = {"ticket_id": str(ticket_id), "team_id": str(team_id), "assignee_id": str(assignee_id), "row_version": int(updated[0])}
            self._save_receipt(cursor, context, "assign_ticket", idempotency_key, digest, 200, response, ticket_id)
        return response

    def triage_ticket(
        self,
        context: RequestContext,
        *,
        ticket_id: UUID,
        expected_version: int,
        category_id: UUID,
        priority: Priority,
        idempotency_key: str,
    ) -> dict[str, Any]:
        payload = {"ticket_id": ticket_id, "expected_version": expected_version, "category_id": category_id, "priority": priority.value}
        digest = canonical_payload_digest(payload)
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            replay = self._receipt(cursor, context, "triage_ticket", idempotency_key, digest)
            if replay is not None:
                return replay
            record = self._load_ticket(cursor, ticket_id, for_update=True)
            if record is None:
                raise NotFound("Pedido não encontrado.")
            current = _ticket(record)
            require_visible_ticket(actor, current)
            cursor.execute("SELECT active FROM support_portal.category WHERE id=%s AND tenant_id=%s", (category_id, context.data_tenant_id))
            category_row = cursor.fetchone()
            updated_model = triage_ticket(
                current, actor=actor, expected_version=expected_version,
                category_id=category_id, category_active=bool(category_row and category_row[0]),
                priority=priority, updated_at=current.updated_at,
            )
            cursor.execute(
                """UPDATE support_portal.ticket SET status=%s, category_id=%s, priority=%s,
                          row_version=row_version+1
                   WHERE id=%s AND row_version=%s RETURNING row_version, updated_at""",
                (updated_model.status.value, category_id, priority.value, ticket_id, expected_version),
            )
            updated = cursor.fetchone()
            if updated is None:
                raise PreconditionFailed("O pedido mudou. Recarregue antes de classificar.")
            cursor.execute(
                """INSERT INTO support_portal.ticket_transition
                     (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                      ticket_id, from_status, to_status, actor_id, expected_version)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (uuid4(), context.owner_org_id, context.application_id, context.installation_id,
                 context.environment_id, context.data_tenant_id, ticket_id, current.status.value,
                 updated_model.status.value, context.actor_id, expected_version),
            )
            response = {"ticket_id": str(ticket_id), "status": updated_model.status.value, "category_id": str(category_id), "priority": priority.value, "row_version": int(updated[0])}
            self._save_receipt(cursor, context, "triage_ticket", idempotency_key, digest, 200, response, ticket_id)
        return response

    def transition(
        self,
        context: RequestContext,
        *,
        ticket_id: UUID,
        action: TransitionAction,
        expected_version: int,
        idempotency_key: str,
        reason: str | None = None,
        resolution_summary: str | None = None,
    ) -> dict[str, Any]:
        payload = {
            "ticket_id": ticket_id, "action": action.value,
            "expected_version": expected_version, "reason": reason,
            "resolution_summary": resolution_summary,
        }
        digest = canonical_payload_digest(payload)
        with self.database.transaction(context) as cursor:
            actor = _actor(cursor, context)
            replay = self._receipt(cursor, context, "ticket_transition", idempotency_key, digest)
            if replay is not None:
                return replay
            record = self._load_ticket(cursor, ticket_id, for_update=True)
            if record is None:
                raise NotFound("Pedido não encontrado.")
            current = _ticket(record)
            require_visible_ticket(actor, current)
            question_persisted = False
            if action is TransitionAction.ASK_CUSTOMER:
                cursor.execute(
                    """SELECT 1 FROM support_portal.ticket_message
                       WHERE ticket_id=%s AND author_id=%s AND kind='public'
                       ORDER BY created_at DESC LIMIT 1""",
                    (ticket_id, context.actor_id),
                )
                question_persisted = cursor.fetchone() is not None
            updated_model = transition_ticket(
                current, actor=actor, action=action, expected_version=expected_version,
                updated_at=current.updated_at,
                actor_is_active_team_member=current.team_id in actor.team_ids if current.team_id else False,
                public_question_persisted=question_persisted,
                resolution_summary=resolution_summary, reason=reason,
            )
            cursor.execute(
                """UPDATE support_portal.ticket SET status=%s, resolution_summary=%s,
                          row_version=row_version+1
                   WHERE id=%s AND row_version=%s RETURNING row_version, updated_at""",
                (updated_model.status.value, updated_model.resolution_summary, ticket_id, expected_version),
            )
            updated = cursor.fetchone()
            if updated is None:
                raise PreconditionFailed("O pedido mudou. Recarregue antes de alterar o estado.")
            cursor.execute(
                """INSERT INTO support_portal.ticket_transition
                     (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                      ticket_id, from_status, to_status, actor_id, reason, expected_version)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (uuid4(), context.owner_org_id, context.application_id, context.installation_id,
                 context.environment_id, context.data_tenant_id, ticket_id, current.status.value,
                 updated_model.status.value, context.actor_id, reason, expected_version),
            )
            response = {"ticket_id": str(ticket_id), "status": updated_model.status.value, "row_version": int(updated[0])}
            self._save_receipt(cursor, context, "ticket_transition", idempotency_key, digest, 200, response, ticket_id)
        return response

    def assistant_read(self, context: RequestContext, ticket_id: UUID) -> dict[str, Any]:
        return self.get_ticket(context, ticket_id, public_only=True)

    def _load_ticket(self, cursor: Any, ticket_id: UUID, *, for_update: bool = False) -> dict[str, Any] | None:
        cursor.execute(
            """SELECT id, tenant_id, account_id, requester_id, subject, status, priority,
                      visibility, team_id, assignee_id, row_version, updated_at, category_id,
                      resolution_summary
               FROM support_portal.ticket WHERE id=%s""" + (" FOR UPDATE" if for_update else ""),
            (ticket_id,),
        )
        return _dict(cursor, cursor.fetchone())

    @staticmethod
    def _ticket_summary(record: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": str(record["id"]), "subject": record["subject"],
            "status": record["status"].value if hasattr(record["status"], "value") else str(record["status"]),
            "priority": record["priority"].value if hasattr(record["priority"], "value") else str(record["priority"]),
            "visibility": record["visibility"].value if hasattr(record["visibility"], "value") else str(record["visibility"]),
            "team_id": str(record["team_id"]) if record["team_id"] else None,
            "assignee_id": str(record["assignee_id"]) if record["assignee_id"] else None,
            "category_id": str(record["category_id"]) if record["category_id"] else None,
            "row_version": int(record["row_version"]),
            "updated_at": record["updated_at"].isoformat(),
            "resolution_summary": record["resolution_summary"],
        }

    @staticmethod
    def _can_reply(actor: ActorContext, ticket: Ticket) -> bool:
        if not actor.active or actor.actor_kind is not ActorKind.USER:
            return False
        if actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR}:
            return True
        if Role.AGENT in actor.roles:
            return ticket.team_id in actor.team_ids
        return (
            ticket.status is TicketStatus.WAITING_CUSTOMER
            and ticket.account_id in actor.account_ids
            and bool(actor.roles & {Role.CUSTOMER_ADMIN, Role.CUSTOMER_MEMBER})
        )

    @staticmethod
    def _can_add_note(actor: ActorContext, ticket: Ticket) -> bool:
        return actor.active and actor.actor_kind is ActorKind.USER and (
            bool(actor.roles & {Role.PLATFORM_ADMIN, Role.COORDINATOR})
            or (Role.AGENT in actor.roles and ticket.team_id in actor.team_ids)
        )

    @staticmethod
    def _receipt(cursor: Any, context: RequestContext, operation: str, key: str, digest: str) -> dict[str, Any] | None:
        lock_key = ":".join((
            str(context.owner_org_id), context.application_id,
            str(context.installation_id), str(context.data_tenant_id),
            str(context.actor_id), operation, key,
        ))
        cursor.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (lock_key,))
        cursor.execute(
            """SELECT payload_sha256, response_status, response_body
               FROM support_portal.ticket_operation_receipt
               WHERE tenant_id=%s AND actor_id=%s AND operation=%s AND idempotency_key=%s""",
            (context.data_tenant_id, context.actor_id, operation, key),
        )
        row = cursor.fetchone()
        if row is None:
            return None
        if str(row[0]).strip() != digest:
            raise Conflict("IDEMPOTENCY_CONFLICT: a mesma chave foi usada com conteúdo diferente.")
        return _as_json(row[2])

    @staticmethod
    def _save_receipt(cursor: Any, context: RequestContext, operation: str, key: str, digest: str, status: int, body: dict[str, Any], ticket_id: UUID) -> None:
        cursor.execute(
            """INSERT INTO support_portal.ticket_operation_receipt
                 (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                  actor_id, operation, idempotency_key, payload_sha256, response_status, response_body, ticket_id)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb,%s)""",
            (uuid4(), context.owner_org_id, context.application_id, context.installation_id,
             context.environment_id, context.data_tenant_id, context.actor_id, operation, key,
             digest, status, json.dumps(body, separators=(",", ":")), ticket_id),
        )

    @staticmethod
    def _notification(cursor: Any, context: RequestContext, ticket_id: UUID, recipient: str, event: str, row_version: int) -> None:
        cursor.execute(
            """INSERT INTO support_portal.ticket_notification_intent
                 (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
                  ticket_id, recipient_actor_id, event_type, row_version)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
               ON CONFLICT (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, recipient_actor_id, event_type, row_version) DO NOTHING""",
            (uuid4(), context.owner_org_id, context.application_id, context.installation_id,
             context.environment_id, context.data_tenant_id, ticket_id, recipient, event, row_version),
        )

    @staticmethod
    def _encode_cursor(cursor: tuple[datetime, UUID] | None) -> str | None:
        if cursor is None:
            return None
        raw = json.dumps([cursor[0].isoformat(), str(cursor[1])], separators=(",", ":")).encode()
        import base64
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_cursor(value: str | None) -> tuple[datetime, UUID] | None:
    if not value:
        return None
    import base64
    from datetime import datetime
    try:
        encoded = value + "=" * (-len(value) % 4)
        timestamp, ticket_id = json.loads(base64.urlsafe_b64decode(encoded).decode())
        return datetime.fromisoformat(timestamp), UUID(ticket_id)
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        raise ValidationError("O cursor de pesquisa é inválido.") from exc
