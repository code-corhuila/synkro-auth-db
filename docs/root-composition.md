# Root composition

Detailed procedures and delivery notes moved from the repository README at
[source 2b62522](https://github.com/code-corhuila/synkro-auth-db/blob/2b6252237bd5a4911ec8db13e99008a059d95e42/README.md).
Recorded execution results retain their original scope; moving them does not
constitute a new execution or certify a different revision.

Run commands from the repository root unless a step explicitly changes directory.

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
