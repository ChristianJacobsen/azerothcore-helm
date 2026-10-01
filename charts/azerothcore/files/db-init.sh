#!/usr/bin/env bash
# The chart runs this on every install and upgrade, so every step must be safe
# to repeat. dbimport applies only the SQL updates that a database lacks.
set -euo pipefail

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

DB_HOST="${DB_HOST:?DB_HOST is required}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:?DB_USER is required}"
DB_PASSWORD="${DB_PASSWORD:?DB_PASSWORD is required}"
DB_ADMIN_USER="${DB_ADMIN_USER:-}"
DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}"
DB_AUTH="${DB_AUTH:?DB_AUTH is required}"
DB_WORLD="${DB_WORLD:?DB_WORLD is required}"
DB_CHARACTERS="${DB_CHARACTERS:?DB_CHARACTERS is required}"
DB_PLAYERBOTS="${DB_PLAYERBOTS:-}"
REALM_ID="${REALM_ID:-1}"
REALM_NAME="${REALM_NAME:-}"
REALM_ADDRESS="${REALM_ADDRESS:-}"
REALM_PORT="${REALM_PORT:-}"
MYSQL_WAIT_ATTEMPTS="${MYSQL_WAIT_ATTEMPTS:-120}"
MYSQL_WAIT_INTERVAL_SECONDS="${MYSQL_WAIT_INTERVAL_SECONDS:-5}"
MYSQL_CONNECT_TIMEOUT_SECONDS="${MYSQL_CONNECT_TIMEOUT_SECONDS:-5}"
# The realmlist row of the base SQL uses these.
DEFAULT_WORLD_PORT=8085
GAME_BUILD=12340

[[ "$REALM_ID" =~ ^[0-9]+$ ]] || die "REALM_ID must be a number"
[[ -z "$REALM_PORT" || "$REALM_PORT" =~ ^[0-9]+$ ]] || die "REALM_PORT must be a number"

sql_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\'/\\\'}"; }

sql_as() {
  local user="$1" pass="$2" db="$3"; shift 3
  local args=(-h "$DB_HOST" -P "$DB_PORT" -u "$user" --batch --skip-column-names)
  [ -n "$db" ] && args+=(-D "$db")
  MYSQL_PWD="$pass" mysql "${args[@]}" "$@"
}
app() { local db="$1"; shift; sql_as "$DB_USER" "$DB_PASSWORD" "$db" "$@"; }
admin() { sql_as "$DB_ADMIN_USER" "$DB_ADMIN_PASSWORD" "" "$@"; }

probe_user="$DB_USER"; probe_pass="$DB_PASSWORD"
if [ -n "$DB_ADMIN_USER" ]; then probe_user="$DB_ADMIN_USER"; probe_pass="$DB_ADMIN_PASSWORD"; fi
for attempt in $(seq 1 "$MYSQL_WAIT_ATTEMPTS"); do
  if sql_as "$probe_user" "$probe_pass" "" --connect-timeout="$MYSQL_CONNECT_TIMEOUT_SECONDS" -e 'SELECT 1' >/dev/null 2>&1; then break; fi
  [ "$attempt" = "$MYSQL_WAIT_ATTEMPTS" ] && die "cannot connect to MySQL at $DB_HOST:$DB_PORT as $probe_user"
  log "waiting for MySQL at $DB_HOST:$DB_PORT"
  sleep "$MYSQL_WAIT_INTERVAL_SECONDS"
done

databases=("$DB_AUTH" "$DB_WORLD" "$DB_CHARACTERS")
[ -n "$DB_PLAYERBOTS" ] && databases+=("$DB_PLAYERBOTS")

if [ -n "$DB_ADMIN_USER" ]; then
  for db in "${databases[@]}"; do
    admin -e "CREATE DATABASE IF NOT EXISTS \`$db\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  done
  if [ "$DB_USER" != "$DB_ADMIN_USER" ]; then
    log "setting up database user $DB_USER"
    user="'$(sql_escape "$DB_USER")'@'%'"
    pw="$(sql_escape "$DB_PASSWORD")"
    {
      echo "CREATE USER IF NOT EXISTS $user IDENTIFIED BY '$pw';"
      echo "ALTER USER $user IDENTIFIED BY '$pw';"
      for db in "${databases[@]}"; do
        echo "GRANT ALL PRIVILEGES ON \`$db\`.* TO $user;"
      done
    } | admin
  fi
fi

log "running dbimport"
# The entrypoint of the image writes dbimport.conf from its template.
bash /azerothcore/entrypoint.sh /azerothcore/env/dist/bin/dbimport

if ! app "$DB_AUTH" -e "SELECT id FROM realmlist WHERE id = $REALM_ID;" | grep -q .; then
  log "creating realmlist row $REALM_ID"
  app "$DB_AUTH" -e "INSERT INTO realmlist (id, name, address, port, gamebuild) VALUES ($REALM_ID, '$(sql_escape "${REALM_NAME:-AzerothCore}")', '$(sql_escape "${REALM_ADDRESS:-127.0.0.1}")', ${REALM_PORT:-$DEFAULT_WORLD_PORT}, $GAME_BUILD);"
fi
set_parts=()
[ -n "$REALM_NAME" ] && set_parts+=("name = '$(sql_escape "$REALM_NAME")'")
[ -n "$REALM_ADDRESS" ] && set_parts+=("address = '$(sql_escape "$REALM_ADDRESS")'")
[ -n "$REALM_PORT" ] && set_parts+=("port = $REALM_PORT")
if [ "${#set_parts[@]}" -gt 0 ]; then
  sql="UPDATE realmlist SET $(IFS=,; echo "${set_parts[*]}") WHERE id = $REALM_ID;"
  log "$sql"
  app "$DB_AUTH" -e "$sql"
fi

log "database initialization complete"
