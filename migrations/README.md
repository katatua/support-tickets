# Migrações

0001_support_portal.sql is the app-specific D1 schema draft. It assumes the
common identity and file services are separate and does not create user credentials,
storage buckets, audit tables, command receipts, jobs, or an outbox. Those are owned
by D0.

The database session is populated from the server-authenticated request context,
inside each transaction. Never derive context variables from browser input. Keep the
runtime role separate from the migration owner and without BYPASSRLS.

The migration and `tests/postgres_rls.sql` were applied to a disposable PostgreSQL
16.15 instance. The integration script uses a non-login runtime role without
`BYPASSRLS`, inserts only synthetic fixtures, checks customer and team views, and
rolls the fixture transaction back. This proves the database policies in isolation;
it does not prove the D0 request middleware, HTTP routes, or private object storage.

Run the migration and RLS proof only against a disposable database:

```sh
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0001_support_portal.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/postgres_rls.sql
```

Review the migration against the exact D0 transaction API before connecting any
runtime. The runtime role must be separate from the migration owner and have no
`BYPASSRLS` privilege.

