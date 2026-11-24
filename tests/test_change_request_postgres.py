from __future__ import annotations

import hashlib
import os
import unittest
from uuid import UUID, uuid4

from support_portal.context import RequestContext
from support_portal.database import PostgresDatabase
from support_portal.domain import ChangeRequestUnavailable, DomainError
from support_portal.repository import PostgresSupportStore


class ProviderStatusError(Exception):
    def __init__(self, status: int):
        self.http_status = status


class LostResponsePort:
    """Structural fake: persists a POST, then loses its first response."""

    def __init__(self):
        self.calls = []
        self.requests = {}
        self.proposal_keys = []

    def read_change_request(self, *, installation_id: str, request_id: str):
        self.calls.append(("read", installation_id, request_id))
        if request_id not in self.requests:
            raise ProviderStatusError(404)
        return self.requests[request_id]

    def propose_change_request(self, *, installation_id: str, text: str, idempotency_key: str):
        self.calls.append(("post", installation_id, text, idempotency_key))
        self.proposal_keys.append(idempotency_key)
        body = text.strip()
        self.requests[idempotency_key] = {
            "id": idempotency_key,
            "body": body,
            "revision": 1,
            "content_hash": hashlib.sha256(body.encode("utf-8")).hexdigest(),
            "state": "submitted",
        }
        if len(self.proposal_keys) == 1:
            raise TimeoutError("simulated lost HTTP response")
        return self.requests[idempotency_key]


@unittest.skipUnless(os.environ.get("APOIO_TEST_DATABASE_URL"), "requires disposable PostgreSQL")
class ChangeRequestPostgresRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import psycopg

        cls.dsn = os.environ["APOIO_TEST_DATABASE_URL"]
        cls.owner = "org:change-recovery:" + str(uuid4())
        cls.installation = str(uuid4())
        cls.environment = "environment:change-recovery:" + str(uuid4())
        cls.tenant = "tenant:change-recovery:" + str(uuid4())
        cls.agent_id = "person:agent:" + str(uuid4())
        cls.customer_id = "person:customer:" + str(uuid4())
        cls.account_id = uuid4()
        cls.team_id = uuid4()
        cls.ticket_id = uuid4()

        with psycopg.connect(cls.dsn, autocommit=True) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """DO $role$
                       BEGIN
                         IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='apoio_runtime_test') THEN
                           CREATE ROLE apoio_runtime_test NOLOGIN NOBYPASSRLS;
                         END IF;
                       END
                       $role$"""
                )
                cursor.execute("ALTER ROLE apoio_runtime_test NOLOGIN NOBYPASSRLS")
                cursor.execute("GRANT USAGE ON SCHEMA support_portal TO apoio_runtime_test")
                cursor.execute("GRANT SELECT ON ALL TABLES IN SCHEMA support_portal TO apoio_runtime_test")
                cursor.execute("GRANT UPDATE ON support_portal.ticket TO apoio_runtime_test")
                cursor.execute(
                    "GRANT INSERT ON support_portal.ticket_change_link, "
                    "support_portal.ticket_operation_receipt TO apoio_runtime_test"
                )
                cursor.execute(
                    """INSERT INTO support_portal.customer_account
                       (id, owner_org_id, application_id, installation_id, environment_id,
                        environment_kind, tenant_id, name, created_by)
                       VALUES (%s,%s,'apoio',%s,%s,'test',%s,%s,%s)""",
                    (cls.account_id, cls.owner, cls.installation, cls.environment, cls.tenant,
                     "Conta de recuperação", cls.customer_id),
                )
                cursor.execute(
                    """INSERT INTO support_portal.support_team
                       (id, owner_org_id, application_id, installation_id, environment_id,
                        environment_kind, tenant_id, name, created_by)
                       VALUES (%s,%s,'apoio',%s,%s,'test',%s,%s,%s)""",
                    (cls.team_id, cls.owner, cls.installation, cls.environment, cls.tenant,
                     "Equipa de recuperação", cls.agent_id),
                )
                cursor.execute(
                    """INSERT INTO support_portal.team_member
                       (id, owner_org_id, application_id, installation_id, environment_id,
                        environment_kind, tenant_id, team_id, actor_id, role, created_by)
                       VALUES (%s,%s,'apoio',%s,%s,'test',%s,%s,%s,'agent',%s)""",
                    (uuid4(), cls.owner, cls.installation, cls.environment, cls.tenant,
                     cls.team_id, cls.agent_id, cls.agent_id),
                )
                cursor.execute(
                    """INSERT INTO support_portal.account_member
                       (id, owner_org_id, application_id, installation_id, environment_id,
                        environment_kind, tenant_id, account_id, actor_id, role, created_by)
                       VALUES (%s,%s,'apoio',%s,%s,'test',%s,%s,%s,'customer_member',%s)""",
                    (uuid4(), cls.owner, cls.installation, cls.environment, cls.tenant,
                     cls.account_id, cls.customer_id, cls.customer_id),
                )
                cursor.execute(
                    """INSERT INTO support_portal.ticket
                       (id, owner_org_id, application_id, installation_id, environment_id,
                        environment_kind, tenant_id, account_id, requester_id, team_id, subject,
                        status, visibility, created_by)
                       VALUES (%s,%s,'apoio',%s,%s,'test',%s,%s,%s,%s,
                               'Exportação indisponível','in_progress','account',%s)""",
                    (cls.ticket_id, cls.owner, cls.installation, cls.environment, cls.tenant,
                     cls.account_id, cls.customer_id, cls.team_id, cls.customer_id),
                )

        def connect_as_runtime(dsn: str):
            connection = psycopg.connect(dsn)
            with connection.cursor() as cursor:
                cursor.execute("SET ROLE apoio_runtime_test")
            connection.commit()
            return connection

        cls.database = PostgresDatabase(dsn=cls.dsn, connect=connect_as_runtime)
        cls.store = PostgresSupportStore(database=cls.database)

    @classmethod
    def context(cls, actor_id: str, correlation_id: str) -> RequestContext:
        return RequestContext(
            owner_org_id=cls.owner,
            application_id="apoio",
            installation_id=cls.installation,
            environment_id=cls.environment,
            environment_kind="test",
            data_tenant_id=cls.tenant,
            actor_id=actor_id,
            actor_kind="user",
            policy_revision="policy:recovery-test",
            correlation_id=correlation_id,
        )

    def test_timeout_after_acceptance_reconciles_same_uuid_without_duplicate_post(self):
        agent_context = self.context(self.agent_id, "request:first:" + str(uuid4()))
        client_key = str(uuid4())
        text = "Adicionar exportação CSV."
        port = LostResponsePort()

        with self.assertRaises(ChangeRequestUnavailable):
            self.store.propose_change_request(
                agent_context, ticket_id=self.ticket_id, text=text,
                idempotency_key=client_key, port=port,
            )

        request_id = port.proposal_keys[0]
        UUID(request_id)
        self.assertEqual(port.calls, [
            ("read", self.installation, request_id),
            ("post", self.installation, text, request_id),
        ])
        with self.assertRaises(DomainError):
            self.store.propose_change_request(
                self.context(self.customer_id, "request:customer:" + str(uuid4())),
                ticket_id=self.ticket_id, text="Pedir alteração como cliente.",
                idempotency_key=str(uuid4()), port=port,
            )
        self.assertEqual(len(port.calls), 2)

        result = self.store.propose_change_request(
            self.context(self.agent_id, "request:retry:" + str(uuid4())),
            ticket_id=self.ticket_id, text=text, idempotency_key=client_key, port=port,
        )
        self.assertEqual(result["change_request"]["id"], request_id)
        self.assertEqual(result["change_request"]["body"], text)
        self.assertEqual(port.calls[-1], ("read", self.installation, request_id))
        self.assertEqual(len(port.proposal_keys), 1)

        with self.database.transaction(self.context(self.customer_id, "request:privacy:" + str(uuid4()))) as cursor:
            cursor.execute(
                "SELECT count(*) FROM support_portal.ticket_change_link WHERE ticket_id=%s",
                (self.ticket_id,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)
            cursor.execute(
                "SELECT count(*) FROM support_portal.ticket_operation_receipt WHERE ticket_id=%s",
                (self.ticket_id,),
            )
            self.assertEqual(cursor.fetchone()[0], 0)

        import psycopg
        with psycopg.connect(self.dsn) as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT count(*) FROM support_portal.ticket_change_link "
                    "WHERE ticket_id=%s AND change_request_ref=%s",
                    (self.ticket_id, request_id),
                )
                self.assertEqual(cursor.fetchone()[0], 1)
                cursor.execute(
                    "SELECT response_body->>'state' FROM support_portal.ticket_operation_receipt "
                    "WHERE ticket_id=%s AND operation='change_request_prepare'",
                    (self.ticket_id,),
                )
                self.assertEqual(cursor.fetchone()[0], "reconciling")
                cursor.execute(
                    "SELECT count(*) FROM support_portal.ticket_operation_receipt "
                    "WHERE ticket_id=%s AND operation='change_request_readback'",
                    (self.ticket_id,),
                )
                self.assertEqual(cursor.fetchone()[0], 1)
