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

The tree follows `Norma-Repositorios.md` Anexo A (Flyway). Every family folder exists from day one,
even when empty (`.gitkeep`), so execution order never has to be renumbered.

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

This repository holds the complete `auth` model of `06-data/models.md` in `synkro-docs`: one schema, four tables and two roles.

| Object | Created by | What it grants |
|---|---|---|
| `auth_schema` | `V001` | the schema of this domain |
| `auth_writer` (`NOLOGIN`) | `V002` | `USAGE` on `auth_schema`; `SELECT`, `INSERT`, `UPDATE` on its tables, never `DELETE`. Granted to `auth_app`. |
| `auth_reader` (`NOLOGIN`) | `V004` | `USAGE` on `auth_schema`; `SELECT` on its tables. Not granted to `auth_app`: no service reads through it yet. |
| `auth_schema.system_user` | `V006` | the users of the system. `role` is `ADMIN`, `SALESPERSON` or `INVENTORY`; `SERVICE` is never a user role (ADR-006). No foreign keys. |
| `auth_schema.refresh_token` | `V007`, key `V008`, index `V009` | the refresh tokens. `token` holds a hash, never the token. `user_id` references `system_user` with `fk_refresh_token_user`, `ON DELETE RESTRICT`, indexed by `idx_refresh_token_user_id`. Tokens are deactivated (`active = false`), never deleted. |
| `auth_schema.service_token` | `V010`, key `V012`, index `V013` | the metadata of the tokens that `synkro-workflow` and `synkro-worker` use to call other services (ADR-006). The signed token is never stored. `issued_by` references `system_user` with `fk_service_token_issued_by`, `ON DELETE RESTRICT`, indexed by `idx_service_token_issued_by`. Tokens are never deleted. |
| `auth_schema.idempotency_key` | `V011` | the `Idempotency-Key` of each creation: user registration and service-token issuance. `key` is the primary key. `resource_id` names a user or a token depending on `resource_type`, so it has no foreign key. |

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
3. **Privileges:** `auth_app` has `USAGE` on `auth_schema`, and on each of the four tables
   `SELECT`, `INSERT` and `UPDATE` but never `DELETE`, which it inherits from `auth_writer`.
   `auth_reader` can read the tables and cannot insert into them. `auth_app` cannot delete from
   any table of `auth_schema`, including one added later.
4. **Constraints:** every CHECK, unique, foreign key and NOT NULL rule of `system_user`,
   `refresh_token`, `service_token` and `idempotency_key` rejects its bad rows with the expected
   SQLSTATE and constraint (or column) name, and accepts the valid rows next to them. The steps
   delete the rows they insert, children first.
5. **Indexes:** `idx_refresh_token_user_id` and `idx_service_token_issued_by` exist on their
   `user_id` and `issued_by` columns, and every foreign key of `auth_schema` has an index that
   starts with its column.
6. **Rollbacks** apply cleanly, highest version to lowest, and leave none of `auth_schema`,
   `auth_writer` or `auth_reader` behind.
7. **Rebuild:** after dropping `flyway_schema_history`, migrating from scratch succeeds again.

The assertions live in [`.github/scripts/db-checks.sh`](.github/scripts/db-checks.sh); each check step
sources it from the repository root.

To reproduce it by hand against the stand-in database above (bash, repository root):

```bash
docker run --rm --network platform -e PGPASSWORD=dev_admin_pw postgres:16-alpine psql -h synkro-db -U postgres -d synkro -tAc "SELECT has_schema_privilege('auth_app', 'auth_schema', 'USAGE');"
```

```bash
find 05_rollbacks -name 'U*.sql' -printf '%f\t%p\n' | sort -r | cut -f2 | while read -r f; do echo "Applying $f"; docker exec -i synkro-db psql -U postgres -d synkro -v ON_ERROR_STOP=1 < "$f" || break; done
```

```bash
docker exec synkro-db psql -U postgres -d synkro -c "DROP TABLE IF EXISTS flyway_schema_history;"
```

Then migrate again (step 3 above). The first command must print `t`; the loop must apply `U009`
down to `U001`, in that order, without errors.

To run the whole workflow locally, unchanged, use [`act`](https://github.com/nektos/act):

```bash
act push -W .github/workflows/db-ci.yml -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

The workflow's PostgreSQL service listens on host port 5432, so stop any PostgreSQL that already
uses that port before running it.
