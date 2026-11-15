-- The bounded cleanup of expired password reset receipts, for an authorized operator (HU-AUTH-19, ADR-021 Decision 5).
--
--   SELECT auth_schema.purge_expired_password_reset_receipts();        -- at most 1000 receipts
--   SELECT auth_schema.purge_expired_password_reset_receipts(5000);    -- at most 5000 (1 to 10000)
--
-- What it does and does not do:
--   * It deletes ONLY receipts whose expires_at has passed by the database clock, oldest first, at most batch_size per
--     call, and returns how many it removed. It returns no row and prints no hash: the operator sees a count.
--   * It never touches password_reset_audit: the audit records and the consumed (actor, key) reservations stay, so a
--     key whose receipt was removed still answers 422 and is never executed again.
--   * Expiry is logical and is decided at lookup time, whether or not this has run. This function is the physical
--     deletion, and a missed run only leaves expired rows stored longer; it never extends replay validity.
--   * It is not scheduled by the database and there is no Worker for it: an operator runs it once a day (README).
--
-- It runs with the privileges of its CALLER (SECURITY INVOKER) and EXECUTE is revoked from everyone: the operator
-- needs DELETE on the receipt, which only the migration owner has. The service role has neither, so it cannot clean up
-- and cannot be used to. The search_path is pinned and every name is qualified.
--
-- Backups taken before a receipt is deleted still contain it: treat them as credential material. Deleting here does
-- not erase them.
CREATE FUNCTION auth_schema.purge_expired_password_reset_receipts(batch_size integer DEFAULT 1000)
RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $purge$
DECLARE
  removed integer;
BEGIN
  IF batch_size IS NULL OR batch_size < 1 OR batch_size > 10000 THEN
    RAISE EXCEPTION '"batch_size" must be between 1 and 10000'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  WITH expired AS (
    SELECT r.audit_id
      FROM auth_schema.password_reset_receipt r
     WHERE r.expires_at <= pg_catalog.clock_timestamp()
     ORDER BY r.expires_at
     LIMIT batch_size
       FOR UPDATE SKIP LOCKED
  ), deleted AS (
    DELETE FROM auth_schema.password_reset_receipt r
     USING expired e
     WHERE r.audit_id = e.audit_id
    RETURNING 1
  )
  SELECT pg_catalog.count(*)::integer INTO removed FROM deleted;

  RETURN removed;
END;
$purge$;

REVOKE ALL ON FUNCTION auth_schema.purge_expired_password_reset_receipts(integer) FROM PUBLIC, auth_app, auth_writer, auth_reader;
