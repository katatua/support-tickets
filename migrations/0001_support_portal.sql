-- Support portal D1 schema.
-- D0 middleware must set transaction-local owner, application, installation,
-- environment ID/kind, data tenant, actor, policy revision and correlation from
-- its authenticated request context before any business query. Never accept these
-- values from a client header or body. Runtime role must not own these tables
-- and must not have BYPASSRLS.

BEGIN;

CREATE SCHEMA IF NOT EXISTS support_portal;

CREATE FUNCTION support_portal.valid_context_identifier(p_value text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT p_value IS NOT NULL
     AND char_length(p_value) >= 1
     AND p_value !~ '^[[:space:]]'
     AND p_value !~ '[[:space:]]
$$;

CREATE TYPE support_portal.ticket_status AS ENUM (
  'new', 'triaged', 'in_progress', 'waiting_customer', 'resolved', 'closed', 'cancelled'
);
CREATE TYPE support_portal.ticket_priority AS ENUM ('low', 'normal', 'high', 'urgent');
CREATE TYPE support_portal.ticket_visibility AS ENUM ('requester', 'account');
CREATE TYPE support_portal.message_kind AS ENUM ('public', 'internal');
CREATE TYPE support_portal.member_role AS ENUM ('customer_admin', 'customer_member');
CREATE TYPE support_portal.staff_role AS ENUM ('platform_admin', 'coordinator');
CREATE TYPE support_portal.team_role AS ENUM ('agent', 'coordinator');

CREATE FUNCTION support_portal.setting_text(setting_name text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting(setting_name, true), '')
$$;

CREATE FUNCTION support_portal.current_tenant_id()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT support_portal.setting_text('app.data_tenant_id') $$;

CREATE FUNCTION support_portal.current_actor_id()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT support_portal.setting_text('app.actor_id') $$;

CREATE FUNCTION support_portal.is_authenticated_person()
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT support_portal.setting_text('app.actor_kind') = 'user' $$;

CREATE FUNCTION support_portal.context_matches(
  p_owner_org_id text,
  p_application_id text,
  p_installation_id text,
  p_environment_id text,
  p_environment_kind text,
  p_tenant_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_tenant_id = support_portal.current_tenant_id()
     AND p_application_id = 'apoio'
     AND p_application_id = support_portal.setting_text('app.application_id')
     AND p_installation_id = support_portal.setting_text('app.installation_id')
     AND p_environment_id = support_portal.setting_text('app.environment_id')
     AND p_environment_kind = support_portal.setting_text('app.environment_kind')
     AND p_owner_org_id = support_portal.setting_text('app.owner_org_id')
$$;

CREATE TABLE support_portal.customer_account (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  name varchar(160) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 160),
  external_ref varchar(160),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  row_version bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);
CREATE UNIQUE INDEX customer_account_external_ref_uq
  ON support_portal.customer_account (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, external_ref)
  WHERE external_ref IS NOT NULL;

CREATE TABLE support_portal.account_member (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  account_id uuid NOT NULL,
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  role support_portal.member_role NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, account_id)
    REFERENCES support_portal.customer_account
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  CHECK ((active AND revoked_at IS NULL) OR (NOT active AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX account_member_active_uq
  ON support_portal.account_member (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, account_id, actor_id)
  WHERE active;

CREATE TABLE support_portal.staff_membership (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  role support_portal.staff_role NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CHECK ((active AND revoked_at IS NULL) OR (NOT active AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX staff_membership_active_uq
  ON support_portal.staff_membership (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, actor_id, role)
  WHERE active;

CREATE TABLE support_portal.support_team (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  name varchar(120) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  row_version bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, name)
);

CREATE TABLE support_portal.team_member (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  team_id uuid NOT NULL,
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  role support_portal.team_role NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, team_id)
    REFERENCES support_portal.support_team
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  CHECK ((active AND revoked_at IS NULL) OR (NOT active AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX team_member_active_uq
  ON support_portal.team_member (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, team_id, actor_id)
  WHERE active;

CREATE TABLE support_portal.category (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  name varchar(80) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  row_version bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, name)
);

CREATE FUNCTION support_portal.is_coordinator(p_tenant_id text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT support_portal.is_authenticated_person() AND EXISTS (
    SELECT 1 FROM support_portal.staff_membership m
    WHERE m.tenant_id = p_tenant_id
      AND m.actor_id = support_portal.current_actor_id()
      AND m.active
      AND m.role IN ('platform_admin', 'coordinator')
  )
$$;

CREATE FUNCTION support_portal.is_active_account_member(p_tenant_id text, p_account_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT support_portal.is_authenticated_person() AND EXISTS (
    SELECT 1 FROM support_portal.account_member m
    WHERE m.tenant_id = p_tenant_id
      AND m.account_id = p_account_id
      AND m.actor_id = support_portal.current_actor_id()
      AND m.active
  )
$$;

CREATE FUNCTION support_portal.is_active_team_member(p_tenant_id text, p_team_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT support_portal.is_authenticated_person() AND EXISTS (
    SELECT 1 FROM support_portal.team_member m
    WHERE m.tenant_id = p_tenant_id
      AND m.team_id = p_team_id
      AND m.actor_id = support_portal.current_actor_id()
      AND m.active
  )
$$;

CREATE TABLE support_portal.ticket (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  account_id uuid NOT NULL,
  requester_id text NOT NULL CHECK (support_portal.valid_context_identifier(requester_id)),
  team_id uuid,
  assignee_id text CHECK (assignee_id IS NULL OR support_portal.valid_context_identifier(assignee_id)),
  subject varchar(180) NOT NULL CHECK (char_length(btrim(subject)) BETWEEN 5 AND 180),
  status support_portal.ticket_status NOT NULL DEFAULT 'new',
  priority support_portal.ticket_priority NOT NULL DEFAULT 'normal',
  visibility support_portal.ticket_visibility NOT NULL,
  category_id uuid,
  resolution_summary text,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  row_version bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, account_id)
    REFERENCES support_portal.customer_account
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, team_id)
    REFERENCES support_portal.support_team
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, category_id)
    REFERENCES support_portal.category
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  CHECK (resolution_summary IS NULL OR char_length(resolution_summary) <= 20000)
);
CREATE INDEX ticket_tenant_status_updated_idx
  ON support_portal.ticket (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, status, updated_at DESC, id DESC);
CREATE INDEX ticket_account_updated_idx
  ON support_portal.ticket (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, account_id, updated_at DESC, id DESC);
CREATE INDEX ticket_team_updated_idx
  ON support_portal.ticket (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, team_id, updated_at DESC, id DESC);

CREATE FUNCTION support_portal.can_read_ticket(p_ticket_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM support_portal.ticket t
    WHERE t.id = p_ticket_id
      AND support_portal.context_matches(
        t.owner_org_id, t.application_id, t.installation_id, t.environment_id, t.environment_kind, t.tenant_id
      )
      AND (
        support_portal.is_coordinator(t.tenant_id)
        OR (t.requester_id = support_portal.current_actor_id()
            AND support_portal.is_active_account_member(t.tenant_id, t.account_id))
        OR (t.visibility = 'account' AND support_portal.is_active_account_member(t.tenant_id, t.account_id))
        OR (t.team_id IS NOT NULL AND support_portal.is_active_team_member(t.tenant_id, t.team_id))
      )
  )
$$;

CREATE FUNCTION support_portal.can_read_internal(p_ticket_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM support_portal.ticket t
    WHERE t.id = p_ticket_id
      AND support_portal.context_matches(
        t.owner_org_id, t.application_id, t.installation_id, t.environment_id, t.environment_kind, t.tenant_id
      )
      AND (
        support_portal.is_coordinator(t.tenant_id)
        OR (t.team_id IS NOT NULL AND support_portal.is_active_team_member(t.tenant_id, t.team_id))
      )
  )
$$;

CREATE TABLE support_portal.ticket_message (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  author_id text NOT NULL CHECK (support_portal.valid_context_identifier(author_id)),
  kind support_portal.message_kind NOT NULL,
  body text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 20000),
  client_message_id uuid NOT NULL,
  body_sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, client_message_id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);
CREATE INDEX ticket_message_thread_idx
  ON support_portal.ticket_message (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, created_at, id);

-- Idempotency receipts are application-persisted because the shared D0 package
-- provides pure helpers, not an online receipt service.
CREATE TABLE support_portal.ticket_operation_receipt (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  operation varchar(80) NOT NULL,
  idempotency_key varchar(160) NOT NULL,
  payload_sha256 char(64) NOT NULL,
  response_status smallint NOT NULL CHECK (response_status BETWEEN 200 AND 499),
  response_body jsonb NOT NULL,
  ticket_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, actor_id, operation, idempotency_key),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);

CREATE TABLE support_portal.ticket_intake_limit (
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  window_started_at timestamptz NOT NULL,
  ticket_count integer NOT NULL CHECK (ticket_count >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, actor_id)
);

CREATE TABLE support_portal.ticket_message_draft (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  author_id text NOT NULL CHECK (support_portal.valid_context_identifier(author_id)),
  kind support_portal.message_kind NOT NULL,
  body text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 20000),
  client_message_id uuid NOT NULL,
  draft_version bigint NOT NULL DEFAULT 1 CHECK (draft_version >= 1),
  published_message_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, published_message_id)
    REFERENCES support_portal.ticket_message
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, client_message_id)
);

CREATE TABLE support_portal.ticket_notification_intent (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  recipient_actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(recipient_actor_id)),
  event_type varchar(40) NOT NULL CHECK (event_type IN ('ticket_created', 'public_reply', 'status_changed', 'assigned')),
  row_version bigint NOT NULL CHECK (row_version >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, recipient_actor_id, event_type, row_version),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);

CREATE TABLE support_portal.ticket_attachment (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  message_id uuid NOT NULL,
  storage_object_id uuid NOT NULL,
  owner_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_id)),
  filename varchar(255) NOT NULL,
  mime_type varchar(160) NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes BETWEEN 1 AND 20971520),
  sha256 char(64) NOT NULL,
  scan_state text NOT NULL CHECK (scan_state IN ('pending', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, storage_object_id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, message_id)
    REFERENCES support_portal.ticket_message
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, id)
);
CREATE INDEX ticket_attachment_message_idx
  ON support_portal.ticket_attachment (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, message_id);

CREATE TABLE support_portal.ticket_transition (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  from_status support_portal.ticket_status,
  to_status support_portal.ticket_status NOT NULL,
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  reason text,
  expected_version bigint NOT NULL CHECK (expected_version >= 1),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);

CREATE TABLE support_portal.ticket_change_link (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  change_request_ref varchar(256) NOT NULL CHECK (support_portal.valid_context_identifier(change_request_ref)),
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, change_request_ref),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);

CREATE FUNCTION support_portal.enforce_ticket_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.row_version <> OLD.row_version + 1 THEN
    RAISE EXCEPTION 'row_version must increase by exactly one' USING ERRCODE = '40001';
  END IF;
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END
$$;
CREATE TRIGGER ticket_version_guard
BEFORE UPDATE ON support_portal.ticket
FOR EACH ROW EXECUTE FUNCTION support_portal.enforce_ticket_version();

CREATE FUNCTION support_portal.reject_immutable_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'append-only support history cannot be changed' USING ERRCODE = '55000';
END
$$;
CREATE TRIGGER ticket_message_immutable
BEFORE UPDATE OR DELETE ON support_portal.ticket_message
FOR EACH ROW EXECUTE FUNCTION support_portal.reject_immutable_mutation();
CREATE TRIGGER ticket_transition_immutable
BEFORE UPDATE OR DELETE ON support_portal.ticket_transition
FOR EACH ROW EXECUTE FUNCTION support_portal.reject_immutable_mutation();
CREATE TRIGGER ticket_operation_receipt_immutable
BEFORE UPDATE OR DELETE ON support_portal.ticket_operation_receipt
FOR EACH ROW EXECUTE FUNCTION support_portal.reject_immutable_mutation();

CREATE FUNCTION support_portal.enforce_draft_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.draft_version <> OLD.draft_version + 1 THEN
    RAISE EXCEPTION 'draft_version must increase by exactly one' USING ERRCODE = '40001';
  END IF;
  IF OLD.published_message_id IS NOT NULL THEN
    RAISE EXCEPTION 'a published draft is immutable' USING ERRCODE = '55000';
  END IF;
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END
$$;
CREATE TRIGGER ticket_message_draft_version
BEFORE UPDATE ON support_portal.ticket_message_draft
FOR EACH ROW EXECUTE FUNCTION support_portal.enforce_draft_version();

-- Organization, app, installation, environment ID, environment kind and tenant are checked in every RLS policy.
-- The runtime DB role must be separate from the migration owner and have no
-- BYPASSRLS. Revocation works because each request reads current membership.
DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'customer_account', 'account_member', 'staff_membership', 'support_team',
    'team_member', 'category', 'ticket', 'ticket_message', 'ticket_attachment',
    'ticket_transition', 'ticket_change_link', 'ticket_operation_receipt',
    'ticket_intake_limit', 'ticket_message_draft', 'ticket_notification_intent'
  ]
  LOOP
    EXECUTE format('ALTER TABLE support_portal.%I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE support_portal.%I FORCE ROW LEVEL SECURITY', table_name);
  END LOOP;
END
$$;

CREATE POLICY customer_account_select ON support_portal.customer_account
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (support_portal.is_coordinator(tenant_id) OR support_portal.is_active_account_member(tenant_id, id))
);
CREATE POLICY customer_account_insert ON support_portal.customer_account
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND created_by = support_portal.current_actor_id()
  AND support_portal.is_coordinator(tenant_id)
);
CREATE POLICY customer_account_update ON support_portal.customer_account
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
);

CREATE POLICY account_member_scope ON support_portal.account_member
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (actor_id = support_portal.current_actor_id() OR support_portal.is_coordinator(tenant_id))
);
CREATE POLICY account_member_manage ON support_portal.account_member
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY staff_membership_self ON support_portal.staff_membership
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
);
CREATE POLICY staff_membership_insert ON support_portal.staff_membership
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);
CREATE POLICY staff_membership_update ON support_portal.staff_membership
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);
CREATE POLICY staff_membership_delete ON support_portal.staff_membership
FOR DELETE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY support_team_scope ON support_portal.support_team
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (support_portal.is_coordinator(tenant_id) OR support_portal.is_active_team_member(tenant_id, id))
);
CREATE POLICY support_team_manage ON support_portal.support_team
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY team_member_scope ON support_portal.team_member
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (actor_id = support_portal.current_actor_id() OR support_portal.is_coordinator(tenant_id))
);
CREATE POLICY team_member_manage ON support_portal.team_member
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY category_scope ON support_portal.category
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (
    support_portal.is_coordinator(tenant_id)
    OR EXISTS (
      SELECT 1 FROM support_portal.team_member tm
      WHERE tm.tenant_id = category.tenant_id
        AND tm.actor_id = support_portal.current_actor_id()
        AND tm.active
    )
    OR EXISTS (
      SELECT 1 FROM support_portal.customer_account ca
      WHERE ca.tenant_id = category.tenant_id
        AND support_portal.is_active_account_member(ca.tenant_id, ca.id)
    )
  )
);
CREATE POLICY category_manage ON support_portal.category
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY ticket_scope_read ON support_portal.ticket
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (
    support_portal.is_coordinator(tenant_id)
    OR (requester_id = support_portal.current_actor_id()
        AND support_portal.is_active_account_member(tenant_id, account_id))
    OR (visibility = 'account' AND support_portal.is_active_account_member(tenant_id, account_id))
    OR (team_id IS NOT NULL AND support_portal.is_active_team_member(tenant_id, team_id))
  )
);
CREATE POLICY ticket_scope_insert ON support_portal.ticket
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND created_by = support_portal.current_actor_id()
  AND (
    (requester_id = support_portal.current_actor_id()
      AND support_portal.is_active_account_member(tenant_id, account_id))
    OR support_portal.is_coordinator(tenant_id)
    OR (team_id IS NOT NULL AND support_portal.is_active_team_member(tenant_id, team_id))
  )
);
CREATE POLICY ticket_staff_update ON support_portal.ticket
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (
    support_portal.is_coordinator(tenant_id)
    OR (team_id IS NOT NULL AND support_portal.is_active_team_member(tenant_id, team_id))
  )
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (
    support_portal.is_coordinator(tenant_id)
    OR (team_id IS NOT NULL AND support_portal.is_active_team_member(tenant_id, team_id))
  )
);

CREATE POLICY ticket_customer_reply_update ON support_portal.ticket
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND status = 'waiting_customer'
  AND (
    (requester_id = support_portal.current_actor_id()
      AND support_portal.is_active_account_member(tenant_id, account_id))
    OR (visibility = 'account' AND support_portal.is_active_account_member(tenant_id, account_id))
  )
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND status = 'in_progress'
  AND (
    (requester_id = support_portal.current_actor_id()
      AND support_portal.is_active_account_member(tenant_id, account_id))
    OR (visibility = 'account' AND support_portal.is_active_account_member(tenant_id, account_id))
  )
);

CREATE POLICY ticket_message_read ON support_portal.ticket_message
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);
CREATE POLICY ticket_message_insert ON support_portal.ticket_message
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);

CREATE POLICY ticket_attachment_read ON support_portal.ticket_attachment
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_ticket(ticket_id)
  AND EXISTS (
    SELECT 1 FROM support_portal.ticket_message m
    WHERE m.id = ticket_attachment.message_id
      AND m.ticket_id = ticket_attachment.ticket_id
      AND (m.kind = 'public' OR support_portal.can_read_internal(ticket_attachment.ticket_id))
  )
);
-- Until a D0 FileAsset adapter verifies ScannerAttestation v2, no application
-- role may create attachment metadata or assert that bytes are CLEAN.
CREATE POLICY ticket_attachment_insert ON support_portal.ticket_attachment
FOR INSERT WITH CHECK (false);

CREATE POLICY ticket_transition_staff_read ON support_portal.ticket_transition
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_internal(ticket_id)
);
CREATE POLICY ticket_transition_staff_insert ON support_portal.ticket_transition
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.can_read_internal(ticket_id)
);
CREATE POLICY ticket_transition_customer_reply_insert ON support_portal.ticket_transition
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND from_status = 'waiting_customer'
  AND to_status = 'in_progress'
  AND support_portal.can_read_ticket(ticket_id)
  AND NOT support_portal.can_read_internal(ticket_id)
);

CREATE POLICY ticket_change_link_read ON support_portal.ticket_change_link
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_ticket(ticket_id)
);
CREATE POLICY ticket_change_link_insert ON support_portal.ticket_change_link
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND created_by = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
);

CREATE POLICY ticket_operation_receipt_select ON support_portal.ticket_operation_receipt
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
  AND (ticket_id IS NULL OR support_portal.can_read_ticket(ticket_id))
);
CREATE POLICY ticket_operation_receipt_insert ON support_portal.ticket_operation_receipt
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
  AND (ticket_id IS NULL OR support_portal.can_read_ticket(ticket_id))
);

CREATE POLICY ticket_intake_limit_self ON support_portal.ticket_intake_limit
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
);

CREATE POLICY ticket_message_draft_select ON support_portal.ticket_message_draft
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);
CREATE POLICY ticket_message_draft_insert ON support_portal.ticket_message_draft
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);
CREATE POLICY ticket_message_draft_update ON support_portal.ticket_message_draft
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND published_message_id IS NULL
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);

CREATE POLICY ticket_notification_intent_select ON support_portal.ticket_notification_intent
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND recipient_actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
  AND support_portal.can_read_ticket(ticket_id)
);
CREATE POLICY ticket_notification_intent_insert ON support_portal.ticket_notification_intent
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_authenticated_person()
  AND support_portal.can_read_ticket(ticket_id)
);

COMMIT;


$$;

CREATE TYPE support_portal.ticket_status AS ENUM (
  'new', 'triaged', 'in_progress', 'waiting_customer', 'resolved', 'closed', 'cancelled'
);
CREATE TYPE support_portal.ticket_priority AS ENUM ('low', 'normal', 'high', 'urgent');
CREATE TYPE support_portal.ticket_visibility AS ENUM ('requester', 'account');
CREATE TYPE support_portal.message_kind AS ENUM ('public', 'internal');
CREATE TYPE support_portal.member_role AS ENUM ('customer_admin', 'customer_member');
CREATE TYPE support_portal.staff_role AS ENUM ('platform_admin', 'coordinator');
CREATE TYPE support_portal.team_role AS ENUM ('agent', 'coordinator');

CREATE FUNCTION support_portal.setting_text(setting_name text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting(setting_name, true), '')
$$;

CREATE FUNCTION support_portal.current_tenant_id()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT support_portal.setting_text('app.data_tenant_id') $$;

CREATE FUNCTION support_portal.current_actor_id()
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT support_portal.setting_text('app.actor_id') $$;

CREATE FUNCTION support_portal.is_authenticated_person()
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT support_portal.setting_text('app.actor_kind') = 'user' $$;

CREATE FUNCTION support_portal.context_matches(
  p_owner_org_id text,
  p_application_id text,
  p_installation_id text,
  p_environment_id text,
  p_environment_kind text,
  p_tenant_id text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT p_tenant_id = support_portal.current_tenant_id()
     AND p_application_id = 'apoio'
     AND p_application_id = support_portal.setting_text('app.application_id')
     AND p_installation_id = support_portal.setting_text('app.installation_id')
     AND p_environment_id = support_portal.setting_text('app.environment_id')
     AND p_environment_kind = support_portal.setting_text('app.environment_kind')
     AND p_owner_org_id = support_portal.setting_text('app.owner_org_id')
$$;

CREATE TABLE support_portal.customer_account (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  name varchar(160) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 160),
  external_ref varchar(160),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  row_version bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);
CREATE UNIQUE INDEX customer_account_external_ref_uq
  ON support_portal.customer_account (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, external_ref)
  WHERE external_ref IS NOT NULL;

CREATE TABLE support_portal.account_member (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  account_id uuid NOT NULL,
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  role support_portal.member_role NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, account_id)
    REFERENCES support_portal.customer_account
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  CHECK ((active AND revoked_at IS NULL) OR (NOT active AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX account_member_active_uq
  ON support_portal.account_member (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, account_id, actor_id)
  WHERE active;

CREATE TABLE support_portal.staff_membership (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  role support_portal.staff_role NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CHECK ((active AND revoked_at IS NULL) OR (NOT active AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX staff_membership_active_uq
  ON support_portal.staff_membership (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, actor_id, role)
  WHERE active;

CREATE TABLE support_portal.support_team (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  name varchar(120) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 120),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  row_version bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, name)
);

CREATE TABLE support_portal.team_member (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  team_id uuid NOT NULL,
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  role support_portal.team_role NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, team_id)
    REFERENCES support_portal.support_team
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  CHECK ((active AND revoked_at IS NULL) OR (NOT active AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX team_member_active_uq
  ON support_portal.team_member (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, team_id, actor_id)
  WHERE active;

CREATE TABLE support_portal.category (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  name varchar(80) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 80),
  active boolean NOT NULL DEFAULT true,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  row_version bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, name)
);

CREATE FUNCTION support_portal.is_coordinator(p_tenant_id text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT support_portal.is_authenticated_person() AND EXISTS (
    SELECT 1 FROM support_portal.staff_membership m
    WHERE m.tenant_id = p_tenant_id
      AND m.actor_id = support_portal.current_actor_id()
      AND m.active
      AND m.role IN ('platform_admin', 'coordinator')
  )
$$;

CREATE FUNCTION support_portal.is_active_account_member(p_tenant_id text, p_account_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT support_portal.is_authenticated_person() AND EXISTS (
    SELECT 1 FROM support_portal.account_member m
    WHERE m.tenant_id = p_tenant_id
      AND m.account_id = p_account_id
      AND m.actor_id = support_portal.current_actor_id()
      AND m.active
  )
$$;

CREATE FUNCTION support_portal.is_active_team_member(p_tenant_id text, p_team_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT support_portal.is_authenticated_person() AND EXISTS (
    SELECT 1 FROM support_portal.team_member m
    WHERE m.tenant_id = p_tenant_id
      AND m.team_id = p_team_id
      AND m.actor_id = support_portal.current_actor_id()
      AND m.active
  )
$$;

CREATE TABLE support_portal.ticket (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  account_id uuid NOT NULL,
  requester_id text NOT NULL CHECK (support_portal.valid_context_identifier(requester_id)),
  team_id uuid,
  assignee_id text CHECK (assignee_id IS NULL OR support_portal.valid_context_identifier(assignee_id)),
  subject varchar(180) NOT NULL CHECK (char_length(btrim(subject)) BETWEEN 5 AND 180),
  status support_portal.ticket_status NOT NULL DEFAULT 'new',
  priority support_portal.ticket_priority NOT NULL DEFAULT 'normal',
  visibility support_portal.ticket_visibility NOT NULL,
  category_id uuid,
  resolution_summary text,
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  row_version bigint NOT NULL DEFAULT 1 CHECK (row_version >= 1),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, account_id)
    REFERENCES support_portal.customer_account
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, team_id)
    REFERENCES support_portal.support_team
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, category_id)
    REFERENCES support_portal.category
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  CHECK (resolution_summary IS NULL OR char_length(resolution_summary) <= 20000)
);
CREATE INDEX ticket_tenant_status_updated_idx
  ON support_portal.ticket (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, status, updated_at DESC, id DESC);
CREATE INDEX ticket_account_updated_idx
  ON support_portal.ticket (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, account_id, updated_at DESC, id DESC);
CREATE INDEX ticket_team_updated_idx
  ON support_portal.ticket (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, team_id, updated_at DESC, id DESC);

CREATE FUNCTION support_portal.can_read_ticket(p_ticket_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM support_portal.ticket t
    WHERE t.id = p_ticket_id
      AND support_portal.context_matches(
        t.owner_org_id, t.application_id, t.installation_id, t.environment_id, t.environment_kind, t.tenant_id
      )
      AND (
        support_portal.is_coordinator(t.tenant_id)
        OR (t.requester_id = support_portal.current_actor_id()
            AND support_portal.is_active_account_member(t.tenant_id, t.account_id))
        OR (t.visibility = 'account' AND support_portal.is_active_account_member(t.tenant_id, t.account_id))
        OR (t.team_id IS NOT NULL AND support_portal.is_active_team_member(t.tenant_id, t.team_id))
      )
  )
$$;

CREATE FUNCTION support_portal.can_read_internal(p_ticket_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM support_portal.ticket t
    WHERE t.id = p_ticket_id
      AND support_portal.context_matches(
        t.owner_org_id, t.application_id, t.installation_id, t.environment_id, t.environment_kind, t.tenant_id
      )
      AND (
        support_portal.is_coordinator(t.tenant_id)
        OR (t.team_id IS NOT NULL AND support_portal.is_active_team_member(t.tenant_id, t.team_id))
      )
  )
$$;

CREATE TABLE support_portal.ticket_message (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  author_id text NOT NULL CHECK (support_portal.valid_context_identifier(author_id)),
  kind support_portal.message_kind NOT NULL,
  body text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 20000),
  client_message_id uuid NOT NULL,
  body_sha256 char(64) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, client_message_id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);
CREATE INDEX ticket_message_thread_idx
  ON support_portal.ticket_message (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, created_at, id);

-- Idempotency receipts are application-persisted because the shared D0 package
-- provides pure helpers, not an online receipt service.
CREATE TABLE support_portal.ticket_operation_receipt (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  operation varchar(80) NOT NULL,
  idempotency_key varchar(160) NOT NULL,
  payload_sha256 char(64) NOT NULL,
  response_status smallint NOT NULL CHECK (response_status BETWEEN 200 AND 499),
  response_body jsonb NOT NULL,
  ticket_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, actor_id, operation, idempotency_key),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);

CREATE TABLE support_portal.ticket_intake_limit (
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  window_started_at timestamptz NOT NULL,
  ticket_count integer NOT NULL CHECK (ticket_count >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, actor_id)
);

CREATE TABLE support_portal.ticket_message_draft (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  author_id text NOT NULL CHECK (support_portal.valid_context_identifier(author_id)),
  kind support_portal.message_kind NOT NULL,
  body text NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 20000),
  client_message_id uuid NOT NULL,
  draft_version bigint NOT NULL DEFAULT 1 CHECK (draft_version >= 1),
  published_message_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, published_message_id)
    REFERENCES support_portal.ticket_message
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, client_message_id)
);

CREATE TABLE support_portal.ticket_notification_intent (
  id uuid PRIMARY KEY,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  recipient_actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(recipient_actor_id)),
  event_type varchar(40) NOT NULL CHECK (event_type IN ('ticket_created', 'public_reply', 'status_changed', 'assigned')),
  row_version bigint NOT NULL CHECK (row_version >= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, recipient_actor_id, event_type, row_version),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);

CREATE TABLE support_portal.ticket_attachment (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  message_id uuid NOT NULL,
  storage_object_id uuid NOT NULL,
  owner_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_id)),
  filename varchar(255) NOT NULL,
  mime_type varchar(160) NOT NULL,
  size_bytes bigint NOT NULL CHECK (size_bytes BETWEEN 1 AND 20971520),
  sha256 char(64) NOT NULL,
  scan_state text NOT NULL CHECK (scan_state IN ('pending', 'rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, storage_object_id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, message_id)
    REFERENCES support_portal.ticket_message
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, id)
);
CREATE INDEX ticket_attachment_message_idx
  ON support_portal.ticket_attachment (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, message_id);

CREATE TABLE support_portal.ticket_transition (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  from_status support_portal.ticket_status,
  to_status support_portal.ticket_status NOT NULL,
  actor_id text NOT NULL CHECK (support_portal.valid_context_identifier(actor_id)),
  reason text,
  expected_version bigint NOT NULL CHECK (expected_version >= 1),
  occurred_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);

CREATE TABLE support_portal.ticket_change_link (
  id uuid NOT NULL,
  owner_org_id text NOT NULL CHECK (support_portal.valid_context_identifier(owner_org_id)),
  application_id text NOT NULL CHECK (application_id = 'apoio'),
  installation_id text NOT NULL CHECK (support_portal.valid_context_identifier(installation_id)),
  environment_id text NOT NULL CHECK (support_portal.valid_context_identifier(environment_id)),
  environment_kind text NOT NULL DEFAULT support_portal.setting_text('app.environment_kind')
    CHECK (environment_kind IN ('test', 'production')),
  tenant_id text NOT NULL CHECK (support_portal.valid_context_identifier(tenant_id)),
  ticket_id uuid NOT NULL,
  change_request_ref varchar(256) NOT NULL CHECK (support_portal.valid_context_identifier(change_request_ref)),
  created_by text NOT NULL CHECK (support_portal.valid_context_identifier(created_by)),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id),
  UNIQUE (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id, change_request_ref),
  FOREIGN KEY (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, ticket_id)
    REFERENCES support_portal.ticket
      (owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id, id)
);

CREATE FUNCTION support_portal.enforce_ticket_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.row_version <> OLD.row_version + 1 THEN
    RAISE EXCEPTION 'row_version must increase by exactly one' USING ERRCODE = '40001';
  END IF;
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END
$$;
CREATE TRIGGER ticket_version_guard
BEFORE UPDATE ON support_portal.ticket
FOR EACH ROW EXECUTE FUNCTION support_portal.enforce_ticket_version();

CREATE FUNCTION support_portal.reject_immutable_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'append-only support history cannot be changed' USING ERRCODE = '55000';
END
$$;
CREATE TRIGGER ticket_message_immutable
BEFORE UPDATE OR DELETE ON support_portal.ticket_message
FOR EACH ROW EXECUTE FUNCTION support_portal.reject_immutable_mutation();
CREATE TRIGGER ticket_transition_immutable
BEFORE UPDATE OR DELETE ON support_portal.ticket_transition
FOR EACH ROW EXECUTE FUNCTION support_portal.reject_immutable_mutation();
CREATE TRIGGER ticket_operation_receipt_immutable
BEFORE UPDATE OR DELETE ON support_portal.ticket_operation_receipt
FOR EACH ROW EXECUTE FUNCTION support_portal.reject_immutable_mutation();

CREATE FUNCTION support_portal.enforce_draft_version()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.draft_version <> OLD.draft_version + 1 THEN
    RAISE EXCEPTION 'draft_version must increase by exactly one' USING ERRCODE = '40001';
  END IF;
  IF OLD.published_message_id IS NOT NULL THEN
    RAISE EXCEPTION 'a published draft is immutable' USING ERRCODE = '55000';
  END IF;
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END
$$;
CREATE TRIGGER ticket_message_draft_version
BEFORE UPDATE ON support_portal.ticket_message_draft
FOR EACH ROW EXECUTE FUNCTION support_portal.enforce_draft_version();

-- Organization, app, installation, environment ID, environment kind and tenant are checked in every RLS policy.
-- The runtime DB role must be separate from the migration owner and have no
-- BYPASSRLS. Revocation works because each request reads current membership.
DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'customer_account', 'account_member', 'staff_membership', 'support_team',
    'team_member', 'category', 'ticket', 'ticket_message', 'ticket_attachment',
    'ticket_transition', 'ticket_change_link', 'ticket_operation_receipt',
    'ticket_intake_limit', 'ticket_message_draft', 'ticket_notification_intent'
  ]
  LOOP
    EXECUTE format('ALTER TABLE support_portal.%I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE support_portal.%I FORCE ROW LEVEL SECURITY', table_name);
  END LOOP;
END
$$;

CREATE POLICY customer_account_select ON support_portal.customer_account
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (support_portal.is_coordinator(tenant_id) OR support_portal.is_active_account_member(tenant_id, id))
);
CREATE POLICY customer_account_insert ON support_portal.customer_account
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND created_by = support_portal.current_actor_id()
  AND support_portal.is_coordinator(tenant_id)
);
CREATE POLICY customer_account_update ON support_portal.customer_account
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
);

CREATE POLICY account_member_scope ON support_portal.account_member
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (actor_id = support_portal.current_actor_id() OR support_portal.is_coordinator(tenant_id))
);
CREATE POLICY account_member_manage ON support_portal.account_member
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY staff_membership_self ON support_portal.staff_membership
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
);
CREATE POLICY staff_membership_insert ON support_portal.staff_membership
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);
CREATE POLICY staff_membership_update ON support_portal.staff_membership
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);
CREATE POLICY staff_membership_delete ON support_portal.staff_membership
FOR DELETE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY support_team_scope ON support_portal.support_team
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (support_portal.is_coordinator(tenant_id) OR support_portal.is_active_team_member(tenant_id, id))
);
CREATE POLICY support_team_manage ON support_portal.support_team
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY team_member_scope ON support_portal.team_member
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (actor_id = support_portal.current_actor_id() OR support_portal.is_coordinator(tenant_id))
);
CREATE POLICY team_member_manage ON support_portal.team_member
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY category_scope ON support_portal.category
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (
    support_portal.is_coordinator(tenant_id)
    OR EXISTS (
      SELECT 1 FROM support_portal.team_member tm
      WHERE tm.tenant_id = category.tenant_id
        AND tm.actor_id = support_portal.current_actor_id()
        AND tm.active
    )
    OR EXISTS (
      SELECT 1 FROM support_portal.customer_account ca
      WHERE ca.tenant_id = category.tenant_id
        AND support_portal.is_active_account_member(ca.tenant_id, ca.id)
    )
  )
);
CREATE POLICY category_manage ON support_portal.category
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_coordinator(tenant_id)
);

CREATE POLICY ticket_scope_read ON support_portal.ticket
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (
    support_portal.is_coordinator(tenant_id)
    OR (requester_id = support_portal.current_actor_id()
        AND support_portal.is_active_account_member(tenant_id, account_id))
    OR (visibility = 'account' AND support_portal.is_active_account_member(tenant_id, account_id))
    OR (team_id IS NOT NULL AND support_portal.is_active_team_member(tenant_id, team_id))
  )
);
CREATE POLICY ticket_scope_insert ON support_portal.ticket
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND created_by = support_portal.current_actor_id()
  AND (
    (requester_id = support_portal.current_actor_id()
      AND support_portal.is_active_account_member(tenant_id, account_id))
    OR support_portal.is_coordinator(tenant_id)
    OR (team_id IS NOT NULL AND support_portal.is_active_team_member(tenant_id, team_id))
  )
);
CREATE POLICY ticket_staff_update ON support_portal.ticket
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (
    support_portal.is_coordinator(tenant_id)
    OR (team_id IS NOT NULL AND support_portal.is_active_team_member(tenant_id, team_id))
  )
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND (
    support_portal.is_coordinator(tenant_id)
    OR (team_id IS NOT NULL AND support_portal.is_active_team_member(tenant_id, team_id))
  )
);

CREATE POLICY ticket_customer_reply_update ON support_portal.ticket
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND status = 'waiting_customer'
  AND (
    (requester_id = support_portal.current_actor_id()
      AND support_portal.is_active_account_member(tenant_id, account_id))
    OR (visibility = 'account' AND support_portal.is_active_account_member(tenant_id, account_id))
  )
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND status = 'in_progress'
  AND (
    (requester_id = support_portal.current_actor_id()
      AND support_portal.is_active_account_member(tenant_id, account_id))
    OR (visibility = 'account' AND support_portal.is_active_account_member(tenant_id, account_id))
  )
);

CREATE POLICY ticket_message_read ON support_portal.ticket_message
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);
CREATE POLICY ticket_message_insert ON support_portal.ticket_message
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);

CREATE POLICY ticket_attachment_read ON support_portal.ticket_attachment
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_ticket(ticket_id)
  AND EXISTS (
    SELECT 1 FROM support_portal.ticket_message m
    WHERE m.id = ticket_attachment.message_id
      AND m.ticket_id = ticket_attachment.ticket_id
      AND (m.kind = 'public' OR support_portal.can_read_internal(ticket_attachment.ticket_id))
  )
);
-- Until a D0 FileAsset adapter verifies ScannerAttestation v2, no application
-- role may create attachment metadata or assert that bytes are CLEAN.
CREATE POLICY ticket_attachment_insert ON support_portal.ticket_attachment
FOR INSERT WITH CHECK (false);

CREATE POLICY ticket_transition_staff_read ON support_portal.ticket_transition
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_internal(ticket_id)
);
CREATE POLICY ticket_transition_staff_insert ON support_portal.ticket_transition
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.can_read_internal(ticket_id)
);
CREATE POLICY ticket_transition_customer_reply_insert ON support_portal.ticket_transition
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND from_status = 'waiting_customer'
  AND to_status = 'in_progress'
  AND support_portal.can_read_ticket(ticket_id)
  AND NOT support_portal.can_read_internal(ticket_id)
);

CREATE POLICY ticket_change_link_read ON support_portal.ticket_change_link
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_ticket(ticket_id)
);
CREATE POLICY ticket_change_link_insert ON support_portal.ticket_change_link
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND created_by = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
);

CREATE POLICY ticket_operation_receipt_select ON support_portal.ticket_operation_receipt
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
  AND (ticket_id IS NULL OR support_portal.can_read_ticket(ticket_id))
);
CREATE POLICY ticket_operation_receipt_insert ON support_portal.ticket_operation_receipt
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
  AND (ticket_id IS NULL OR support_portal.can_read_ticket(ticket_id))
);

CREATE POLICY ticket_intake_limit_self ON support_portal.ticket_intake_limit
FOR ALL USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
);

CREATE POLICY ticket_message_draft_select ON support_portal.ticket_message_draft
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);
CREATE POLICY ticket_message_draft_insert ON support_portal.ticket_message_draft
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);
CREATE POLICY ticket_message_draft_update ON support_portal.ticket_message_draft
FOR UPDATE USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND published_message_id IS NULL
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
) WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND author_id = support_portal.current_actor_id()
  AND support_portal.can_read_ticket(ticket_id)
  AND (kind = 'public' OR support_portal.can_read_internal(ticket_id))
);

CREATE POLICY ticket_notification_intent_select ON support_portal.ticket_notification_intent
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND recipient_actor_id = support_portal.current_actor_id()
  AND support_portal.is_authenticated_person()
  AND support_portal.can_read_ticket(ticket_id)
);
CREATE POLICY ticket_notification_intent_insert ON support_portal.ticket_notification_intent
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.is_authenticated_person()
  AND support_portal.can_read_ticket(ticket_id)
);

COMMIT;

