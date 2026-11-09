#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
expected="$(awk 'NR==1 {print $1}' docs/original-script.sha256)"
if command -v sha256 >/dev/null 2>&1; then
  actual="$(sha256 -q disk_health_audit.sh)"
elif command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum disk_health_audit.sh | awk '{print $1}')"
else
  echo 'Missing SHA-256 utility' >&2
  exit 1
fi
[ "$expected" = "$actual" ] || { echo 'SHA256 MISMATCH' >&2; exit 1; }
echo 'SOURCE_SHA256=PASS'
if command -v bash >/dev/null 2>&1; then
  bash -n disk_health_audit.sh
  echo 'BASH_SYNTAX=PASS'
else
  echo 'BASH_SYNTAX=SKIPPED (bash not installed)'
fi
