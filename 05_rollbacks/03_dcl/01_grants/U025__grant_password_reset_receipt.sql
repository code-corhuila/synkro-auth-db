-- Back to what auth_schema default privileges (V003, V005) give a new table: the rollback of the table itself (U022)
-- runs right after and removes the privileges with it.
GRANT SELECT, INSERT, UPDATE ON TABLE auth_schema.password_reset_receipt TO auth_writer;
GRANT SELECT ON TABLE auth_schema.password_reset_receipt TO auth_reader;
