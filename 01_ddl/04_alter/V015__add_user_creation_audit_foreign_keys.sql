-- Both keys are RESTRICT: a user named by a record, as creator or as created, can never be deleted.
ALTER TABLE auth_schema.user_creation_audit ADD CONSTRAINT fk_user_creation_audit_actor
  FOREIGN KEY (actor_user_id) REFERENCES auth_schema.system_user (user_id) ON DELETE RESTRICT;
ALTER TABLE auth_schema.user_creation_audit ADD CONSTRAINT fk_user_creation_audit_created_user
  FOREIGN KEY (created_user_id) REFERENCES auth_schema.system_user (user_id) ON DELETE RESTRICT;
