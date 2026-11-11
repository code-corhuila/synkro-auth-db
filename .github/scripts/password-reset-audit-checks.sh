# Assertions for the AUTH-RESET-AUDIT-01 steps of db-ci.yml (HU-AUTH-19, ADR-021 Decision 4).
# A step sets PSQL (and PSQL_APP or PSQL_OTHER where it needs them), sources this file from the
# repository root and calls one check_* function. A failed assertion exits the step.

source .github/scripts/db-checks.sh

reset_audit_table="auth_schema.password_reset_audit"
reset_audit_columns="audit_id, operation, actor_user_id, target_user_id, idempotency_key, outcome, occurred_at, correlation_id"

check_shape() {
  expect_eq "password_reset_audit has exactly the specified columns and types" \
    "SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod) || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END, ', ' ORDER BY a.attnum) FROM pg_attribute a WHERE a.attrelid = to_regclass('$reset_audit_table') AND a.attnum > 0 AND NOT a.attisdropped;" \
    "audit_id uuid NOT NULL, operation text NOT NULL, actor_user_id uuid NOT NULL, target_user_id uuid NOT NULL, idempotency_key text NOT NULL, outcome text NOT NULL, occurred_at timestamp with time zone NOT NULL, correlation_id text NOT NULL"
  expect_eq "no column has a default: Auth supplies every value itself" \
    "SELECT count(*) FROM pg_attrdef WHERE adrelid = to_regclass('$reset_audit_table');" 0
  expect_eq "password_reset_audit has exactly the specified named constraints" \
    "SELECT string_agg(conname, ', ' ORDER BY conname) FROM pg_constraint WHERE conrelid = to_regclass('$reset_audit_table');" \
    "chk_password_reset_audit_correlation_id, chk_password_reset_audit_idempotency_key, chk_password_reset_audit_not_self, chk_password_reset_audit_operation, chk_password_reset_audit_outcome, fk_password_reset_audit_actor, fk_password_reset_audit_target, pk_password_reset_audit, uq_password_reset_audit_actor_key"
  expect_eq "both foreign keys point to system_user with ON DELETE RESTRICT" \
    "SELECT string_agg(conname || ' -> ' || confrelid::regclass || ' ' || confdeltype::text, ', ' ORDER BY conname) FROM pg_constraint WHERE conrelid = to_regclass('$reset_audit_table') AND contype = 'f';" \
    "fk_password_reset_audit_actor -> auth_schema.\"system_user\" r, fk_password_reset_audit_target -> auth_schema.\"system_user\" r"
  expect_eq "an idempotency key is unique per actor, not globally" \
    "SELECT coalesce(pg_get_indexdef(to_regclass('auth_schema.uq_password_reset_audit_actor_key')), '<none>');" \
    "CREATE UNIQUE INDEX uq_password_reset_audit_actor_key ON auth_schema.password_reset_audit USING btree (actor_user_id, idempotency_key)"
  expect_eq "idx_password_reset_audit_target_user_id is on password_reset_audit (target_user_id)" \
    "SELECT coalesce(pg_get_indexdef(to_regclass('auth_schema.idx_password_reset_audit_target_user_id')), '<none>');" \
    "CREATE INDEX idx_password_reset_audit_target_user_id ON auth_schema.password_reset_audit USING btree (target_user_id)"
  expect_eq "the table has no more indexes than its key, its unique constraint and the target index" \
    "SELECT count(*) FROM pg_indexes WHERE schemaname = 'auth_schema' AND tablename = 'password_reset_audit';" 3
}

check_rows() {
  # $1 = the e-mail local part of a user created below
  local user_id_of
  user_id_of() { echo "(SELECT user_id FROM auth_schema.system_user WHERE email = '$1@synkro.test')"; }
  # $1 operation, $2 actor, $3 target, $4 idempotency key, $5 outcome, $6 occurred_at, $7 correlation id (SQL literals)
  reset_insert() {
    echo "INSERT INTO $reset_audit_table ($reset_audit_columns) VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, $6, $7);"
  }

  expect_accepted "INSERT INTO auth_schema.system_user (name, email, password_hash, role) VALUES
    ('Reset Admin', 'reset-admin@synkro.test', 'placeholder-not-a-hash', 'ADMIN'),
    ('Reset Deputy', 'reset-deputy@synkro.test', 'placeholder-not-a-hash', 'ADMIN'),
    ('Reset Sales', 'reset-sales@synkro.test', 'placeholder-not-a-hash', 'SALESPERSON'),
    ('Reset Stock', 'reset-stock@synkro.test', 'placeholder-not-a-hash', 'INVENTORY'),
    ('Reset Spare', 'reset-spare@synkro.test', 'placeholder-not-a-hash', 'INVENTORY');" \
    "the users the reset records will point to"

  # --- 1. valid records, with every attribution field kept
  expect_accepted "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-sales)" "'reset-key-0001'" "'SUCCESS'" "'2026-11-10 12:00:00+00'" "'http-0001'")" \
    "an ADMIN resets a SALESPERSON"
  expect_accepted "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-sales)" "'reset-key-0002'" "'SUCCESS'" "now()" "'http-0002'")" \
    "the same ADMIN resets the same user again under another key: a user may have many resets"
  expect_accepted "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-deputy)" "$(user_id_of reset-stock)" "'reset-key-0001'" "'SUCCESS'" "now()" "'http-0003'")" \
    "another ADMIN reuses the same key text: the key is scoped to its actor"
  expect_accepted "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-stock)" "'k1234567'" "'SUCCESS'" "now()" "'x'")" \
    "an 8-character key and a 1-character correlation id"
  expect_accepted "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-stock)" "repeat('k', 128)" "'SUCCESS'" "now()" "'http-0004'")" \
    "a 128-character key"
  expect_eq "the first record keeps its operation, actor, target, key, outcome, time and correlation id" \
    "SELECT operation || '|' || (actor_user_id = $(user_id_of reset-admin)) || '|' || (target_user_id = $(user_id_of reset-sales)) || '|' || idempotency_key || '|' || outcome || '|' || (occurred_at AT TIME ZONE 'UTC') || '|' || correlation_id FROM $reset_audit_table WHERE correlation_id = 'http-0001';" \
    "PASSWORD_RESET|true|true|reset-key-0001|SUCCESS|2026-11-10 12:00:00|http-0001"

  # --- 2. invalid operation, outcome, key, correlation id and self-reset (SQLSTATE 23514)
  expect_violation 23514 chk_password_reset_audit_operation \
    "$(reset_insert "'USER_REGISTERED'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "'reset-key-0010'" "'SUCCESS'" "now()" "'c'")"
  expect_violation 23514 chk_password_reset_audit_operation \
    "$(reset_insert "'password_reset'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "'reset-key-0010'" "'SUCCESS'" "now()" "'c'")"
  # only successes are recorded: failed attempts belong to the security logs
  expect_violation 23514 chk_password_reset_audit_outcome \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "'reset-key-0010'" "'FAILURE'" "now()" "'c'")"
  expect_violation 23514 chk_password_reset_audit_outcome \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "'reset-key-0010'" "'success'" "now()" "'c'")"
  expect_violation 23514 chk_password_reset_audit_idempotency_key \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "'k123456'" "'SUCCESS'" "now()" "'c'")"
  expect_violation 23514 chk_password_reset_audit_idempotency_key \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "repeat('k', 129)" "'SUCCESS'" "now()" "'c'")"
  expect_violation 23514 chk_password_reset_audit_idempotency_key \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "''" "'SUCCESS'" "now()" "'c'")"
  expect_violation 23514 chk_password_reset_audit_correlation_id \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "'reset-key-0010'" "'SUCCESS'" "now()" "''")"
  # a reset is never an administrator acting on their own account
  expect_violation 23514 chk_password_reset_audit_not_self \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-admin)" "'reset-key-0010'" "'SUCCESS'" "now()" "'c'")"

  # --- 3. required fields: every column rejects NULL (SQLSTATE 23502)
  declare -A VALUE=(
    [audit_id]="gen_random_uuid()"
    [operation]="'PASSWORD_RESET'"
    [actor_user_id]="$(user_id_of reset-admin)"
    [target_user_id]="$(user_id_of reset-spare)"
    [idempotency_key]="'reset-key-0011'"
    [outcome]="'SUCCESS'"
    [occurred_at]="now()"
    [correlation_id]="'c'"
  )
  local null_column column values value
  for null_column in ${reset_audit_columns//,/}; do
    values=""
    for column in ${reset_audit_columns//,/}; do
      value="${VALUE[$column]}"
      if [ "$column" = "$null_column" ]; then value="NULL"; fi
      values+="${values:+, }$value"
    done
    expect_violation 23502 "$null_column" \
      "INSERT INTO $reset_audit_table ($reset_audit_columns) VALUES ($values);"
  done

  # --- 4. one record per (actor, key), one record per audit id
  expect_violation 23505 uq_password_reset_audit_actor_key \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "$(user_id_of reset-spare)" "'reset-key-0001'" "'SUCCESS'" "now()" "'http-dup'")"
  expect_violation 23505 pk_password_reset_audit \
    "INSERT INTO $reset_audit_table ($reset_audit_columns) SELECT audit_id, operation, actor_user_id, target_user_id, 'reset-key-0012', outcome, occurred_at, 'pk-dup' FROM $reset_audit_table WHERE correlation_id = 'http-0001';"
  expect_eq "a conflicting key is skipped without error and writes nothing (the claim the adapter relies on)" \
    "WITH claim AS (INSERT INTO $reset_audit_table ($reset_audit_columns) VALUES (gen_random_uuid(), 'PASSWORD_RESET', $(user_id_of reset-admin), $(user_id_of reset-spare), 'reset-key-0001', 'SUCCESS', now(), 'claim') ON CONFLICT (actor_user_id, idempotency_key) DO NOTHING RETURNING 1) SELECT count(*) FROM claim;" 0

  # --- 5. foreign keys
  expect_violation 23503 fk_password_reset_audit_actor \
    "$(reset_insert "'PASSWORD_RESET'" "'99999999-9999-9999-9999-999999999999'" "$(user_id_of reset-spare)" "'reset-key-0013'" "'SUCCESS'" "now()" "'c'")"
  expect_violation 23503 fk_password_reset_audit_target \
    "$(reset_insert "'PASSWORD_RESET'" "$(user_id_of reset-admin)" "'99999999-9999-9999-9999-999999999999'" "'reset-key-0013'" "'SUCCESS'" "now()" "'c'")"
  # RESTRICT: neither the acting ADMIN nor the target can be deleted while a record names them
  expect_violation 23503 fk_password_reset_audit_actor \
    "DELETE FROM auth_schema.system_user WHERE email = 'reset-deputy@synkro.test';"
  expect_violation 23503 fk_password_reset_audit_target \
    "DELETE FROM auth_schema.system_user WHERE email = 'reset-sales@synkro.test';"
  expect_accepted "DELETE FROM auth_schema.system_user WHERE email = 'reset-spare@synkro.test';" \
    "deleting a user that no reset record names"

  # Clean up every row this check accepted: records first, then the users they name
  $PSQL -c "DELETE FROM $reset_audit_table;"
  $PSQL -c "DELETE FROM auth_schema.system_user;"
  expect_eq "password_reset_audit is empty after the checks" "SELECT count(*) FROM $reset_audit_table;" 0
  expect_eq "system_user is empty after the checks" "SELECT count(*) FROM auth_schema.system_user;" 0
}

check_grants() {
  # $1 = role, $2 = the privileges it must have; it must lack every other one
  expect_reset_privileges() {
    local privilege wanted
    for privilege in SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER; do
      wanted=f
      if [[ " $2 " == *" $privilege "* ]]; then wanted=t; fi
      expect_eq "$1 $([ "$wanted" = t ] && echo has || echo lacks) $privilege on password_reset_audit" \
        "SELECT has_table_privilege('$1', '$reset_audit_table', '$privilege');" "$wanted"
    done
  }

  expect_reset_privileges auth_writer "SELECT INSERT"
  expect_reset_privileges auth_reader "SELECT"
  expect_reset_privileges auth_app "SELECT INSERT"

  expect_eq "no role other than the owner holds a privilege here, apart from auth_writer and auth_reader" \
    "SELECT coalesce(string_agg(DISTINCT coalesce(r.rolname, 'PUBLIC') || ':' || a.privilege_type, ', ' ORDER BY coalesce(r.rolname, 'PUBLIC') || ':' || a.privilege_type), '') FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a LEFT JOIN pg_roles r ON r.oid = a.grantee WHERE c.oid = to_regclass('$reset_audit_table') AND a.grantee <> c.relowner;" \
    "auth_reader:SELECT, auth_writer:INSERT, auth_writer:SELECT"
  expect_eq "PUBLIC holds no privilege on password_reset_audit" \
    "SELECT count(*) FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a WHERE c.oid = to_regclass('$reset_audit_table') AND a.grantee = 0;" 0
  expect_eq "auth_app has no direct grant on password_reset_audit" \
    "SELECT count(*) FROM pg_class c CROSS JOIN LATERAL aclexplode(c.relacl) a JOIN pg_roles r ON r.oid = a.grantee WHERE c.oid = to_regclass('$reset_audit_table') AND r.rolname = 'auth_app';" 0
  expect_eq "no column carries a privilege of its own" \
    "SELECT count(*) FROM pg_attribute WHERE attrelid = to_regclass('$reset_audit_table') AND attacl IS NOT NULL;" 0
  expect_eq "auth_app can update no column of password_reset_audit" \
    "SELECT has_any_column_privilege('auth_app', '$reset_audit_table', 'UPDATE');" f
  expect_eq "the migration owner owns password_reset_audit, as it owns system_user" \
    "SELECT (SELECT relowner FROM pg_class WHERE oid = to_regclass('$reset_audit_table')) = (SELECT relowner FROM pg_class WHERE oid = 'auth_schema.system_user'::regclass);" t
  expect_eq "auth_app does not own password_reset_audit and is not a member of its owner" \
    "SELECT NOT pg_has_role('auth_app', c.relowner, 'USAGE') AND pg_get_userbyid(c.relowner) <> 'auth_app' FROM pg_class c WHERE c.oid = to_regclass('$reset_audit_table');" t
}

# The unit ADR-021 Decision 4 describes, run by the service's own login: audit claim, password change and
# refresh revocation in one transaction, and the audit table cannot be altered afterwards.
check_app_login() {
  local admin='c1c1c1c1-c1c1-c1c1-c1c1-c1c1c1c1c1c1' target='c2c2c2c2-c2c2-c2c2-c2c2-c2c2c2c2c2c2'
  local other='c3c3c3c3-c3c3-c3c3-c3c3-c3c3c3c3c3c3'

  $PSQL -c "INSERT INTO auth_schema.system_user (user_id, name, email, password_hash, role) VALUES
    ('$admin', 'Login Admin', 'login-admin@synkro.test', 'placeholder-not-a-hash', 'ADMIN'),
    ('$target', 'Login Sales', 'login-sales@synkro.test', 'old-placeholder-hash', 'SALESPERSON'),
    ('$other', 'Login Other', 'login-other@synkro.test', 'other-placeholder-hash', 'INVENTORY');"
  $PSQL -c "INSERT INTO auth_schema.refresh_token (user_id, token, expiration_date) VALUES
    ('$target', 'placeholder-target-1', now() + interval '7 days'),
    ('$target', 'placeholder-target-2', now() + interval '7 days'),
    ('$other', 'placeholder-other-1', now() + interval '7 days');"

  PSQL="$PSQL_APP" expect_eq "the connection is auth_app itself, not a SET ROLE" \
    "SELECT session_user || '/' || current_user;" "auth_app/auth_app"
  PSQL="$PSQL_APP" expect_eq "auth_app can SELECT password_reset_audit" \
    "SELECT count(*) FROM $reset_audit_table;" 0

  local unit="INSERT INTO $reset_audit_table ($reset_audit_columns) VALUES (gen_random_uuid(), 'PASSWORD_RESET', '$admin', '$target', 'login-key-0001', 'SUCCESS', now(), 'login-0001') ON CONFLICT (actor_user_id, idempotency_key) DO NOTHING;
    UPDATE auth_schema.system_user SET password_hash = 'new-placeholder-hash' WHERE user_id = '$target' AND active AND role <> 'ADMIN';
    UPDATE auth_schema.refresh_token SET active = false WHERE user_id = '$target' AND active;"
  PSQL="$PSQL_APP" expect_accepted "$unit" "auth_app runs the audit claim, the password change and the revocation as one unit"
  expect_eq "the unit changed the target, revoked only the target's refresh tokens and wrote one record" \
    "SELECT (SELECT password_hash FROM auth_schema.system_user WHERE user_id = '$target') || '|' || (SELECT count(*) FROM auth_schema.refresh_token WHERE user_id = '$target' AND active) || '|' || (SELECT count(*) FROM auth_schema.refresh_token WHERE user_id = '$other' AND active) || '|' || (SELECT count(*) FROM $reset_audit_table);" \
    "new-placeholder-hash|0|1|1"
  expect_eq "the other user's hash is untouched" \
    "SELECT password_hash FROM auth_schema.system_user WHERE user_id = '$other';" "other-placeholder-hash"

  # The unit does nothing to an ADMIN account: the guard in the UPDATE matches no row
  PSQL="$PSQL_APP" expect_eq "the guarded UPDATE changes no ADMIN account" \
    "WITH changed AS (UPDATE auth_schema.system_user SET password_hash = 'must-not-apply' WHERE user_id = '$admin' AND active AND role <> 'ADMIN' RETURNING 1) SELECT count(*) FROM changed;" 0

  # A replay of the claim writes nothing
  PSQL="$PSQL_APP" expect_eq "a replayed claim writes no second record" \
    "WITH claim AS (INSERT INTO $reset_audit_table ($reset_audit_columns) VALUES (gen_random_uuid(), 'PASSWORD_RESET', '$admin', '$target', 'login-key-0001', 'SUCCESS', now(), 'login-0002') ON CONFLICT (actor_user_id, idempotency_key) DO NOTHING RETURNING 1) SELECT count(*) FROM claim;" 0
  expect_eq "still exactly one record after the replay" "SELECT count(*) FROM $reset_audit_table;" 1

  # Records can be appended, never altered, by the service itself
  PSQL="$PSQL_APP" expect_denied "UPDATE" "UPDATE $reset_audit_table SET correlation_id = 'tampered';"
  PSQL="$PSQL_APP" expect_denied "DELETE" "DELETE FROM $reset_audit_table;"
  PSQL="$PSQL_APP" expect_denied "TRUNCATE" "TRUNCATE $reset_audit_table;"
  PSQL="$PSQL_APP" expect_denied "ALTER TABLE (drop a check)" \
    "ALTER TABLE $reset_audit_table DROP CONSTRAINT chk_password_reset_audit_outcome;"
  PSQL="$PSQL_APP" expect_denied "ALTER TABLE (disable triggers, which also disable the foreign-key checks)" \
    "ALTER TABLE $reset_audit_table DISABLE TRIGGER ALL;"
  PSQL="$PSQL_APP" expect_denied "DROP TABLE" "DROP TABLE $reset_audit_table;"
  expect_eq "the record is unchanged after the refused attempts" \
    "SELECT correlation_id FROM $reset_audit_table;" "login-0001"

  $PSQL -c "DELETE FROM auth_schema.refresh_token;"
  $PSQL -c "DELETE FROM $reset_audit_table;"
  $PSQL -c "DELETE FROM auth_schema.system_user;"
  expect_eq "the tables this check used are empty again" \
    "SELECT (SELECT count(*) FROM auth_schema.refresh_token) + (SELECT count(*) FROM $reset_audit_table) + (SELECT count(*) FROM auth_schema.system_user);" 0
}

# The other domains share this instance and each has its own login role; the stand-in is dropped at the end.
check_other_domain() {
  $PSQL -c "CREATE ROLE probe_other_domain_reset_app LOGIN PASSWORD 'ci_other_pw';"

  PSQL="$PSQL_OTHER" expect_eq "the other-domain role connects as itself" \
    "SELECT session_user;" probe_other_domain_reset_app
  local privilege
  for privilege in SELECT INSERT UPDATE DELETE TRUNCATE REFERENCES TRIGGER; do
    expect_eq "the other-domain role lacks $privilege on password_reset_audit" \
      "SELECT has_table_privilege('probe_other_domain_reset_app', '$reset_audit_table', '$privilege');" f
  done
  PSQL="$PSQL_OTHER" expect_denied "SELECT" "SELECT count(*) FROM $reset_audit_table;"
  PSQL="$PSQL_OTHER" expect_denied "INSERT" \
    "INSERT INTO $reset_audit_table ($reset_audit_columns) VALUES (gen_random_uuid(), 'PASSWORD_RESET', gen_random_uuid(), gen_random_uuid(), 'other-key-0001', 'SUCCESS', now(), 'other-0001');"
  PSQL="$PSQL_OTHER" expect_denied "UPDATE" "UPDATE $reset_audit_table SET correlation_id = 'other';"
  PSQL="$PSQL_OTHER" expect_denied "DELETE" "DELETE FROM $reset_audit_table;"
  PSQL="$PSQL_OTHER" expect_denied "TRUNCATE" "TRUNCATE $reset_audit_table;"

  $PSQL -c "DROP ROLE probe_other_domain_reset_app;"
  expect_eq "the other-domain stand-in role is dropped" \
    "SELECT count(*) FROM pg_roles WHERE rolname = 'probe_other_domain_reset_app';" 0
}
