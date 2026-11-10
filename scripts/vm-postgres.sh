#!/usr/bin/env bash
set -euo pipefail
: "${SSH_USER:?Set the Ubuntu image SSH user}"
: "${SSH_KEY:?Set path to the SSH private key}"
: "${PG_PASSWORD_FILE:?Set path to a file containing the test database password}"
: "${PG_PACKAGE_VERSION:?Set the exact Ubuntu 22.04 postgresql-14 package version}"
for c in terraform jq ssh base64; do command -v "$c" >/dev/null || { echo "Missing $c" >&2; exit 1; }; done
[[ -r "$SSH_KEY" && -r "$PG_PASSWORD_FILE" && -s "$PG_PASSWORD_FILE" ]] || { echo 'SSH key or password file missing/empty' >&2; exit 1; }
[[ "$PG_PACKAGE_VERSION" =~ ^[0-9][a-zA-Z0-9.+:~_-]*$ ]] || { echo 'Invalid PostgreSQL package version' >&2; exit 1; }
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo 'Invalid SSH user' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
outputs=$(terraform -chdir="$ROOT/infra" output -json)
bastion=$(jq -er '.bastion_public_ip.value' <<<"$outputs")
admin=$(jq -er '.private_ips.value.admin' <<<"$outputs")
pg=$(jq -er '.private_ips.value.pg' <<<"$outputs")
node_cidr=$(jq -er '.network_cidrs.value.kubernetes' <<<"$outputs")
password64=$(base64 -w0 < "$PG_PASSWORD_FILE")
ssh_config=$(mktemp)
chmod 600 "$ssh_config"
trap 'rm -f "$ssh_config"' EXIT
cat > "$ssh_config" <<CONFIG
Host *
  User $SSH_USER
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
Host spike-bastion
  HostName $bastion
Host spike-admin
  HostName $admin
  ProxyJump spike-bastion
Host spike-pg
  HostName $pg
  ProxyJump spike-admin
CONFIG
# Secrets travel only on SSH stdin, never in a command argument or Terraform state.
{ printf 'PG_PASSWORD_B64=%q\nNODE_CIDR=%q\nPG_PACKAGE_VERSION=%q\n' "$password64" "$node_cidr" "$PG_PACKAGE_VERSION"; cat <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y "postgresql-14=$PG_PACKAGE_VERSION" "postgresql-client-14=$PG_PACKAGE_VERSION"
printf 'Installed PostgreSQL package versions (record in results):\n'
dpkg-query -W -f='${Package} ${Version}\n' postgresql-14 postgresql-client-14
version=$(pg_lsclusters --no-header | awk 'NR==1 {print $1}')
[ "$version" = 14 ] || { echo "Expected Ubuntu 22.04 PostgreSQL 14, got $version" >&2; exit 1; }
sudo sed -i "s/^#\?listen_addresses = .*/listen_addresses = '*' /" /etc/postgresql/14/main/postgresql.conf
printf 'host spike spike %s scram-sha-256\n' "$NODE_CIDR" | sudo tee -a /etc/postgresql/14/main/pg_hba.conf >/dev/null
sudo systemctl restart postgresql
password=$(printf '%s' "$PG_PASSWORD_B64" | base64 -d)
export PGPASSWORD_SETUP="$password"
sudo --preserve-env=PGPASSWORD_SETUP -u postgres psql -v ON_ERROR_STOP=1 <<'SQL'
\getenv pw PGPASSWORD_SETUP
SELECT format('CREATE ROLE spike LOGIN PASSWORD %L', :'pw') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname='spike') \gexec
SELECT format('ALTER ROLE spike PASSWORD %L', :'pw') \gexec
SELECT 'CREATE DATABASE spike OWNER spike' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='spike') \gexec
SQL
REMOTE
} | ssh -F "$ssh_config" spike-pg 'bash -s'
