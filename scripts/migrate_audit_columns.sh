#!/usr/bin/env bash
# scripts/migrate_audit_columns.sh -- applies add_audit_columns.sql to the
# live webapp database as the Postgres superuser.
#
# Reads scripts/config.env (same file scripts/setup.sh uses) for the
# superuser password, VIP, port and database name. Shows the target and
# asks for confirmation before changing anything; --yes skips the prompt
# for unattended runs. Idempotent: re-running after success changes nothing.
#
# Usage:
#   scripts/migrate_audit_columns.sh
#   scripts/migrate_audit_columns.sh --yes
#
# Run it from srv-deploy-eng (needs the psql client and a route to the VIP).
# No sudo required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SCRIPT_DIR/config.env"
SQL_FILE="$REPO_ROOT/add_audit_columns.sql"

ASSUME_YES=0
if [[ "${1:-}" == "--yes" ]]; then
	ASSUME_YES=1
elif [[ $# -gt 0 ]]; then
	echo "Unknown argument: $1 (only --yes is supported)." >&2
	exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
	echo "psql not found on PATH." >&2
	exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "scripts/config.env not found. Copy scripts/config.env.example and fill it in." >&2
	exit 1
fi

if [[ ! -f "$SQL_FILE" ]]; then
	echo "add_audit_columns.sql not found at $SQL_FILE." >&2
	exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

for var in WEBAPP_SUPERUSER_PASSWORD WEBAPP_VIP WEBAPP_VIP_PORT WEBAPP_DB_NAME; do
	if [[ -z "${!var:-}" ]]; then
		echo "config.env: $var is not set." >&2
		exit 1
	fi
done

SUPERUSER="${WEBAPP_SUPERUSER:-postgres}"

echo "Target: database '$WEBAPP_DB_NAME' at $WEBAPP_VIP:$WEBAPP_VIP_PORT as '$SUPERUSER'"
echo "Action: add created_by/updated_by (FK to app_user) to equipment, assignment,"
echo "        product, sale, sale_item, recipe. Existing rows keep NULL."

if [[ $ASSUME_YES -ne 1 ]]; then
	read -r -p "Proceed? [y/N] " answer
	if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
		echo "Aborted, nothing changed."
		exit 0
	fi
fi

export PGPASSWORD="$WEBAPP_SUPERUSER_PASSWORD"
psql -h "$WEBAPP_VIP" -p "$WEBAPP_VIP_PORT" -U "$SUPERUSER" -d "$WEBAPP_DB_NAME" \
	-v ON_ERROR_STOP=1 -f "$SQL_FILE"

echo "==> Done. Re-run 'python setup.py' in the app repo to regenerate table_core.py."
