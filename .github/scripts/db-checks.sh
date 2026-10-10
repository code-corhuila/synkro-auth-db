# Assertions for the -db check steps of db-ci.yml. A step sets PSQL, then
# sources this file from the repository root. A failed assertion exits the step.

# $1 = description, $2 = SQL returning one value, $3 = expected value
expect_eq() {
  local got
  got=$($PSQL -tAc "$2" 2>&1 || true)
  if [ "$got" != "$3" ]; then
    echo "FAIL: $1: expected '$3', got '$got'"; exit 1
  fi
  echo "PASS: $1"
}

# $1 = SQLSTATE, $2 = constraint or column name, $3 = SQL that must violate it
expect_violation() {
  local out
  if out=$($PSQL -v VERBOSITY=verbose -c "$3" 2>&1); then
    echo "FAIL: accepted, expected $2 ($1) to reject: $3"; exit 1
  fi
  if ! grep -q "ERROR:  $1: .*\"$2\"" <<< "$out"; then
    echo "FAIL: rejected for the wrong reason, expected $2 ($1), got:"
    echo "$out"; exit 1
  fi
  echo "PASS: rejected by $2 ($1)"
}

# $1 = SQL that must succeed, $2 = what it proves
expect_accepted() {
  $PSQL -c "$1" || { echo "FAIL: rejected a valid control: $2"; exit 1; }
  echo "PASS: accepted (control): $2"
}
