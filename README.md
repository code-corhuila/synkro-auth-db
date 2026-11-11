# synkro-auth-db

> auth bounded context: database (schema, seeds, migrations)

Part of the **SynkroTech SAS Sales Management System** — organization `code-corhuila`.
Governance and documentation live in [`synkro-docs`](https://github.com/code-corhuila/synkro-docs).

## Branching

Three permanent branches. **None of them accepts a direct commit** — you enter through a child
branch and leave through a Pull Request.

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/...  hotfix/...
```

Promotion happens **by re-application** (`git cherry-pick -x`), never by merging one permanent
branch into another: `merge develop -> qa` and `merge qa -> main` do not exist in this model.

`main` requires **1 approval from `ariel5253`**. On `develop` and `qa` the team sets its own review
rule.

Full policy: `00-governance/branching-policy.md` in `synkro-docs`.

## Layout

The tree is the team's layout convention for every `-db` repository: one folder per kind of change
(structure, data, privileges, transaction control) plus one for the rollbacks. Flyway orders
migrations by version number, never by path, so the folders only group files by purpose and keep
each review scoped to one concern. Every family folder exists from day one, even when empty
(`.gitkeep`), so the layout never has to be renamed or renumbered when a family is first used.

| Folder | Content | Run by |
|---|---|---|
| `01_ddl/` | schemas, types, tables, alters, views, functions, procedures, triggers, indexes | Flyway |
| `02_dml/` | inserts, updates, deletes, upserts, patches | Flyway |
| `03_dcl/` | roles, grants, row-level policies | Flyway |
| `04_tcl/` | transaction blocks, manual recoveries, release tags | Flyway |
| `05_rollbacks/` | one `U` script per `V` migration, mirroring its folder | `psql` only (CI and manual recovery) |
| `deploy/compose.yml` | the migration runner (no database: that is `synkro-infra-postgres`) | Docker Compose |

Rules every new migration follows:

- **One version sequence for the whole repository** — `V001`, `V002`, `V003`, … — whatever folder
  the file lives in. Take the next free number; never renumber.
- **Name:** `V<NNN>__<description>.sql` (two underscores). `validateMigrationNaming` rejects anything else.
- **Every `V` has a `U`** with the same number and description, at the mirrored path under
  `05_rollbacks/` (e.g. `03_dcl/01_grants/V003__grants.sql` → `05_rollbacks/03_dcl/01_grants/U003__grants.sql`).
- **Rollbacks run highest version to lowest.** `U003` (revoke) must run before `U002` (drop role):
  PostgreSQL refuses to drop a role that still holds privileges.
- `05_rollbacks/` is deliberately **not** in `flyway.toml` `locations`: Flyway Community never runs `U` scripts.
- The connection is never in `flyway.toml`; Flyway reads `FLYWAY_URL`, `FLYWAY_USER`, `FLYWAY_PASSWORD`
  from the environment. The runner uses the instance administrator's credentials (ADR-012).
- `auth_app` (the login role) is created by `synkro-infra-postgres`'s bootstrap, not here.
  `V003` grants `auth_writer` to it, so **it must exist before the first migrate**.
- **Name every constraint**: `pk_<table>`, `uq_<table>_<rule>`, `chk_<table>_<rule>`, `fk_<table>_<target>`.
  The CI checks assert on these names. A closed set is a named `CHECK`, never an `ENUM`.
- **Tables get their privileges from default privileges.** `V003` and `V005` use `ALTER DEFAULT
  PRIVILEGES`, which covers only tables created by the role that ran them. The runner always
  connects as the instance administrator, so every table is created by that same role; the CI
  checks that a table's owner is the role that set those defaults.
- **A foreign key is its own migration in `04_alter/`, and its column gets an index.** The `CREATE
  TABLE` never holds a foreign key, so the order in which tables are created does not matter. The CI
  checks every foreign key of the schema for an index, including the keys added later.

## Schema, tables and roles

This repository holds the complete `auth` model of `06-data/models.md` in `synkro-docs`: one schema, seven tables and two roles.

| Object | Created by | What it grants |
|---|---|---|
| `auth_schema` | `V001` | the schema of this domain |
| `auth_writer` (`NOLOGIN`) | `V002` | `USAGE` on `auth_schema`; `SELECT`, `INSERT`, `UPDATE` on its tables, never `DELETE`; on the two audit tables (`user_creation_audit`, `password_reset_audit`) and on `password_reset_receipt` only `SELECT` and `INSERT`. Granted to `auth_app`. |
| `auth_reader` (`NOLOGIN`) | `V004` | `USAGE` on `auth_schema`; `SELECT` on its tables, **except `password_reset_receipt`**, which no reader, report or export can read (`V025`). Not granted to `auth_app`: no service reads through it yet. |
| `auth_schema.system_user` | `V006` | the users of the system. `role` is `ADMIN`, `SALESPERSON` or `INVENTORY`; `SERVICE` is never a user role (ADR-006). No foreign keys. |
| `auth_schema.refresh_token` | `V007`, key `V008`, index `V009` | the refresh tokens. `token` holds a hash, never the token. `user_id` references `system_user` with `fk_refresh_token_user`, `ON DELETE RESTRICT`, indexed by `idx_refresh_token_user_id`. Tokens are deactivated (`active = false`), never deleted. |
| `auth_schema.service_token` | `V010`, key `V012`, index `V013` | the metadata of the tokens that `synkro-workflow` and `synkro-worker` use to call other services (ADR-006). The signed token is never stored. `issued_by` references `system_user` with `fk_service_token_issued_by`, `ON DELETE RESTRICT`, indexed by `idx_service_token_issued_by`. Tokens are never deleted. |
| `auth_schema.idempotency_key` | `V011` | the `Idempotency-Key` of each creation: user registration and service-token issuance. `key` is the primary key. `resource_id` names a user or a token depending on `resource_type`, so it has no foreign key. |
| `auth_schema.user_creation_audit` | `V014`, keys `V015`, index `V016`, grants `V017` | one record per user created: who created it (an `ADMIN` user, or the deployment operator for the first administrator), when, and under which correlation id. See [The user creation audit](#the-user-creation-audit). |
| `auth_schema.password_reset_audit` | `V018`, keys `V019`, index `V020`, grants `V021` | one record per committed ADMIN password reset: which `ADMIN` reset which user, when, under which correlation id and idempotency key (HU-AUTH-19, ADR-021). It holds no password, hash or token. See [The password reset audit](#the-password-reset-audit). |
| `auth_schema.password_reset_receipt` | `V022`, key `V023`, index `V024`, grants `V025` | the private, **expiring** receipt of the original request of a reset, so a retry with the same `Idempotency-Key` is recognised even after the user's password changed (ADR-021 Decision 5). It holds exactly the bcrypt string already computed for that reset. See [The password reset receipt](#the-password-reset-receipt). |
| `auth_schema.purge_expired_password_reset_receipts(integer)` | `V026` | the bounded cleanup of expired receipts, for an authorized operator. See [Cleanup of expired receipts](#cleanup-of-expired-receipts). |

## The user creation audit

`auth_schema.user_creation_audit` is the proof of who created each user. The team decided that this
proof is stored in the database, in the same transaction as the user, and not only in the logs: a
log line and a user insert cannot commit together, so a user could exist without its attribution.

| Column | Meaning |
|---|---|
| `audit_id` | primary key, generated by the service (no default, so a row cannot invent its own id) |
| `operation` | `USER_REGISTERED` (an administrator registered the user) or `INITIAL_ADMIN_CREATED` (the operator initialized the environment) |
| `actor_kind` | `ADMIN` or `OPERATOR` |
| `actor_user_id` | the administrator who acted; required for `USER_REGISTERED`, null for `INITIAL_ADMIN_CREATED` |
| `operator_identity` | the deployment identity of the operator, 1 to 200 characters; required for `INITIAL_ADMIN_CREATED`, null otherwise |
| `created_user_id` | the user that was created; unique, so a user has exactly one record |
| `outcome` | always `SUCCESS`: a failed attempt creates no user, so it is kept in the logs, never here |
| `occurred_at` | when the record was made |
| `correlation_id` | the identifier that ties the record to the request or command that caused it; not empty |

How the table is protected, and why:

- **Each operation has exactly one valid actor** (`chk_user_creation_audit_actor`). The check does not
  look at the actor's role afterwards: the service verifies the `ADMIN` role when it creates the
  user, and a later role change must not turn an old record invalid.
- **Both foreign keys are `ON DELETE RESTRICT`.** A user named by a record, as creator or as
  created, cannot be deleted, so the history never points to nothing. `actor_user_id` is indexed
  by `idx_user_creation_audit_actor_user_id`; `created_user_id` is already indexed by its unique constraint.
- **`auth_app` loses `UPDATE` on this table** so that records can only be appended, never altered by the
  service itself. `auth_writer` has `SELECT` and `INSERT`, `auth_reader` has `SELECT`, and nobody has
  `UPDATE`, `DELETE` or `TRUNCATE`. `V017` resets every privilege on the table first because the
  schema's default privileges (`V003`, `V005`) would otherwise give `auth_writer` — and through it
  `auth_app` — `UPDATE`.
- **The migration owner keeps the table.** `auth_app` cannot alter it, drop a constraint or turn off the
  foreign-key checks, so the rules above cannot be bypassed from the service.
- **No other domain's role can see it.** The table holds user identifiers, so it is only reachable
  through the roles of this repository.
- **Users that existed before this table have no record, and none is invented.** Only creations made
  after the audit is deployed are attributed. `system_user` has no authorship column.

## The password reset audit

`auth_schema.password_reset_audit` records every ADMIN password reset that committed (HU-AUTH-19,
[ADR-021](https://github.com/code-corhuila/synkro-docs/blob/main/05-architecture/decisions/records/ADR-021-admin-password-reset.md),
which is `Proposed` while this is written). `synkro-auth-api` writes the record, the new password hash and the
revocation of the target's refresh tokens in **one transaction**, so a reset cannot commit without its
attribution, and the row is the idempotency record of the reset. A failed or rejected attempt creates no row:
it belongs to the security logs.

| Column | Meaning |
|---|---|
| `audit_id` | primary key, generated by the service (no default) |
| `operation` | always `PASSWORD_RESET` |
| `actor_user_id` | the `ADMIN` who reset the password |
| `target_user_id` | the user whose password was reset |
| `idempotency_key` | the `Idempotency-Key` of the request, 8 to 128 characters |
| `outcome` | always `SUCCESS` |
| `occurred_at` | when the record was made |
| `correlation_id` | the identifier that ties the record to the request; not empty |

- **The key is scoped to its actor**: `UNIQUE (actor_user_id, idempotency_key)`. Another `ADMIN` using the same
  text has a different key, so no actor can read or repeat another actor's reset. That unique index also serves
  the replay lookup and the actor foreign key; `target_user_id` has `idx_password_reset_audit_target_user_id`.
- **An administrator never resets their own password**: `chk_password_reset_audit_not_self`. That the target is not
  an `ADMIN` and is active is checked by the service inside the transaction, not by this table.
- **Both foreign keys are `ON DELETE RESTRICT`**, so a user named by a record cannot be deleted.
- **Append-only for the service**: as in `user_creation_audit`, `V021` resets every privilege first and grants
  `auth_writer` only `SELECT` and `INSERT` and `auth_reader` only `SELECT`; `auth_app` cannot `UPDATE`, `DELETE`,
  `TRUNCATE` or alter the table.
- **Nothing secret is stored**: no password, no password hash, no token and no request body. Request equivalence
  for a replay is decided against the separate, expiring receipt below, never against the target's current hash and
  never against anything kept here.
- **The reservation is permanent.** The unique key of this table is what keeps a key consumed: expiring or deleting
  its receipt never frees it for another reset, and this table is never cleaned.
- **Existing data is untouched.** `system_user` and `refresh_token` get no new column; earlier resets are not
  invented, and `V018` to `V026` are new, additive migrations. Each has its `U` rollback.
- **Deployment order:** `synkro-auth-api` pins this repository by commit in its CI (`AUTH_DB_REF`), so this change
  is integrated first and the API bumps the pin afterwards.

## The password reset receipt

`auth_schema.password_reset_receipt` is a **private, temporary verifier of the original request** of an ADMIN
password reset (HU-AUTH-19, ADR-021 Decision 5, accepted). It is separate from the audit on purpose: the audit is
permanent evidence and never holds anything derived from a password; the receipt is credential material that
expires.

| Column | Meaning |
|---|---|
| `audit_id` | primary key and foreign key to `password_reset_audit` (`ON DELETE RESTRICT`): one receipt per reset |
| `request_password_hash` | exactly the bcrypt string computed for that reset and assigned to `system_user.password_hash` in the same transaction. No second bcrypt is generated; `chk_password_reset_receipt_bcrypt` makes the table refuse anything that is not a bcrypt string (a password, a body or a fast hash) |
| `expires_at` | the database clock at insertion plus 24 hours, set by the inserting statement; indexed (`idx_password_reset_receipt_expires_at`) for the bounded cleanup |

- **Written in the reset's single transaction.** The new hash, the revocation of the target's refresh tokens, the
  audit row and this receipt commit together or not at all.
- **Validity is logical and uses the database clock.** A receipt is usable while `expires_at > clock_timestamp()`,
  checked at each lookup, whether or not the cleanup has removed the row. A replay of an old request returns the
  original result only inside that window; expired or missing means a safe `422`, and the key stays consumed by the
  audit row. The service never reads the target's current hash as the comparator.
- **Minimum privileges** (`V025`): `auth_app` (through `auth_writer`) has `SELECT` and `INSERT` only. There is no
  `UPDATE`, `DELETE` or `TRUNCATE` at runtime, and **`auth_reader` has nothing**: no reader, report or export reads
  it, even though auth_schema's default privileges would otherwise give a new table to `auth_reader`.
- **Backups.** A backup taken while a receipt exists contains it. Treat backups of this database as credential
  material: encrypted, access-restricted and with a retention decided by the operator. Deleting a receipt here
  does not erase it from a backup, and nothing in this repository promises physical erasure at 24 hours.

### Cleanup of expired receipts

Logical expiry (24 hours) and physical deletion are different things. The replay rule is already enforced by the
clock; the cleanup only removes rows that no longer have any use, to keep the verifiers of retired passwords from
accumulating.

```sql
-- as the migration owner (never auth_app); see the complete privilege requirements below
SELECT auth_schema.purge_expired_password_reset_receipts();      -- at most 1000 receipts per call
SELECT auth_schema.purge_expired_password_reset_receipts(5000);  -- at most 5000 (valid range 1 to 10000)
```

- **Scope.** It deletes **only receipts whose `expires_at` has passed**, oldest first, at most `batch_size` per call,
  and returns the number removed. It never prints a hash or any row. It never touches `password_reset_audit`, so
  every audit record and every consumed key stays and an old key keeps answering `422`.
- **Who can run it.** It runs with the caller's own privileges (`SECURITY INVOKER`). The migration owner can run it.
  A separately provisioned operator would need schema `USAGE`, function `EXECUTE`, and receipt-table `SELECT`,
  `DELETE` and `UPDATE` (required by `FOR UPDATE SKIP LOCKED`). `DELETE` alone is insufficient. No such operator
  role is created by these migrations. `auth_app`,
  `auth_writer`, `auth_reader` and other domains cannot run it or delete a receipt.
- **Schedule: once a day.** Repeat the call until it returns less than the batch size. Check beforehand, without
  printing any value:
  `SELECT count(*) FROM auth_schema.password_reset_receipt WHERE expires_at <= clock_timestamp();`
- **Responsible.** Project owner **AsolanoT** is assigned the daily execution, verification and response to failures
  in the persistent local installation (assignment confirmed on 2026-11-11). Use protected migration-owner
  credentials, separate from the runtime account; Auth DB maintainers (`CODEOWNERS`) maintain the procedure.
  The deployment procedure is in `synkro-docs/10-devops/local-setup.md`, section "AUTH-19 receipt cleanup".
  This assignment does not install a scheduler. An automated executor and its schedule must be explicitly
  configured and tested before claiming that daily execution is automated.
- **No Worker, no automatic TTL.** There is no job, service or PostgreSQL TTL that deletes on its own. A missed
  run is an operational finding: rows stay stored longer, but replay validity is never extended.
- **Race with a replay.** A replay admitted at its lookup may finish after the receipt is deleted; it is read-only,
  so it changes nothing. A replay that arrives after the deletion finds no receipt and gets `422`: it never
  executes the reset again.

## Running the migrations locally

Requirements: Docker, and a PostgreSQL 16 instance reachable from the Docker network `platform`.

**1. A database.** Once `synkro-infra-postgres` exists, start it — it provides `synkro-db` on the
`platform` network and creates `auth_app`. Until then, a throwaway stand-in:

```bash
docker network create platform
```

```bash
docker run -d --name synkro-db --network platform -e POSTGRES_PASSWORD=dev_admin_pw -e POSTGRES_DB=synkro postgres:16-alpine
```

```bash
docker exec synkro-db psql -U postgres -d synkro -c "CREATE ROLE auth_app LOGIN PASSWORD 'dev_app_pw';"
```

To use a PostgreSQL installed on your own machine instead, keep the `platform` network (it must
exist) and point `FLYWAY_URL` at `jdbc:postgresql://host.docker.internal:5432/<database>`.

**2. Credentials.** Copy `.env.example` to `.env` (git-ignored) and fill in the administrator user
and password — for the stand-in above, `postgres` / `dev_admin_pw`.

**3. Migrate**, from the repository root:

```bash
docker compose -f deploy/compose.yml --env-file .env run --rm auth-db-migrate
```

`--env-file .env` is required: Compose otherwise looks for `.env` next to `deploy/compose.yml`.
Missing `FLYWAY_*` values stop the run before Flyway starts. Running it again must print
`No migration necessary`.

Other Flyway commands replace `migrate` at the end (`info`, `validate`, …); the working directory
and `flyway.toml` are already fixed in the service's entrypoint, so no path is ever typed:

```bash
docker compose -f deploy/compose.yml --env-file .env run --rm auth-db-migrate info
```

`clean` is disabled (`cleanDisabled = true`) on purpose. To start over, apply the rollbacks.

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

The assertions live in [`.github/scripts/db-checks.sh`](.github/scripts/db-checks.sh) (the helpers) and
[`.github/scripts/password-reset-audit-checks.sh`](.github/scripts/password-reset-audit-checks.sh) (the
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

## Root composition integration (HU-INF-02)

Flyway uses `auth_schema` as its only/default schema and stores its ledger in
`auth_schema.flyway_schema_history`. No historical migration was changed.
The tooling runner mounts this repository read-only. Root infrastructure waits
for authenticated PostgreSQL readiness before deliberately invoking it.

If `public.flyway_schema_history` exists in an established environment, stop.
Take a backup, inventory its domain/version/checksum records and obtain a reviewed
reconciliation procedure. Do not repair, move or delete that ledger automatically.
CI drops its disposable schema history **before** the schema-dropping rollback.
Run `python3 tests/test_history_contract.py` for the configuration regression.
