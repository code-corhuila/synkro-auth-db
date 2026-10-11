-- created_user_id needs no index of its own: uq_user_creation_audit_created_user already serves
-- the attribution lookup and its foreign key.
CREATE INDEX idx_user_creation_audit_actor_user_id ON auth_schema.user_creation_audit (actor_user_id);
