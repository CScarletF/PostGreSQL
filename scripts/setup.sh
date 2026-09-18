#!/usr/bin/env bash
# scripts/setup.sh -- one-shot webapp_postgres provisioning.
#
# Reads scripts/config.env, then: symlinks the Ansible SSH keys into
# /root/.ssh/ if missing (see README's Phase 3 addendum for why this is
# needed at all), confirms python3-psycopg2 is present on the target
# host, writes a gitignored webapp_postgres_secrets.yml from config.env,
# and runs webapp_postgres.yml -- no other command needed.
#
# Usage:
#   git clone <this repo> && cd autobase-postgresql
#   cp scripts/config.env.example scripts/config.env
#   # fill in scripts/config.env
#   sudo scripts/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$SCRIPT_DIR/config.env"

if [[ $EUID -ne 0 ]]; then
	echo "Must run as root (sudo) -- webapp_postgres.yml connects using keys under /root/.ssh/." >&2
	exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
	echo "ansible-playbook not found on PATH." >&2
	exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "scripts/config.env not found." >&2
	echo "Copy scripts/config.env.example to scripts/config.env, fill in real values, then re-run." >&2
	exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

REQUIRED_VARS=(
	WEBAPP_SUPERUSER_PASSWORD
	WEBAPP_VIP
	WEBAPP_VIP_PORT
	WEBAPP_DB_NAME
	WEBAPP_APP_USER
	WEBAPP_MODULES_DIR
	TARGET_HOST
	INVENTORY_PATH
	SSH_KEY_CONTROLLER
	SSH_KEY_TARGET
)

for var in "${REQUIRED_VARS[@]}"; do
	if [[ -z "${!var:-}" ]]; then
		echo "config.env: $var is not set." >&2
		exit 1
	fi
done

cd "$REPO_ROOT"

if [[ ! -f "$INVENTORY_PATH" ]]; then
	echo "Inventory not found at $INVENTORY_PATH (check INVENTORY_PATH in config.env)." >&2
	exit 1
fi

echo "==> Symlinking SSH keys into /root/.ssh/ (idempotent)"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
for key_path in "$SSH_KEY_CONTROLLER" "$SSH_KEY_TARGET"; do
	if [[ ! -f "$key_path" ]]; then
		echo "SSH key not found: $key_path" >&2
		exit 1
	fi
	key_name="$(basename "$key_path")"
	link_path="/root/.ssh/$key_name"
	if [[ ! -e "$link_path" ]]; then
		ln -s "$key_path" "$link_path"
		echo "  linked $link_path -> $key_path"
	else
		echo "  $link_path already present"
	fi
done

echo "==> Checking python3-psycopg2 on $TARGET_HOST"
if ansible "$TARGET_HOST" -i "$INVENTORY_PATH" -m command -a "python3 -c 'import psycopg2'" >/dev/null 2>&1; then
	echo "  already present"
else
	echo "  not found, installing"
	ansible "$TARGET_HOST" -i "$INVENTORY_PATH" -b -m apt -a "name=python3-psycopg2 state=present update_cache=true"
fi

echo "==> Writing webapp_postgres_secrets.yml (gitignored)"
cat > "$REPO_ROOT/webapp_postgres_secrets.yml" <<-EOF
	webapp_postgres_superuser_password: "$WEBAPP_SUPERUSER_PASSWORD"
	EOF
chmod 600 "$REPO_ROOT/webapp_postgres_secrets.yml"

echo "==> Running webapp_postgres.yml"
ansible-playbook webapp_postgres.yml \
	-i "$INVENTORY_PATH" \
	-e @webapp_postgres_secrets.yml \
	-e webapp_postgres_vip="$WEBAPP_VIP" \
	-e webapp_postgres_vip_port="$WEBAPP_VIP_PORT" \
	-e webapp_postgres_db_name="$WEBAPP_DB_NAME" \
	-e webapp_postgres_app_user="$WEBAPP_APP_USER" \
	-e webapp_postgres_modules_dir="$WEBAPP_MODULES_DIR"

echo "==> Done."