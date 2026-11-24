# Migrações

`0001_support_portal.sql` is the app-specific D1 schema draft. It does not create
user credentials or object storage. Operation receipts and notification intents in
this migration are app records; they are not the common D0 receipt/outbox dispatcher.
The file-service binding, malware scanner, delivery worker and external integration
remain unavailable until their common runtime contracts are published and connected.

The database session is populated from the server-authenticated request context,
inside each transaction. Opaque D0 identifiers are stored as text without a local length
cap; the adapter rejects empty/whitespace-only values and surrounding whitespace but
preserves internal characters, matching the pinned D0 parser. RLS plus composite
keys/foreign keys include owner organization, fixed app ID, installation, environment
ID, environment kind, and data tenant. Never derive context variables from browser input. Keep the
runtime role separate from the migration owner and without BYPASSRLS.

The migration and `tests/postgres_rls.sql` are proved against a disposable PostgreSQL
16.15 instance; rerun that proof after migration edits. The SQL proof uses a non-login runtime role without `BYPASSRLS`,
inserts only synthetic fixtures, checks customer and team views, and checks that a
service actor cannot inherit a person's membership. It rolls back its fixtures. This
proves the database policies in isolation; it does not prove the D0 request middleware,
the Python/PostgreSQL adapter, or private object storage.

Run the migration and RLS proof only against a disposable database:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0001_support_portal.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/postgres_rls.sql
```

Review the migration against the exact D0 transaction API before connecting any
runtime. The runtime role must be separate from the migration owner and have no
`BYPASSRLS` privilege.

