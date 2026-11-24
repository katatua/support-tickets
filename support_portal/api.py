"""Authenticated Apoio portal API and browser entry point.

The WSGI host must attach ``sovharn.request_context`` after authenticating the
person. No request header, query parameter, cookie or body can create this value.
Without that trusted injection every business route returns 401.
"""
from __future__ import annotations

from typing import Any, Callable
from uuid import UUID

from flask import Flask, jsonify, make_response, render_template, request
from pydantic import ValidationError as PydanticValidationError

from .assistant_tools import AssistantTools, TOOL_DEFINITIONS
from .context import ContextUnavailable, RequestContext
from .domain import (
    DomainError, MessageKind, NotFound, Priority, TransitionAction, ValidationError,
    Visibility,
)
from .models import (
    AssignTicketInput, AssistantReadTicketInput, AssistantSearchInput,
    CreateTicketInput, MessageKindInput, PublishDraftInput, SaveDraftInput,
    TransitionActionInput, TransitionTicketInput, TriageTicketInput,
    UpdateDraftInput,
)
from .database import DatabaseUnavailable
from .repository import PostgresSupportStore, decode_cursor


_EXPECTED_HOSTS = {
    "test": "apoio-testes.sovharn.com",
    "production": "apoio.sovharn.com",
}


class _TrustedState:
    def __init__(self, value: Any):
        self.sovharn_context = value


def _trusted_context_from_wsgi() -> RequestContext:
    """Read only an environment entry installed by trusted server middleware."""
    raw = request.environ.get("sovharn.request_context")
    return RequestContext.from_trusted_state(_TrustedState(raw))


def _validated(model: type, data: Any) -> Any:
    try:
        return model.model_validate(data)
    except PydanticValidationError as exc:
        raise ValidationError("Os dados enviados são inválidos.") from exc


def _json_body() -> dict[str, Any]:
    value = request.get_json(silent=True)
    if not isinstance(value, dict):
        raise ValidationError("O corpo deve ser um objeto JSON.")
    return value


def _required_idempotency_key() -> str:
    value = request.headers.get("Idempotency-Key", "").strip()
    if not 1 <= len(value) <= 160:
        raise ValidationError("Envie uma chave Idempotency-Key com 1 a 160 caracteres.")
    return value


def create_app(
    *,
    store: Any | None = None,
    context_resolver: Callable[[], RequestContext] | None = None,
    allowed_hosts: dict[str, str] | None = None,
) -> Flask:
    app = Flask(__name__, template_folder="templates", static_folder="static")
    app.config["SUPPORT_STORE"] = store or PostgresSupportStore()
    app.config["CONTEXT_RESOLVER"] = context_resolver or _trusted_context_from_wsgi
    app.config["EXPECTED_HOSTS"] = allowed_hosts or _EXPECTED_HOSTS

    def require_context() -> RequestContext:
        try:
            context = app.config["CONTEXT_RESOLVER"]()
            if not isinstance(context, RequestContext):
                raise ContextUnavailable("Trusted context resolver returned an invalid object.")
            if context.application_id != "apoio":
                raise ContextUnavailable("Request belongs to a different application.")
            expected_host = app.config["EXPECTED_HOSTS"].get(context.environment_kind)
            request_host = (request.host or "").split(":", 1)[0].lower()
            if not expected_host or request_host != expected_host:
                raise ContextUnavailable("Request host does not match the trusted environment.")
            return context
        except ContextUnavailable as exc:
            raise _http_error(401, "A autenticação pessoal deste portal não está disponível.") from exc

    def _http_error(status: int, message: str):
        from werkzeug.exceptions import HTTPException

        error = HTTPException(description=message)
        error.code = status
        return error

    @app.errorhandler(DomainError)
    def handle_domain_error(error: DomainError):
        response = jsonify({"error": error.code, "message": error.message})
        response.status_code = error.status_code
        return response

    @app.errorhandler(404)
    def handle_not_found(_error: Any):
        return jsonify({"error": "NOT_FOUND", "message": "Recurso não encontrado."}), 404

    @app.errorhandler(401)
    def handle_unauthorized(error: Any):
        return jsonify({"error": "AUTH_REQUIRED", "message": str(error.description)}), 401

    @app.errorhandler(503)
    def handle_unavailable(error: Any):
        return jsonify({"error": "SERVICE_UNAVAILABLE", "message": str(error.description)}), 503

    @app.errorhandler(DatabaseUnavailable)
    def handle_database_unavailable(_error: DatabaseUnavailable):
        return jsonify({"error": "DATABASE_UNAVAILABLE", "message": "O portal de apoio está temporariamente indisponível."}), 503

    @app.errorhandler(PydanticValidationError)
    def handle_model_validation(_error: Any):
        return jsonify({"error": "VALIDATION_ERROR", "message": "Os dados enviados são inválidos."}), 422

    @app.get("/healthz")
    def healthz():
        # Liveness only; authentication, database and SH Connect are not certified here.
        return jsonify({"service": "apoio", "state": "alive"})

    @app.get("/")
    def portal_home():
        context = require_context()
        me = app.config["SUPPORT_STORE"].me(context)
        return render_template("portal.html", me=me)

    @app.get("/api/v1/me")
    def me():
        context = require_context()
        return jsonify(app.config["SUPPORT_STORE"].me(context))

    @app.get("/api/v1/categories")
    def categories():
        context = require_context()
        me_record = app.config["SUPPORT_STORE"].me(context)
        return jsonify({"items": me_record["categories"]})

    @app.get("/api/v1/tickets")
    def tickets():
        context = require_context()
        try:
            limit = int(request.args.get("limit", "25"))
        except ValueError as exc:
            raise ValidationError("O limite da página deve ser um número.") from exc
        return jsonify(app.config["SUPPORT_STORE"].list_tickets(
            context,
            limit=limit,
            after=decode_cursor(request.args.get("cursor")),
            query=request.args.get("q"),
        ))

    @app.post("/api/v1/tickets")
    def create_ticket():
        context = require_context()
        data = _validated(CreateTicketInput, _json_body())
        result = app.config["SUPPORT_STORE"].create_ticket(
            context,
            account_id=data.account_id,
            subject=data.subject,
            body=data.body,
            visibility=Visibility(data.visibility.value),
            category_id=data.category_id,
            idempotency_key=_required_idempotency_key(),
        )
        response = jsonify(result)
        response.status_code = 201
        return response

    @app.get("/api/v1/tickets/<uuid:ticket_id>")
    def get_ticket(ticket_id: UUID):
        context = require_context()
        return jsonify(app.config["SUPPORT_STORE"].get_ticket(context, ticket_id))

    @app.get("/api/v1/tickets/<uuid:ticket_id>/export")
    def export_ticket(ticket_id: UUID):
        context = require_context()
        return jsonify(app.config["SUPPORT_STORE"].get_ticket(context, ticket_id, public_only=True))

    @app.post("/api/v1/tickets/<uuid:ticket_id>/drafts")
    def save_draft(ticket_id: UUID):
        context = require_context()
        data = _validated(SaveDraftInput, _json_body())
        result = app.config["SUPPORT_STORE"].save_draft(
            context,
            ticket_id=ticket_id,
            body=data.body,
            kind=MessageKind(data.kind.value),
            expected_version=data.expected_ticket_version,
            client_message_id=data.client_message_id,
        )
        return jsonify(result), 201

    @app.patch("/api/v1/tickets/<uuid:ticket_id>/drafts/<uuid:draft_id>")
    def update_draft(ticket_id: UUID, draft_id: UUID):
        context = require_context()
        data = _validated(UpdateDraftInput, _json_body())
        return jsonify(app.config["SUPPORT_STORE"].update_draft(
            context,
            ticket_id=ticket_id,
            draft_id=draft_id,
            body=data.body,
            expected_ticket_version=data.expected_ticket_version,
            expected_draft_version=data.expected_draft_version,
        ))

    @app.post("/api/v1/tickets/<uuid:ticket_id>/drafts/<uuid:draft_id>/publish")
    def publish_draft(ticket_id: UUID, draft_id: UUID):
        context = require_context()
        data = _validated(PublishDraftInput, _json_body())
        result = app.config["SUPPORT_STORE"].publish_draft(
            context,
            ticket_id=ticket_id,
            draft_id=draft_id,
            expected_ticket_version=data.expected_ticket_version,
            expected_draft_version=data.expected_draft_version,
            idempotency_key=_required_idempotency_key(),
        )
        response = jsonify(result)
        response.status_code = 200
        return response

    @app.post("/api/v1/tickets/<uuid:ticket_id>/assign")
    def assign_ticket(ticket_id: UUID):
        context = require_context()
        data = _validated(AssignTicketInput, _json_body())
        return jsonify(app.config["SUPPORT_STORE"].assign_ticket(
            context,
            ticket_id=ticket_id,
            expected_version=data.expected_version,
            team_id=data.team_id,
            assignee_id=data.assignee_id,
            idempotency_key=_required_idempotency_key(),
        ))

    @app.post("/api/v1/tickets/<uuid:ticket_id>/triage")
    def triage_ticket(ticket_id: UUID):
        context = require_context()
        data = _validated(TriageTicketInput, _json_body())
        return jsonify(app.config["SUPPORT_STORE"].triage_ticket(
            context,
            ticket_id=ticket_id,
            expected_version=data.expected_version,
            category_id=data.category_id,
            priority=Priority(data.priority.value),
            idempotency_key=_required_idempotency_key(),
        ))

    @app.post("/api/v1/tickets/<uuid:ticket_id>/transition")
    def transition_ticket(ticket_id: UUID):
        context = require_context()
        data = _validated(TransitionTicketInput, _json_body())
        return jsonify(app.config["SUPPORT_STORE"].transition(
            context,
            ticket_id=ticket_id,
            action=TransitionAction(data.action.value),
            expected_version=data.expected_version,
            idempotency_key=_required_idempotency_key(),
            reason=data.reason,
            resolution_summary=data.resolution_summary,
        ))

    @app.get("/api/v1/assistant/tools")
    def assistant_tool_list():
        require_context()
        return jsonify({"tools": list(TOOL_DEFINITIONS), "model_available": False})

    @app.post("/api/v1/assistant/tools/<tool_name>")
    def assistant_tool(tool_name: str):
        context = require_context()
        try:
            result = AssistantTools(app.config["SUPPORT_STORE"]).execute(context, tool_name, _json_body())
        except PydanticValidationError as exc:
            raise ValidationError("Os argumentos da ferramenta são inválidos.") from exc
        except ValueError as exc:
            raise NotFound("Ferramenta não encontrada.") from exc
        return jsonify({"tool": tool_name, "result": result})

    return app


app = create_app()
