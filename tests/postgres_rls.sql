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
GRANT USAGE ON SCHEMA support_portal TO apoio_runtime_test;
GRANT SELECT ON ALL TABLES IN SCHEMA support_portal TO apoio_runtime_test;

INSERT INTO support_portal.customer_account
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, name, created_by)
VALUES
  ('51000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', 'Conta Alfa teste', '55000000-0000-4000-8000-000000000001'),
  ('51000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000002', 'Conta Beta teste', '55000000-0000-4000-8000-000000000002');

INSERT INTO support_portal.account_member
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, account_id,
   actor_id, role, created_by)
VALUES
  ('56000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001',
   '55000000-0000-4000-8000-000000000001', 'customer_member', '55000000-0000-4000-8000-000000000001'),
  ('56000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000002',
   '55000000-0000-4000-8000-000000000002', 'customer_member', '55000000-0000-4000-8000-000000000002');

INSERT INTO support_portal.support_team
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, name, created_by)
VALUES
  ('57000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', 'Apoio Alfa', '55000000-0000-4000-8000-000000000003');
INSERT INTO support_portal.team_member
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, team_id,
   actor_id, role, created_by)
VALUES
  ('58000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', '57000000-0000-4000-8000-000000000001',
   '55000000-0000-4000-8000-000000000003', 'agent', '55000000-0000-4000-8000-000000000003');

INSERT INTO support_portal.ticket
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, account_id,
   requester_id, team_id, subject, status, visibility, created_by)
VALUES
  ('59000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000001',
   '55000000-0000-4000-8000-000000000001', '57000000-0000-4000-8000-000000000001',
   'Ticket Alfa sintético', 'in_progress', 'account',
   '55000000-0000-4000-8000-000000000001'),
  ('59000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000002',
   '55000000-0000-4000-8000-000000000002', NULL, 'Ticket Beta sintético', 'new', 'requester',
   '55000000-0000-4000-8000-000000000002');

INSERT INTO support_portal.ticket_message
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, ticket_id,
   author_id, kind, body, client_message_id, body_sha256)
VALUES
  ('5a000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', '59000000-0000-4000-8000-000000000001',
   '55000000-0000-4000-8000-000000000001', 'public', 'Resposta pública sintética.',
   '5b000000-0000-4000-8000-000000000001', repeat('a', 64)),
  ('5a000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', '59000000-0000-4000-8000-000000000001',
   '55000000-0000-4000-8000-000000000003', 'internal', 'Nota interna sintética secreta.',
   '5b000000-0000-4000-8000-000000000002', repeat('b', 64)),
  ('5a000000-0000-4000-8000-000000000003', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000002', '59000000-0000-4000-8000-000000000002',
   '55000000-0000-4000-8000-000000000002', 'public', 'Mensagem Beta sintética.',
   '5b000000-0000-4000-8000-000000000003', repeat('c', 64));

INSERT INTO support_portal.ticket_attachment
  (id, owner_org_id, application_id, installation_id, environment_id, tenant_id, ticket_id,
   message_id, storage_object_id, owner_id, filename, mime_type, size_bytes, sha256, scan_state)
VALUES
  ('5c000000-0000-4000-8000-000000000001', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', '59000000-0000-4000-8000-000000000001',
   '5a000000-0000-4000-8000-000000000001', '5d000000-0000-4000-8000-000000000001',
   '55000000-0000-4000-8000-000000000001', 'public.pdf', 'application/pdf', 128, repeat('d', 64), 'clean'),
  ('5c000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000000', 'apoio-test-app',
   '52000000-0000-4000-8000-000000000001', '53000000-0000-4000-8000-000000000001',
   '54000000-0000-4000-8000-000000000001', '59000000-0000-4000-8000-000000000001',
   '5a000000-0000-4000-8000-000000000002', '5d000000-0000-4000-8000-000000000002',
   '55000000-0000-4000-8000-000000000003', 'internal.pdf', 'application/pdf', 128, repeat('e', 64), 'clean');

SET ROLE apoio_runtime_test;
SELECT set_config('app.owner_org_id', '51000000-0000-4000-8000-000000000000', true);
SELECT set_config('app.application_id', 'apoio-test-app', true);
SELECT set_config('app.installation_id', '52000000-0000-4000-8000-000000000001', true);
SELECT set_config('app.environment_id', '53000000-0000-4000-8000-000000000001', true);
SELECT set_config('app.data_tenant_id', '54000000-0000-4000-8000-000000000002', true);
SELECT set_config('app.actor_id', '55000000-0000-4000-8000-000000000002', true);
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

SELECT set_config('app.data_tenant_id', '54000000-0000-4000-8000-000000000001', true);
SELECT set_config('app.actor_id', '55000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE ticket_count integer; message_count integer; attachment_count integer;
BEGIN
  SELECT count(*) INTO ticket_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO message_count FROM support_portal.ticket_message
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO attachment_count FROM support_portal.ticket_attachment
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  IF ticket_count <> 1 OR message_count <> 1 OR attachment_count <> 1 THEN
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
DECLARE ticket_count integer; message_count integer; attachment_count integer;
BEGIN
  SELECT count(*) INTO ticket_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO message_count FROM support_portal.ticket_message
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO attachment_count FROM support_portal.ticket_attachment
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  IF ticket_count <> 0 OR message_count <> 0 OR attachment_count <> 0 THEN
    RAISE EXCEPTION 'revoked customer membership retained access to old content';
  END IF;
END
$$;

SELECT set_config('app.data_tenant_id', '54000000-0000-4000-8000-000000000001', true);
SELECT set_config('app.actor_id', '55000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE message_count integer; attachment_count integer;
BEGIN
  SELECT count(*) INTO message_count FROM support_portal.ticket_message
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO attachment_count FROM support_portal.ticket_attachment
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  IF message_count <> 2 OR attachment_count <> 2 THEN
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
DECLARE ticket_count integer; message_count integer; attachment_count integer;
BEGIN
  SELECT count(*) INTO ticket_count FROM support_portal.ticket
    WHERE id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO message_count FROM support_portal.ticket_message
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  SELECT count(*) INTO attachment_count FROM support_portal.ticket_attachment
    WHERE ticket_id = '59000000-0000-4000-8000-000000000001';
  IF ticket_count <> 0 OR message_count <> 0 OR attachment_count <> 0 THEN
    RAISE EXCEPTION 'revoked team membership retained access to old content';
  END IF;
END
$$;

ROLLBACK;
