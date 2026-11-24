from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timezone, timedelta
import unittest
from uuid import UUID, uuid4

from support_portal.context import ContextUnavailable, RequestContext
from support_portal.repository import PostgresSupportStore, _validated_change_readback
from support_portal.domain import (
    ActorContext,
    ActorKind,
    AttachmentRef,
    ChangeApproval,
    Conflict,
    Message,
    MessageKind,
    NotFound,
    Priority,
    PreconditionFailed,
    Role,
    ScanState,
    Ticket,
    TicketStatus,
    TransitionAction,
    ValidationError,
    Visibility,
    assign_ticket,
    assistant_ticket_context,
    authorized_search,
    authorized_page,
    can_submit_change,
    ChangeRequestUnavailable,
    canonical_payload_digest,
    check_idempotent_replay,
    customer_export_surface,
    delivery_label,
    require_visible_ticket,
    notification_payload,
    customer_ticket_surface,
    transition_ticket,
    triage_ticket,
    validate_attachment_for_publish,
    visible_messages,
)


TENANT_A = "tenant:alpha"
TENANT_B = "tenant:beta"
ACCOUNT_A = UUID("10000000-0000-4000-8000-000000000001")
ACCOUNT_B = UUID("10000000-0000-4000-8000-000000000002")
TEAM = UUID("20000000-0000-4000-8000-000000000001")
ANA = "person:ana"
BRUNO = "person:bruno"
RITA = "person:rita"
LUIS = "person:luis"
APP = "apoio"
ENV = "environment:shared"
TICKET_ID = UUID("50000000-0000-4000-8000-000000000001")
NOW = datetime(2026, 11, 24, 0, 0, tzinfo=timezone.utc)


def ticket(**changes):
    base = Ticket(
        id=TICKET_ID,
        tenant_id=TENANT_A,
        account_id=ACCOUNT_A,
        requester_id=ANA,
        subject="Invoice export is unavailable",
        status=TicketStatus.IN_PROGRESS,
        priority=Priority.NORMAL,
        visibility=Visibility.ACCOUNT,
        team_id=TEAM,
        assignee_id=RITA,
        row_version=2,
        updated_at=NOW,
    )
    return replace(base, **changes)


def customer(actor_id=ANA, account_ids=frozenset({ACCOUNT_A})):
    return ActorContext(
        tenant_id=TENANT_A,
        actor_id=actor_id,
        actor_kind=ActorKind.USER,
        roles=frozenset({Role.CUSTOMER_MEMBER}),
        account_ids=account_ids,
    )


def agent(actor_id=RITA, teams=frozenset({TEAM})):
    return ActorContext(
        tenant_id=TENANT_A,
        actor_id=actor_id,
        actor_kind=ActorKind.USER,
        roles=frozenset({Role.AGENT}),
        team_ids=teams,
    )


def coordinator(actor_id=LUIS):
    return ActorContext(
        tenant_id=TENANT_A,
        actor_id=actor_id,
        actor_kind=ActorKind.USER,
        roles=frozenset({Role.COORDINATOR}),
    )


def trusted_state(**overrides):
    values = {
        "owner_org_id": "org:acme",
        "application_id": APP,
        "installation_id": "install:apoio",
        "environment_id": ENV,
        "environment_kind": "test",
        "data_tenant_id": TENANT_A,
        "actor_id": ANA,
        "actor_kind": "user",
        "policy_revision": "policy-1",
        "correlation_id": "request:opaque-01",
    }
    values.update(overrides)

    class State:
        sovharn_context = values

    return State()


class DomainTests(unittest.TestCase):
    def test_change_request_reuses_staff_note_capability_and_validates_readback(self):
        self.assertTrue(PostgresSupportStore._can_add_note(agent(), ticket()))
        self.assertTrue(PostgresSupportStore._can_add_note(coordinator(), ticket()))
        admin = ActorContext(TENANT_A, LUIS, ActorKind.USER, frozenset({Role.PLATFORM_ADMIN}))
        self.assertTrue(PostgresSupportStore._can_add_note(admin, ticket()))
        self.assertFalse(PostgresSupportStore._can_add_note(customer(), ticket()))
        self.assertFalse(PostgresSupportStore._can_add_note(agent(teams=frozenset({uuid4()})), ticket()))
        service = ActorContext(TENANT_A, "service:1", ActorKind.SERVICE, frozenset(), active=False)
        self.assertFalse(PostgresSupportStore._can_add_note(service, ticket()))

        request_id = str(uuid4())
        body = "Adicionar exportação CSV."
        from hashlib import sha256
        record = {"id": request_id, "body": body, "revision": 1,
                  "content_hash": sha256(body.encode()).hexdigest(), "state": "submitted"}
        self.assertEqual(_validated_change_readback(record, expected_id=request_id), record)
        with self.assertRaises(ChangeRequestUnavailable):
            _validated_change_readback({**record, "body": "texto alterado"}, expected_id=request_id)

    def test_context_is_fail_closed_and_requires_exact_schema(self):
        class EmptyState:
            sovharn_context = None

        with self.assertRaises(ContextUnavailable):
            RequestContext.from_trusted_state(EmptyState())

        malformed = trusted_state()
        malformed.sovharn_context["tenant_id"] = str(TENANT_B)
        with self.assertRaises(ContextUnavailable):
            RequestContext.from_trusted_state(malformed)

    def test_context_accepts_opaque_non_uuid_d0_identifiers(self):
        context = RequestContext.from_trusted_state(trusted_state())
        self.assertEqual(context.owner_org_id, "org:acme")
        self.assertEqual(context.installation_id, "install:apoio")
        self.assertEqual(context.environment_id, "environment:shared")
        self.assertEqual(context.data_tenant_id, "tenant:alpha")
        self.assertEqual(context.actor_id, "person:ana")
        self.assertEqual(context.correlation_id, "request:opaque-01")

    def test_context_rejects_empty_and_surrounding_whitespace_identifiers(self):
        for invalid in ("", "   ", " org:acme", "org:acme\n", "org:acme\t"):
            with self.subTest(invalid=repr(invalid)):
                with self.assertRaises(ContextUnavailable):
                    RequestContext.from_trusted_state(trusted_state(owner_org_id=invalid))

    def test_context_preserves_long_opaque_ids_and_internal_control_characters(self):
        identifier = "org:" + ("x" * 300) + "\nunit"
        context = RequestContext.from_trusted_state(trusted_state(owner_org_id=identifier))
        self.assertEqual(context.owner_org_id, identifier)

    def test_context_binding_requires_exact_installation_and_environment(self):
        context = RequestContext.from_trusted_state(trusted_state())
        context.assert_binding(
            application_id=APP,
            installation_id=context.installation_id,
            environment_id=ENV,
            environment_kind="test",
        )
        with self.assertRaises(ContextUnavailable):
            context.assert_binding(
                application_id=APP,
                installation_id=context.installation_id,
                environment_id=ENV,
                environment_kind="production",
            )

    def test_context_accepts_canonical_assistant_kind_but_does_not_grant_ticket_access(self):
        context = RequestContext.from_trusted_state(trusted_state(actor_kind="assistant"))
        self.assertEqual(context.actor_kind, "assistant")
        assistant = ActorContext(
            tenant_id=TENANT_A,
            actor_id=ANA,
            actor_kind=ActorKind.ASSISTANT,
            roles=frozenset({Role.CUSTOMER_MEMBER}),
            account_ids=frozenset({ACCOUNT_A}),
        )
        with self.assertRaises(NotFound):
            require_visible_ticket(assistant, ticket())

    def test_customer_cannot_discover_other_tenant_ticket(self):
        actor = ActorContext(
            tenant_id=TENANT_B,
            actor_id=BRUNO,
            actor_kind=ActorKind.USER,
            roles=frozenset({Role.CUSTOMER_MEMBER}),
            account_ids=frozenset({ACCOUNT_B}),
        )
        with self.assertRaises(NotFound):
            require_visible_ticket(actor, ticket())

    def test_service_actor_cannot_inherit_a_person_membership(self):
        service = ActorContext(
            tenant_id=TENANT_A,
            actor_id=ANA,
            actor_kind=ActorKind.SERVICE,
            roles=frozenset({Role.CUSTOMER_MEMBER}),
            account_ids=frozenset({ACCOUNT_A}),
        )
        with self.assertRaises(NotFound):
            require_visible_ticket(service, ticket())

    def test_customer_cannot_read_requester_only_ticket(self):
        with self.assertRaises(NotFound):
            require_visible_ticket(customer(BRUNO), ticket(visibility=Visibility.REQUESTER))

    def test_customer_surfaces_exclude_internal_notes(self):
        messages = (
            Message(uuid4(), TENANT_A, TICKET_ID, RITA, MessageKind.PUBLIC, "We are checking this.", uuid4(), NOW),
            Message(uuid4(), TENANT_A, TICKET_ID, RITA, MessageKind.INTERNAL, "Internal diagnosis.", uuid4(), NOW),
        )
        self.assertEqual(
            [message.kind for message in visible_messages(customer(), ticket(), messages)],
            [MessageKind.PUBLIC],
        )
        self.assertEqual(len(visible_messages(agent(), ticket(), messages)), 2)

    def test_search_export_assistant_and_notifications_never_include_internal_body(self):
        messages = (
            Message(uuid4(), TENANT_A, TICKET_ID, RITA, MessageKind.PUBLIC, "Public shipping update.", uuid4(), NOW),
            Message(uuid4(), TENANT_A, TICKET_ID, RITA, MessageKind.INTERNAL, "private-phrase secret diagnosis", uuid4(), NOW),
        )
        surface = customer_ticket_surface(customer(), ticket(), messages)
        export = customer_export_surface(agent(), ticket(), messages)
        assistant = assistant_ticket_context(agent(), ticket(), messages)
        public_results = authorized_search(
            [ticket()], messages, actor=customer(), query="shipping"
        )
        secret_results = authorized_search(
            [ticket()], messages, actor=agent(), query="private-phrase"
        )
        payload = notification_payload(
            ticket=ticket(), recipient_actor_id=ANA, event="public_reply"
        )
        all_safe_surfaces = repr((surface, export, assistant, public_results, secret_results, payload))
        self.assertEqual([message.body for message in surface.messages], ["Public shipping update."])
        self.assertEqual([message.body for message in export.messages], ["Public shipping update."])
        self.assertEqual([message.body for message in assistant.messages], ["Public shipping update."])
        self.assertEqual(len(public_results), 1)
        self.assertEqual(secret_results, ())
        self.assertNotIn("private-phrase", all_safe_surfaces)
        self.assertNotIn("secret diagnosis", all_safe_surfaces)

    def test_idempotency_replays_same_payload_and_rejects_different_payload(self):
        payload = {"kind": "public", "body": "Please send the export again."}
        digest = canonical_payload_digest(payload)
        self.assertTrue(check_idempotent_replay(saved_digest=digest, incoming_payload=payload))
        with self.assertRaises(Conflict):
            check_idempotent_replay(saved_digest=digest, incoming_payload={**payload, "body": "Different body"})

    def test_stale_assignment_returns_412(self):
        with self.assertRaises(PreconditionFailed):
            assign_ticket(
                ticket(),
                actor=coordinator(),
                expected_version=1,
                team_id=TEAM,
                assignee_id=RITA,
                active_team_members={TEAM: frozenset({RITA})},
                updated_at=NOW,
            )

    def test_assignment_requires_active_team_member(self):
        with self.assertRaises(ValidationError):
            assign_ticket(
                ticket(),
                actor=coordinator(),
                expected_version=2,
                team_id=TEAM,
                assignee_id=BRUNO,
                active_team_members={TEAM: frozenset({RITA})},
                updated_at=NOW,
            )

    def test_resolution_requires_active_assignee_and_summary(self):
        with self.assertRaises(ValidationError):
            transition_ticket(
                ticket(assignee_id=None), actor=coordinator(),
                action=TransitionAction.RESOLVE, expected_version=2, updated_at=NOW,
                actor_is_active_team_member=False, resolution_summary="Resolved successfully.",
            )
        with self.assertRaises(ValidationError):
            transition_ticket(
                ticket(), actor=agent(), action=TransitionAction.RESOLVE,
                expected_version=2, updated_at=NOW, actor_is_active_team_member=True,
                resolution_summary="short",
            )

    def test_stale_transition_returns_412(self):
        with self.assertRaises(PreconditionFailed):
            transition_ticket(
                ticket(), actor=agent(), action=TransitionAction.RESOLVE,
                expected_version=1, updated_at=NOW,
                actor_is_active_team_member=True, resolution_summary="Resolved successfully.",
            )

    def test_customer_reply_resumes_waiting_ticket_and_keeps_question_history(self):
        waiting = ticket(status=TicketStatus.WAITING_CUSTOMER, row_version=3)
        question = Message(uuid4(), TENANT_A, TICKET_ID, RITA, MessageKind.PUBLIC, "Can you confirm the account?", uuid4(), NOW)
        answer = Message(uuid4(), TENANT_A, TICKET_ID, ANA, MessageKind.PUBLIC, "Yes, confirmed.", uuid4(), NOW + timedelta(minutes=1))
        resumed = transition_ticket(
            waiting, actor=customer(), action=TransitionAction.CUSTOMER_REPLY,
            expected_version=3, updated_at=answer.created_at,
        )
        self.assertEqual(resumed.status, TicketStatus.IN_PROGRESS)
        self.assertEqual(resumed.row_version, 4)
        self.assertEqual([message.body for message in (question, answer)], ["Can you confirm the account?", "Yes, confirmed."])

    def test_pending_attachment_cannot_be_published(self):
        attachment = AttachmentRef(
            id=uuid4(), tenant_id=TENANT_A, application_id=APP, environment_id=ENV,
            owner_id=ANA, scan_state=ScanState.PENDING,
        )
        with self.assertRaises(ValidationError):
            validate_attachment_for_publish(
                actor=customer(), ticket=ticket(), attachment=attachment,
                application_id=APP, environment_id=ENV,
            )

    def test_unsigned_clean_attachment_requires_d0_v2_attestation(self):
        attachment = AttachmentRef(
            id=uuid4(), tenant_id=TENANT_A, application_id=APP, environment_id=ENV,
            owner_id=ANA, scan_state=ScanState.CLEAN,
        )
        with self.assertRaisesRegex(ValidationError, "D0 v2 scanner attestation"):
            validate_attachment_for_publish(
                actor=customer(), ticket=ticket(), attachment=attachment,
                application_id=APP, environment_id=ENV,
            )
        with self.assertRaises(NotFound):
            validate_attachment_for_publish(
                actor=customer(BRUNO), ticket=ticket(), attachment=attachment,
                application_id=APP, environment_id=ENV,
            )

    def test_attachment_cannot_be_linked_twice(self):
        attachment = AttachmentRef(
            id=uuid4(), tenant_id=TENANT_A, application_id=APP, environment_id=ENV,
            owner_id=ANA, scan_state=ScanState.CLEAN, linked_message_id=uuid4(),
        )
        with self.assertRaises(Conflict):
            validate_attachment_for_publish(
                actor=customer(), ticket=ticket(), attachment=attachment,
                application_id=APP, environment_id=ENV,
            )

    def test_inactive_category_is_rejected_without_changing_ticket(self):
        original = ticket(status=TicketStatus.NEW, row_version=1)
        with self.assertRaises(ValidationError):
            triage_ticket(
                original, actor=coordinator(), expected_version=1, category_id=uuid4(),
                category_active=False, priority=Priority.HIGH, updated_at=NOW,
            )
        self.assertEqual(original.status, TicketStatus.NEW)
        self.assertEqual(original.row_version, 1)

    def test_change_submission_requires_current_approved_revision_and_digest(self):
        self.assertFalse(can_submit_change(current_revision=2, current_digest="new", approved=ChangeApproval(1, "old")))
        self.assertFalse(can_submit_change(current_revision=2, current_digest="new", approved=ChangeApproval(2, "old")))
        self.assertTrue(can_submit_change(current_revision=2, current_digest="new", approved=ChangeApproval(2, "new")))

    def test_claimed_done_never_means_production(self):
        self.assertNotEqual(delivery_label(raw_status="CLAIMED_DONE"), "Disponível em produção")
        self.assertEqual(
            delivery_label(
                raw_status="verified_production",
                evidence={
                    "app_id": "apoio",
                    "environment_kind": "production",
                    "candidate_digest": "sha256:1",
                    "runtime_readback": True,
                },
            ),
            "Disponível em produção",
        )

    def test_business_transitions_do_not_require_sovharn_availability(self):
        started = transition_ticket(
            ticket(status=TicketStatus.TRIAGED),
            actor=agent(), action=TransitionAction.START,
            expected_version=2, updated_at=NOW, actor_is_active_team_member=True,
        )
        self.assertEqual(started.status, TicketStatus.IN_PROGRESS)

    def test_removed_customer_membership_revokes_existing_ticket_reads(self):
        removed = customer(BRUNO, account_ids=frozenset())
        with self.assertRaises(NotFound):
            require_visible_ticket(removed, ticket())
        removed_requester = customer(ANA, account_ids=frozenset())
        with self.assertRaises(NotFound):
            require_visible_ticket(removed_requester, ticket())

    def test_authorized_pagination_filters_before_has_more_and_cursor(self):
        visible = ticket()
        hidden = ticket(
            id=UUID("50000000-0000-4000-8000-000000000002"),
            tenant_id=TENANT_B,
            requester_id=BRUNO,
            account_id=ACCOUNT_B,
        )
        page = authorized_page([visible, hidden], actor=customer(), limit=1)
        self.assertEqual([item.id for item in page.items], [visible.id])
        self.assertFalse(page.has_more)
        self.assertIsNone(page.next_cursor)

    def test_customer_question_must_be_persisted_before_waiting(self):
        with self.assertRaises(ValidationError):
            transition_ticket(
                ticket(), actor=agent(), action=TransitionAction.ASK_CUSTOMER,
                expected_version=2, updated_at=NOW, actor_is_active_team_member=True,
                public_question_persisted=False,
            )


if __name__ == "__main__":
    unittest.main()

