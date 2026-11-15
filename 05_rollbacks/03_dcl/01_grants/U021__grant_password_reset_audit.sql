-- Back to what auth_schema's default privileges (V003, V005) give a new table: the rollback of the
-- table itself (U018) runs right after and removes the privileges with it.
GRANT SELECT, INSERT, UPDATE ON TABLE auth_schema.password_reset_audit TO auth_writer;
GRANT SELECT ON TABLE auth_schema.password_reset_audit TO auth_reader;
