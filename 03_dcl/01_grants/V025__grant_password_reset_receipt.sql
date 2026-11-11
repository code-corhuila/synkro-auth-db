-- Minimum privileges for a verifier of a possibly retired password.
--
-- auth_schema's default privileges (V003, V005) would hand auth_writer SELECT, INSERT and UPDATE and auth_reader
-- SELECT on every new table, and auth_app inherits auth_writer. Every role that could hold a privilege is therefore
-- reset first and only the two the service needs are granted:
--   auth_writer (so auth_app): SELECT to compare a replay and INSERT to write the receipt. No UPDATE, DELETE or
--     TRUNCATE: the runtime never changes a receipt and never removes one; removal is the operator's bounded
--     cleanup (V026).
--   auth_reader: nothing. No report, export or general reader can see a receipt (ADR-021 Decision 5), even though it
--     can read every other table of this schema.
-- The migration owner keeps ownership, so auth_app can neither alter the table nor disable its constraints.
REVOKE ALL ON TABLE auth_schema.password_reset_receipt FROM PUBLIC, auth_app, auth_writer, auth_reader;
GRANT SELECT, INSERT ON TABLE auth_schema.password_reset_receipt TO auth_writer;
