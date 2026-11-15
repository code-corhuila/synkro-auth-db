# Migrations

Detailed procedures and delivery notes moved from the repository README at
[source 2b62522](https://github.com/code-corhuila/synkro-auth-db/blob/2b6252237bd5a4911ec8db13e99008a059d95e42/README.md).
Recorded execution results retain their original scope; moving them does not
constitute a new execution or certify a different revision.

Run commands from the repository root unless a step explicitly changes directory.

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
