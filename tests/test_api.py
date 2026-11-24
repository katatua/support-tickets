from __future__ import annotations

from uuid import uuid4
import unittest

from support_portal.api import create_app
from support_portal.context import RequestContext
from support_portal.domain import Conflict, NotFound


class FakeStore:
    def __init__(self):
        self.calls = []
        self.change_receipts = []

    def me(self, context):
        self.calls.append(("me", context))
        return {
            "context": {"actor_id": str(context.actor_id)},
            "capabilities": ["customer_member"], "accounts": [], "categories": [], "teams": [],
        }

    def list_tickets(self, context, **kwargs):
        self.calls.append(("list_tickets", context, kwargs))
        return {"items": [], "next_cursor": None, "has_more": False}

    def create_ticket(self, context, **kwargs):
        self.calls.append(("create_ticket", context, kwargs))
        return {"id": "ticket-1", "row_version": 1}

    def get_ticket(self, context, ticket_id, *, public_only=False):
        self.calls.append(("get_ticket", context, ticket_id, public_only))
        raise NotFound("Pedido não encontrado.")

    def propose_change_request(self, context, *, ticket_id, text, idempotency_key, port):
        self.calls.append(("propose_change_request", context, ticket_id, text, idempotency_key))
        key = (str(context.actor_id), str(ticket_id), idempotency_key)
        for saved_text, saved_result, saved_key in self.change_receipts:
            if saved_key == key:
                if saved_text != text:
                    raise Conflict("IDEMPOTENCY_CONFLICT: a mesma chave foi usada com conteúdo diferente.")
                return saved_result
        proposal = port.propose_change_request(
            installation_id=str(context.installation_id), text=text,
            idempotency_key=idempotency_key,
        )
        readback = port.read_change_request(
            installation_id=str(context.installation_id), request_id=proposal["id"],
        )
        result = {"ticket_id": str(ticket_id), "change_request": readback}
        self.change_receipts.append((text, result, key))
        return result

    def read_change_request(self, context, *, ticket_id, request_id, port):
        self.calls.append(("read_change_request", context, ticket_id, request_id))
        return {"ticket_id": str(ticket_id), "change_request": port.read_change_request(
            installation_id=str(context.installation_id), request_id=str(request_id),
        )}

    def assistant_read(self, context, ticket_id):
        self.calls.append(("assistant_read", context, ticket_id))
        return {"id": str(ticket_id), "messages": [{"body": "Resposta pública"}]}

    def triage_ticket(self, context, **kwargs):
        self.calls.append(("triage_ticket", context, kwargs))
        return {"ticket_id": str(kwargs["ticket_id"]), "status": "triaged", "row_version": 2}

    def assign_ticket(self, context, **kwargs):
        self.calls.append(("assign_ticket", context, kwargs))
        return {"ticket_id": str(kwargs["ticket_id"]), "row_version": 3}

    def transition(self, context, **kwargs):
        self.calls.append(("transition", context, kwargs))
        return {"ticket_id": str(kwargs["ticket_id"]), "status": "in_progress", "row_version": 4}


class FakeChangeRequestPort:
    def __init__(self):
        self.calls = []
        self.requests = {}

    def propose_change_request(self, *, installation_id, text, idempotency_key):
        self.calls.append(("propose", installation_id, text, idempotency_key))
        record = {"id": idempotency_key, "body": text.strip(), "revision": 1,
                  "content_hash": "a" * 64, "state": "submitted"}
        self.requests[idempotency_key] = record
        return record

    def read_change_request(self, *, installation_id, request_id):
        self.calls.append(("read", installation_id, request_id))
        return self.requests[request_id]


def context(**changes):
    values = {
        "owner_org_id": "org:api-test",
        "application_id": "apoio",
        "installation_id": "install:api-test",
        "environment_id": "environment:api-test",
        "environment_kind": "test",
        "data_tenant_id": "tenant:api-test",
        "actor_id": "person:api-test",
        "actor_kind": "user",
        "policy_revision": "policy-r1",
        "correlation_id": "request:api-test",
    }
    values.update(changes)
    return RequestContext(**values)


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.store = FakeStore()
        self.context = context()
        self.app = create_app(store=self.store, context_resolver=lambda: self.context)
        self.app.config.update(TESTING=True)
        self.client = self.app.test_client()
        self.host = {
            "Host": "apoio-testes.sovharn.com",
            "Origin": "https://apoio-testes.sovharn.com",
        }

    def test_missing_trusted_context_fails_closed_despite_client_claims(self):
        app = create_app(store=self.store)
        app.config.update(TESTING=True)
        client = app.test_client()
        response = client.get(
            "/api/v1/tickets",
            headers={
                "Host": "apoio-testes.sovharn.com",
                "X-Tenant-ID": str(uuid4()),
                "X-Actor-ID": str(uuid4()),
                "X-Actor-Kind": "user",
            },
            query_string={"tenant_id": str(uuid4()), "actor_id": str(uuid4())},
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.store.calls, [])

    def test_app_context_cannot_be_replayed_on_another_host(self):
        response = self.client.get("/api/v1/me", headers={"Host": "apoio.sovharn.com"})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.store.calls, [])

    def test_cross_site_mutation_is_rejected_before_store_access(self):
        response = self.client.post(
            "/api/v1/tickets",
            headers={"Host": "apoio-testes.sovharn.com", "Origin": "https://evil.example"},
            json={
                "account_id": str(uuid4()), "subject": "Export failure",
                "body": "The monthly export is not available.",
            },
        )
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.store.calls, [])

    def test_context_for_another_application_is_rejected(self):
        self.context = context(application_id="crm")
        response = self.client.get("/api/v1/me", headers=self.host)
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.store.calls, [])

    def test_authenticated_portal_reads_server_membership_projection(self):
        response = self.client.get("/api/v1/me", headers=self.host)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["context"]["actor_id"], str(self.context.actor_id))
        self.assertEqual(self.store.calls[0][0], "me")

    def test_portal_template_renders_responsive_persistent_workflow(self):
        response = self.client.get("/", headers=self.host)
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"viewport-fit=cover", response.data)
        self.assertIn(b"Guardar rascunho", response.data)
        self.assertIn(b"Carregar mais pedidos", response.data)

    def test_ticket_creation_uses_idempotency_key_and_ignores_actor_claims(self):
        account_id = uuid4()
        response = self.client.post(
            "/api/v1/tickets",
            headers={**self.host, "Idempotency-Key": "browser-request-1", "X-Actor-ID": str(uuid4())},
            json={
                "account_id": str(account_id), "subject": "Export failure",
                "body": "The monthly export is not available.", "visibility": "requester",
                "actor_id": str(uuid4()),
            },
        )
        self.assertEqual(response.status_code, 422)  # unknown actor field is forbidden
        self.assertEqual(self.store.calls, [])

        response = self.client.post(
            "/api/v1/tickets",
            headers={**self.host, "Idempotency-Key": "browser-request-1", "X-Actor-ID": str(uuid4())},
            json={
                "account_id": str(account_id), "subject": "Export failure",
                "body": "The monthly export is not available.", "visibility": "requester",
            },
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.json["id"], "ticket-1")
        name, actor_context, args = self.store.calls[0]
        self.assertEqual(name, "create_ticket")
        self.assertEqual(actor_context.actor_id, self.context.actor_id)
        self.assertEqual(args["idempotency_key"], "browser-request-1")
        self.assertEqual(args["account_id"], account_id)

    def test_missing_idempotency_key_is_rejected_before_mutation(self):
        response = self.client.post(
            "/api/v1/tickets", headers=self.host,
            json={"account_id": str(uuid4()), "subject": "Export failure", "body": "The monthly export is not available."},
        )
        self.assertEqual(response.status_code, 422)
        self.assertEqual(self.store.calls, [])

    def test_change_request_route_fails_closed_without_injected_port(self):
        response = self.client.post(
            f"/api/v1/tickets/{uuid4()}/change-requests",
            headers={**self.host, "Idempotency-Key": str(uuid4())},
            json={"text": "Adicionar exportação CSV."},
        )
        self.assertEqual(response.status_code, 503)
        self.assertEqual(self.store.calls, [])

    def test_change_request_proposal_replay_conflict_and_readback_use_fake_port(self):
        port = FakeChangeRequestPort()
        self.app.config["CHANGE_REQUEST_PORT"] = port
        ticket_id, key = uuid4(), str(uuid4())
        path = f"/api/v1/tickets/{ticket_id}/change-requests"
        first = self.client.post(path, headers={**self.host, "Idempotency-Key": key},
                                 json={"text": "Adicionar exportação CSV."})
        self.assertEqual(first.status_code, 201)
        self.assertEqual(first.json["change_request"]["id"], key)
        self.assertEqual([call[0] for call in port.calls], ["propose", "read"])
        replay = self.client.post(path, headers={**self.host, "Idempotency-Key": key},
                                  json={"text": "Adicionar exportação CSV."})
        self.assertEqual(replay.status_code, 201)
        self.assertEqual(replay.json, first.json)
        self.assertEqual(len(port.calls), 2)
        conflict = self.client.post(path, headers={**self.host, "Idempotency-Key": key},
                                    json={"text": "Alterar outra coisa."})
        self.assertEqual(conflict.status_code, 409)
        self.assertEqual(len(port.calls), 2)
        readback = self.client.get(f"{path}/{key}", headers=self.host)
        self.assertEqual(readback.status_code, 200)
        self.assertEqual(readback.json["change_request"]["id"], key)
        self.assertEqual(port.calls[-1][0], "read")

    def test_triage_assignment_and_transition_routes_forward_expected_versions(self):
        ticket_id = uuid4()
        category_id = uuid4()
        team_id = uuid4()
        cases = [
            ("triage_ticket", f"/api/v1/tickets/{ticket_id}/triage", {
                "expected_version": 1, "category_id": str(category_id), "priority": "high",
            }),
            ("assign_ticket", f"/api/v1/tickets/{ticket_id}/assign", {
                "expected_version": 2, "team_id": str(team_id), "assignee_id": "person:agent-opaque",
            }),
            ("transition", f"/api/v1/tickets/{ticket_id}/transition", {
                "expected_version": 3, "action": "start",
            }),
        ]
        for operation, path, payload in cases:
            response = self.client.post(
                path,
                headers={**self.host, "Idempotency-Key": f"key-{operation}"},
                json=payload,
            )
            self.assertEqual(response.status_code, 200)
            call_name, call_context, args = self.store.calls[-1]
            self.assertEqual(call_name, operation)
            self.assertEqual(call_context.actor_id, self.context.actor_id)
            self.assertEqual(args["expected_version"], payload["expected_version"])
            self.assertEqual(args["idempotency_key"], f"key-{operation}")

    def test_assignment_accepts_long_opaque_actor_ids_and_internal_newlines(self):
        ticket_id = uuid4()
        team_id = uuid4()
        assignee_id = "person:" + ("agent" * 60) + "\nsecondary"
        ok = self.client.post(
            f"/api/v1/tickets/{ticket_id}/assign",
            headers={**self.host, "Idempotency-Key": "opaque-assignee"},
            json={"expected_version": 1, "team_id": str(team_id), "assignee_id": assignee_id},
        )
        self.assertEqual(ok.status_code, 200)
        self.assertEqual(self.store.calls[-1][2]["assignee_id"], assignee_id)
        self.store.calls.clear()
        invalid = self.client.post(
            f"/api/v1/tickets/{ticket_id}/assign",
            headers={**self.host, "Idempotency-Key": "invalid-assignee"},
            json={"expected_version": 1, "team_id": str(team_id), "assignee_id": "person:agent\n"},
        )
        self.assertEqual(invalid.status_code, 422)
        self.assertEqual(self.store.calls, [])

    def test_unauthorized_ticket_lookup_has_one_non_disclosing_response(self):
        ticket_id = uuid4()
        response = self.client.get(f"/api/v1/tickets/{ticket_id}", headers=self.host)
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.json, {"error": "NOT_FOUND", "message": "Pedido não encontrado."})

    def test_assistant_tools_are_typed_read_only_and_model_independent(self):
        listing = self.client.get("/api/v1/assistant/tools", headers=self.host)
        self.assertEqual(listing.status_code, 200)
        self.assertFalse(listing.json["model_available"])
        ticket_id = uuid4()
        response = self.client.post(
            "/api/v1/assistant/tools/read_ticket", headers=self.host,
            json={"ticket_id": str(ticket_id)},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["result"]["messages"][0]["body"], "Resposta pública")
        self.assertEqual(self.store.calls[-1][0], "assistant_read")
        invalid = self.client.post(
            "/api/v1/assistant/tools/read_ticket", headers=self.host,
            json={"ticket_id": str(ticket_id), "include_internal": True},
        )
        self.assertEqual(invalid.status_code, 422)

    def test_liveness_does_not_claim_database_or_integration_readiness(self):
        response = self.client.get("/healthz")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json, {"service": "apoio", "state": "alive"})


if __name__ == "__main__":
    unittest.main()
