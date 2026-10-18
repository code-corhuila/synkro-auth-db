ALTER TABLE IF EXISTS auth_schema.user_creation_audit DROP CONSTRAINT IF EXISTS fk_user_creation_audit_created_user;
ALTER TABLE IF EXISTS auth_schema.user_creation_audit DROP CONSTRAINT IF EXISTS fk_user_creation_audit_actor;
