-- The private, expiring receipt of the ORIGINAL request of an ADMIN password reset (HU-AUTH-19, ADR-021 Decision 5).
--
-- It exists so that a retry of a request whose response was lost can be recognised as the same request, for a
-- bounded time, even if the user's password has changed since: the retry is compared with what the reset set,
-- never with whatever password the user has now. It is deliberately NOT part of password_reset_audit: the audit is
-- append-only evidence that is kept for good, and it never holds anything derived from a password.
--
-- request_password_hash is exactly the bcrypt string that was computed for that reset and assigned to
-- system_user.password_hash in the same transaction. No second bcrypt is generated, and no password, request
-- body or fast hash is ever stored here: the format check below makes the table itself refuse anything that is
-- not a bcrypt string. The value is credential material of a possibly retired password: it is never returned by
-- an API, logged or exported, and only the Auth runtime role can read it (V025).
--
-- Validity is logical and decided by the database clock at lookup time: a receipt is usable while
-- expires_at > clock_timestamp(), whether or not the cleanup (V026) has removed the row yet. Removing or expiring a
-- receipt never frees the (actor, key) reservation, which lives in password_reset_audit for good.
CREATE TABLE auth_schema.password_reset_receipt (
  -- the audit record this receipt belongs to; one receipt per reset
  audit_id              uuid        NOT NULL,
  request_password_hash text        NOT NULL,
  -- the database clock at insertion plus 24 hours; set by the statement that inserts the receipt, not by a default,
  -- so the window is never silently changed by an omitted value
  expires_at            timestamptz NOT NULL,
  CONSTRAINT pk_password_reset_receipt PRIMARY KEY (audit_id),
  -- $2a$, $2b$ or $2y$, a two-digit cost and 53 characters of salt and digest: 60 characters in total
  CONSTRAINT chk_password_reset_receipt_bcrypt CHECK (request_password_hash ~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$')
);
