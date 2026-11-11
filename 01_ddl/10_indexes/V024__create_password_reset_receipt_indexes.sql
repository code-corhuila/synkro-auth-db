-- audit_id needs no index of its own: the primary key serves the replay lookup (joined from the audit record by
-- its key) and the foreign key. expires_at serves the bounded cleanup, which reads the oldest expired receipts first.
CREATE INDEX idx_password_reset_receipt_expires_at ON auth_schema.password_reset_receipt (expires_at);
