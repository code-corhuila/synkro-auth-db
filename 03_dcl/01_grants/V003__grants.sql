GRANT USAGE ON SCHEMA auth_schema TO auth_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA auth_schema
  GRANT SELECT, INSERT, UPDATE ON TABLES TO auth_writer;
GRANT auth_writer TO auth_app;
