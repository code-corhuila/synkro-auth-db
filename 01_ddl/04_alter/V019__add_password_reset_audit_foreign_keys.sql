-- Both keys are RESTRICT: a user named by a record, as the ADMIN who reset or as the user reset, can never be deleted.
ALTER TABLE auth_schema.password_reset_audit ADD CONSTRAINT fk_password_reset_audit_actor
  FOREIGN KEY (actor_user_id) REFERENCES auth_schema.system_user (user_id) ON DELETE RESTRICT;
ALTER TABLE auth_schema.password_reset_audit ADD CONSTRAINT fk_password_reset_audit_target
  FOREIGN KEY (target_user_id) REFERENCES auth_schema.system_user (user_id) ON DELETE RESTRICT;
