ALTER TABLE IF EXISTS auth_schema.password_reset_audit DROP CONSTRAINT IF EXISTS fk_password_reset_audit_target;
ALTER TABLE IF EXISTS auth_schema.password_reset_audit DROP CONSTRAINT IF EXISTS fk_password_reset_audit_actor;
