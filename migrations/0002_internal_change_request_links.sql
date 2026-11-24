BEGIN;

-- Software change requests are internal support history. Customers cannot read
-- external references or attach one to their own ticket.
DROP POLICY ticket_change_link_read ON support_portal.ticket_change_link;
CREATE POLICY ticket_change_link_read ON support_portal.ticket_change_link
FOR SELECT USING (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND support_portal.can_read_internal(ticket_id)
);

DROP POLICY ticket_change_link_insert ON support_portal.ticket_change_link;
CREATE POLICY ticket_change_link_insert ON support_portal.ticket_change_link
FOR INSERT WITH CHECK (
  support_portal.context_matches(owner_org_id, application_id, installation_id, environment_id, environment_kind, tenant_id)
  AND created_by = support_portal.current_actor_id()
  AND support_portal.can_read_internal(ticket_id)
);

COMMIT;
