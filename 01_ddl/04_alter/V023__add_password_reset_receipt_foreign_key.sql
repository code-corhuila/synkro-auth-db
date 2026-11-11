-- RESTRICT: an audit record that has a receipt can never be deleted, so the permanent reservation of (actor, key)
-- cannot disappear under it. The primary key index of the receipt already serves this foreign key.
ALTER TABLE auth_schema.password_reset_receipt ADD CONSTRAINT fk_password_reset_receipt_audit
  FOREIGN KEY (audit_id) REFERENCES auth_schema.password_reset_audit (audit_id) ON DELETE RESTRICT;
