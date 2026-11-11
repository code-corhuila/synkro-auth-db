-- Audit records can only be appended, never changed, by the service itself: auth_app loses UPDATE
-- here (and never gets DELETE or TRUNCATE) so that a compromised or buggy service cannot rewrite
-- who reset whose password.
--
-- auth_schema's default privileges (V003, V005) already hand auth_writer SELECT, INSERT and UPDATE
-- on every new table, and auth_app inherits them through auth_writer. Revoking UPDATE from
-- auth_writer alone would leave this table's access depending on those defaults, so every role that
-- could hold a privilege is reset first and the two intended grants are made explicit, exactly as
-- V017 does for user_creation_audit. The migration owner keeps ownership: auth_app can neither
-- alter the table nor disable its constraints.
REVOKE ALL ON TABLE auth_schema.password_reset_audit FROM PUBLIC, auth_app, auth_writer, auth_reader;
GRANT SELECT, INSERT ON TABLE auth_schema.password_reset_audit TO auth_writer;
GRANT SELECT ON TABLE auth_schema.password_reset_audit TO auth_reader;
