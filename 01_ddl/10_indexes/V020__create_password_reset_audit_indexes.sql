-- actor_user_id needs no index of its own: uq_password_reset_audit_actor_key starts with it and already
-- serves the replay lookup by (actor, key) and the foreign key. The target is looked up on its own.
CREATE INDEX idx_password_reset_audit_target_user_id ON auth_schema.password_reset_audit (target_user_id);
