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
3. **Privileges:** `auth_app` has `USAGE` on `auth_schema`.
4. **Rollbacks** apply cleanly, highest version to lowest, and leave neither `auth_schema`
   nor `auth_writer` behind.
5. **Rebuild:** after dropping `flyway_schema_history`, migrating from scratch succeeds again.

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

Then migrate again (step 3 above). The first command must print `t`; the loop must apply `U003`,
`U002`, `U001` in that order without errors.

To run the whole workflow locally, unchanged, use [`act`](https://github.com/nektos/act):

```bash
act push -W .github/workflows/db-ci.yml -P ubuntu-latest=catthehacker/ubuntu:act-latest
```
