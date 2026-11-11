-- Dropped with the table (U022) in the full rollback; on its own this removes only the constraint.
ALTER TABLE IF EXISTS auth_schema.password_reset_receipt DROP CONSTRAINT IF EXISTS fk_password_reset_receipt_audit;
