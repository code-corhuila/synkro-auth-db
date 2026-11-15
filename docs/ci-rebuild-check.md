# Ci rebuild check

Detailed procedures and delivery notes moved from the repository README at
[source 2b62522](https://github.com/code-corhuila/synkro-auth-db/blob/2b6252237bd5a4911ec8db13e99008a059d95e42/README.md).
Recorded execution results retain their original scope; moving them does not
constitute a new execution or certify a different revision.

Run commands from the repository root unless a step explicitly changes directory.

## The CI rebuild check

`.github/workflows/db-ci.yml` runs on every push and PR to `develop`, `qa` and `main`, against an
empty `postgres:16-alpine`, using the same Flyway image as `deploy/compose.yml` (keep both tags equal).
It proves, in order:

1. **Migrate from empty** applies every `V*.sql` in the repository (the applied count is checked:
   Flyway exits 0 with zero migrations when it cannot find its config).
2. **Migrate again** is a no-op (`No migration necessary`).
3. **Privileges:** `auth_app` has `USAGE` on `auth_schema`, and on each of the four original tables
   `SELECT`, `INSERT` and `UPDATE` but never `DELETE`, which it inherits from `auth_writer`. On
   `user_creation_audit` it has only `SELECT` and `INSERT`.
   `auth_reader` can read the tables and cannot insert into them. `auth_app` cannot delete from
   any table of `auth_schema`, including one added later.
4. **Constraints:** every CHECK, unique, foreign key and NOT NULL rule of `system_user`,
   `refresh_token`, `service_token`, `idempotency_key` and `user_creation_audit` rejects its bad rows with the expected
   SQLSTATE and constraint (or column) name, and accepts the valid rows next to them. The steps
   delete the rows they insert, children first.
5. **Indexes:** `idx_refresh_token_user_id` and `idx_service_token_issued_by` exist on their
   `user_id` and `issued_by` columns, and every foreign key of `auth_schema` has an index that
   starts with its column.
6. **Rollbacks** apply cleanly, highest version to lowest, and leave none of `auth_schema`,
   `auth_writer` or `auth_reader` behind.
7. **Rebuild:** after dropping `auth_schema.flyway_schema_history`, migrating from scratch succeeds again.
8. **Audit table (`AUTH-AUDIT-01`):** the steps named `AUTH-AUDIT-01` check that
   `user_creation_audit` has exactly its specified columns and constraints; that valid records are
   accepted and invalid actors, operations and missing fields are rejected; that its exact ACL is
   append-only; that a real login as `auth_app` (not a `SET ROLE`) can read and append but is denied
   `UPDATE`, `DELETE`, `TRUNCATE`, structural `ALTER` and every constraint bypass it tries; that a
   role of another domain cannot see or touch the table; that every `V` has its `U`; and that rolling the
   audit migrations back and applying them again leaves the checksums of `V001` to `V013` and the
   existing data unchanged.

9. **Password reset audit (`AUTH-RESET-AUDIT-01`):** the steps with that name check that `password_reset_audit`
   has exactly its specified columns, constraints and indexes; that valid records are accepted (many resets per
   user, the same key text under two actors) and that invalid operations, outcomes, keys, self-resets and missing
   fields are rejected; that its exact ACL is append-only; that a real login as `auth_app` can run the reset unit
   (audit claim, password change, refresh revocation) and is denied `UPDATE`, `DELETE`, `TRUNCATE` and structural
   changes; and that a role of another domain cannot see or touch it.

10. **Password reset receipt (`AUTH-RESET-RECEIPT-01`):** the steps with that name check that
    `password_reset_receipt` has exactly its columns, constraints and indexes and that the cleanup function is a
    caller-privileges function returning only a count; that it accepts bcrypt strings and refuses a password, a fast
    hash, a malformed string or a missing column; that `auth_reader` and the other-domain role hold no privilege on
    it and nobody but the owner can run the cleanup; that a real login as `auth_app` commits the reset, the
    revocation, the audit and the receipt as one unit, that a failure at the receipt leaves no earlier effect, and
    that it is denied `UPDATE`, `DELETE`, `TRUNCATE` and the cleanup; and that the cleanup removes only expired
    receipts, in bounded batches, keeps every audit record and every consumed key, and rejects invalid batch
    sizes. Expiry is tested by setting `expires_at`, never by sleeping. The rollback-and-reapply step covers the
    thirteen audit and receipt migrations, `V014` to `V026`.

The assertions live in [`.github/scripts/db-checks.sh`](../.github/scripts/db-checks.sh) (the helpers) and
[`.github/scripts/password-reset-audit-checks.sh`](../.github/scripts/password-reset-audit-checks.sh) (the
`AUTH-RESET-AUDIT-01` and `AUTH-RESET-RECEIPT-01` checks); each check step sources them from the repository root.

To reproduce it by hand against the stand-in database above (bash, repository root):

```bash
docker run --rm --network platform -e PGPASSWORD=dev_admin_pw postgres:16-alpine psql -h synkro-db -U postgres -d synkro -tAc "SELECT has_schema_privilege('auth_app', 'auth_schema', 'USAGE');"
```

The history table lives in `auth_schema`, so drop it before the rollbacks, as CI does:

```bash
docker exec synkro-db psql -U postgres -d synkro -c "DROP TABLE IF EXISTS auth_schema.flyway_schema_history;"
```

```bash
find 05_rollbacks -name 'U*.sql' -printf '%f\t%p\n' | sort -r | cut -f2 | while read -r f; do echo "Applying $f"; docker exec -i synkro-db psql -U postgres -d synkro -v ON_ERROR_STOP=1 < "$f" || break; done
```

Then migrate again (step 3 above). The first command must print `t`; the loop must apply `U017`
down to `U001`, in that order, without errors.

To run the whole workflow locally, unchanged, use [`act`](https://github.com/nektos/act):

```bash
act push -W .github/workflows/db-ci.yml -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

The workflow's PostgreSQL service listens on host port 5432, so stop any PostgreSQL that already
uses that port before running it.
