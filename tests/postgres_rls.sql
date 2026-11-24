-- RLS integration proof for the disposable PostgreSQL database.
-- Run after migrations/0001_support_portal.sql as a database administrator.
-- All identities and ticket text below are synthetic fixtures.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'apoio_runtime_test') THEN
    CREATE ROLE apoio_runtime_test NOLOGIN NOBYPASSRLS;
  END IF;
END
$$;
ALTER ROLE apoio_runtime_test NOBYPASSRLS;
SELECT set_config('app.environment_kind', 'test', false);
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname = 'apoio_runtime_test'
      AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcanlogin
  ) THEN
    RAISE EXCEPTION 'runtime fixture role must be NOLOGIN NOBYPASSRLS and not superuser';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'support_portal' AND c.relkind = 'r'
      AND (NOT c.relrowsecurity OR NOT c.relforcerowsecurity)
  ) THEN
    RAISE EXCEPTION 'support portal tables must enable and force row-level security';
  END IF;
END
$$;
GRANT USAGE ON SCHEMA support_portal TO apoio_runtime_test;
GRANT SELECT ON ALL TABLES IN SCHEMA support_portal TO apoio_runtime_test;
GRANT INSERT ON support_portal.ticket_attachment TO apoio_runtime_test;

INSERT INTO support_portal.customer_account
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, name, created_by)
VALUES
  ('51000000-0000-4000-8000-000000000001', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', 'Conta Alfa teste', 'person:ana'),
  ('51000000-0000-4000-8000-000000000002', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:beta', 'Conta Beta teste', 'person:bruno');

-- Same D0 environment ID and data tenant collide across owner, installation and
-- environment kind. They must remain invisible even to a tenant coordinator.
INSERT INTO support_portal.customer_account
  (id, owner_org_id, application_id, installation_id, environment_id, environment_kind,
   tenant_id, name, created_by)
VALUES
  ('61000000-0000-4000-8000-000000000001', 'org:other', 'apoio',
   'install:apoio', 'environment:shared', 'test', 'tenant:alpha', 'Outra organização', 'person:rita'),
  ('61000000-0000-4000-8000-000000000002', 'org:apoio', 'apoio',
   'install:other', 'environment:shared', 'test', 'tenant:alpha', 'Outra instalação', 'person:rita'),
  ('61000000-0000-4000-8000-000000000003', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared', 'production', 'tenant:alpha', 'Outro ambiente', 'person:rita');

INSERT INTO support_portal.staff_membership
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id,
   actor_id, role, created_by)
VALUES
  ('56000000-0000-4000-8000-000000000003', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared', 'tenant:alpha', 'person:coordinator',
   'coordinator', 'person:coordinator');

DO $$
BEGIN
  INSERT INTO support_portal.customer_account
    (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, name, created_by)
  VALUES
    ('61000000-0000-4000-8000-000000000004', 'org:apoio', 'apoio-impersonation',
     'install:apoio', 'environment:shared', 'tenant:alpha', 'App inválida', 'person:ana');
  RAISE EXCEPTION 'non-canonical application_id was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END
$$;

INSERT INTO support_portal.account_member
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, account_id,
   actor_id, role, created_by)
VALUES
  ('56000000-0000-4000-8000-000000000001', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '51000000-0000-4000-8000-000000000001',
   'person:ana', 'customer_member', 'person:ana'),
  ('56000000-0000-4000-8000-000000000002', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:beta', '51000000-0000-4000-8000-000000000002',
   'person:bruno', 'customer_member', 'person:bruno');

INSERT INTO support_portal.support_team
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, name, created_by)
VALUES
  ('57000000-0000-4000-8000-000000000001', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', 'Apoio Alfa', 'person:rita');
INSERT INTO support_portal.team_member
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, team_id,
   actor_id, role, created_by)
VALUES
  ('58000000-0000-4000-8000-000000000001', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '57000000-0000-4000-8000-000000000001',
   'person:rita', 'agent', 'person:rita');

INSERT INTO support_portal.ticket
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, account_id,
   requester_id, team_id, subject, status, visibility, created_by)
VALUES
  ('59000000-0000-4000-8000-000000000001', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '51000000-0000-4000-8000-000000000001',
   'person:ana', '57000000-0000-4000-8000-000000000001',
   'Ticket Alfa sintético', 'in_progress', 'account',
   'person:ana'),
  ('59000000-0000-4000-8000-000000000002', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:beta', '51000000-0000-4000-8000-000000000002',
   'person:bruno', NULL, 'Ticket Beta sintético', 'new', 'requester',
   'person:bruno');

INSERT INTO support_portal.ticket_message
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, ticket_id,
   author_id, kind, body, client_message_id, body_sha256)
VALUES
  ('5a000000-0000-4000-8000-000000000001', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '59000000-0000-4000-8000-000000000001',
   'person:ana', 'public', 'Resposta pública sintética.',
   '5b000000-0000-4000-8000-000000000001', repeat('a', 64)),
  ('5a000000-0000-4000-8000-000000000002', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '59000000-0000-4000-8000-000000000001',
   'person:rita', 'internal', 'Nota interna sintética secreta.',
   '5b000000-0000-4000-8000-000000000002', repeat('b', 64)),
  ('5a000000-0000-4000-8000-000000000003', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:beta', '59000000-0000-4000-8000-000000000002',
   'person:bruno', 'public', 'Mensagem Beta sintética.',
   '5b000000-0000-4000-8000-000000000003', repeat('c', 64));

INSERT INTO support_portal.ticket_attachment
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, ticket_id,
   message_id, storage_object_id, owner_id, filename, mime_type, size_bytes, sha256, scan_state)
VALUES
  ('5c000000-0000-4000-8000-000000000001', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '59000000-0000-4000-8000-000000000001',
   '5a000000-0000-4000-8000-000000000001', '5d000000-0000-4000-8000-000000000001',
   'person:ana', 'public.pdf', 'application/pdf', 128, repeat('d', 64), 'pending'),
  ('5c000000-0000-4000-8000-000000000002', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '59000000-0000-4000-8000-000000000001',
   '5a000000-0000-4000-8000-000000000002', '5d000000-0000-4000-8000-000000000002',
   'person:rita', 'internal.pdf', 'application/pdf', 128, repeat('e', 64), 'pending');

DO $apoio_clean$
BEGIN
  UPDATE support_portal.ticket_attachment SET scan_state = 'clean'
  WHERE id = '5c000000-0000-4000-8000-000000000001';
  RAISE EXCEPTION 'database accepted CLEAN without D0 v2 scanner attestation';
EXCEPTION WHEN check_violation THEN
  NULL;
END
$apoio_clean$;

INSERT INTO support_portal.ticket_message_draft
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, ticket_id,
   author_id, kind, body, client_message_id)
VALUES
  ('5e000000-0000-4000-8000-000000000001', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '59000000-0000-4000-8000-000000000001',
   'person:ana', 'public', 'Rascunho privado da cliente.',
   '5f000000-0000-4000-8000-000000000001'),
  ('5e000000-0000-4000-8000-000000000002', 'org:apoio', 'apoio',
   'install:apoio', 'environment:shared',
   'tenant:alpha', '59000000-0000-4000-8000-000000000001',
   'person:rita', 'internal', 'Nota interna em rascunho secreta.',
   '5f000000-0000-4000-8000-000000000002');

SET ROLE apoio_runtime_test;
SELECT set_config('app.owner_org_id', 'org:apoio', true);
SELECT set_config('app.application_id', 'apoio', true);
SELECT set_config('app.installation_id', 'install:apoio', true);
SELECT set_config('app.environment_id', 'environment:shared', true);
SELECT set_config('app.environment_kind', 'test', true);
SELECT set_config('app.data_tenant_id', 'tenant:beta', true);
SELECT set_config('app.actor_id', 'person:bruno', true);
SELECT set_config('app.actor_kind', 'user', true);
DO $apoio_upload$
BEGIN
  INSERT INTO support_portal.ticket_attachment
    (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, ticket_id,
     message_id, storage_object_id, owner_id, filename, mime_type, size_bytes, sha256, scan_state)
  VALUES
    ('5c000000-0000-4000-8000-000000000003', 'org:apoio', 'apoio', 'install:apoio',
     'environment:shared', 'tenant:beta', '59000000-0000-4000-8000-000000000002',
     '5a000000-0000-4000-8000-000000000003', '5d000000-0000-4000-8000-000000000003',
     'person:bruno', 'pending.pdf', 'application/pdf', 128, repeat('f', 64), 'pending');
  RAISE EXCEPTION 'runtime role inserted attachment without a D0 v2 upload/scanner adapter';
EXCEPTION WHEN insufficient_privilege THEN
  NULL;
END
$apoio_upload$;
DO $$
DECLARE visible_count integer; unknown_count integer;
BEGIN
  SELECT count(*) INTO visible_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO unknown_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000099';
  IF visible_count <> 0 OR unknown_count <> 0 THEN
    RAISE EXCEPTION 'tenant isolation leaked a ticket or disclosed its existence';
  END IF;
  SELECT count(*) INTO visible_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000002';
  IF visible_count <> 1 THEN RAISE EXCEPTION 'Beta cannot read its own ticket'; END IF;
END
$$;
SELECT set_config('app.data_tenant_id', 'tenant:alpha', true);
SELECT set_config('app.actor_id', 'person:coordinator', true);
DO $$
DECLARE visible_count integer; expected_count integer;
BEGIN
  SELECT count(*) INTO visible_count FROM support_portal.customer_account
   WHERE id IN (
     '61000000-0000-4000-8000-000000000001',
     '61000000-0000-4000-8000-000000000002',
     '61000000-0000-4000-8000-000000000003'
   );
  SELECT count(*) INTO expected_count FROM support_portal.customer_account;
  IF visible_count <> 0 OR expected_count <> 1 THEN
    RAISE EXCEPTION 'same environment ID escaped organization, installation or environment-kind RLS';
  END IF;
END
$$;
SELECT set_config('app.actor_id', 'person:bruno', true);
SELECT set_config('app.data_tenant_id', 'tenant:beta', true);
SELECT set_config('app.actor_kind', 'service', true);
DO $$
DECLARE visible_count integer;
BEGIN
  SELECT count(*) INTO visible_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000002';
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'service actor inherited a human membership';
  END IF;
END
$$;
SELECT set_config('app.actor_kind', 'user', true);

SELECT set_config('app.data_tenant_id', 'tenant:alpha', true);
SELECT set_config('app.actor_id', 'person:ana', true);
DO $$
DECLARE ticket_count integer; message_count integer; attachment_count integer; draft_count integer; secret_drafts integer;
BEGIN
  SELECT count(*) INTO ticket_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO message_count FROM support_portal.ticket_message
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO attachment_count FROM support_portal.ticket_attachment
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO draft_count FROM support_portal.ticket_message_draft
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO secret_drafts FROM support_portal.ticket_message_draft
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001' AND body LIKE '%secreta%';
  IF ticket_count <> 1 OR message_count <> 1 OR attachment_count <> 1 OR draft_count <> 1 OR secret_drafts <> 0 THEN
    RAISE EXCEPTION 'customer view exposed internal content or hid public content';
  END IF;
END
$$;

RESET ROLE;
UPDATE support_portal.account_member
   SET active = false, revoked_at = clock_timestamp()
 WHERE id = '56000000-0000-4000-8000-000000000001';
SET ROLE apoio_runtime_test;
DO $$
DECLARE ticket_count integer; message_count integer; attachment_count integer; draft_count integer;
BEGIN
  SELECT count(*) INTO ticket_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO message_count FROM support_portal.ticket_message
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO attachment_count FROM support_portal.ticket_attachment
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO draft_count FROM support_portal.ticket_message_draft
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  IF ticket_count <> 0 OR message_count <> 0 OR attachment_count <> 0 OR draft_count <> 0 THEN
    RAISE EXCEPTION 'revoked customer membership retained access to old content';
  END IF;
END
$$;

SELECT set_config('app.data_tenant_id', 'tenant:alpha', true);
SELECT set_config('app.actor_id', 'person:rita', true);
DO $$
DECLARE message_count integer; attachment_count integer; draft_count integer; secret_drafts integer;
BEGIN
  SELECT count(*) INTO message_count FROM support_portal.ticket_message
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO attachment_count FROM support_portal.ticket_attachment
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO draft_count FROM support_portal.ticket_message_draft
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO secret_drafts FROM support_portal.ticket_message_draft
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001' AND body LIKE '%secreta%';
  IF message_count <> 2 OR attachment_count <> 2 OR draft_count <> 1 OR secret_drafts <> 1 THEN
    RAISE EXCEPTION 'active team member cannot read internal history and attachments';
  END IF;
END
$$;

RESET ROLE;
UPDATE support_portal.team_member
   SET active = false, revoked_at = clock_timestamp()
 WHERE id = '58000000-0000-4000-8000-000000000001';
SET ROLE apoio_runtime_test;
DO $$
DECLARE ticket_count integer; message_count integer; attachment_count integer; draft_count integer;
BEGIN
  SELECT count(*) INTO ticket_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO message_count FROM support_portal.ticket_message
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO attachment_count FROM support_portal.ticket_attachment
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO draft_count FROM support_portal.ticket_message_draft
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  IF ticket_count <> 0 OR message_count <> 0 OR attachment_count <> 0 OR draft_count <> 0 THEN
    RAISE EXCEPTION 'revoked team membership retained access to old content';
  END IF;
END
$$;

ROLLBACK;
