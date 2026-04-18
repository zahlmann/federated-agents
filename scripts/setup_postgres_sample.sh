#!/bin/zsh
set -euo pipefail

# Spins up a local Postgres container that hosts the cardiac registry table.
# The EHR CSV stays as a file on disk; the registry lives in Postgres so the
# receiver app can exercise both data-source kinds in one session.

container_name="federated-agents-postgres"
image="postgres:16"
port=5433
db=cardiac
user=agent
password=agent
table=cardiac_admissions_registry
csv_path="$HOME/cardiac_admissions_registry.csv"

if ! command -v docker >/dev/null; then
  echo "docker is not installed. Install Docker Desktop or run brew install postgresql and create the table manually." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "The Docker daemon is not running. Start Docker Desktop first, then rerun this script." >&2
  exit 1
fi

if [[ ! -f "$csv_path" ]]; then
  echo "CSV not found at $csv_path. Regenerate the sample CSVs first." >&2
  exit 1
fi

echo "→ starting $container_name on port $port"
if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
  docker start "$container_name" >/dev/null
else
  docker run -d \
    --name "$container_name" \
    -e "POSTGRES_USER=$user" \
    -e "POSTGRES_PASSWORD=$password" \
    -e "POSTGRES_DB=$db" \
    -p "$port:5432" \
    "$image" >/dev/null
fi

echo "→ waiting for postgres to accept connections"
for attempt in $(seq 1 30); do
  if docker exec "$container_name" pg_isready -U "$user" -d "$db" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "→ creating table $table"
docker exec -i "$container_name" psql -U "$user" -d "$db" <<SQL
DROP TABLE IF EXISTS $table;
CREATE TABLE $table (
  patient_id TEXT,
  procedure_category TEXT,
  readmitted_within_30d INTEGER,
  mortality_within_30d INTEGER,
  complication_flag INTEGER,
  ef_at_discharge_band TEXT
);
SQL

echo "→ loading $csv_path"
docker exec -i "$container_name" psql -U "$user" -d "$db" -c "\copy $table FROM STDIN WITH CSV HEADER" < "$csv_path"

row_count=$(docker exec "$container_name" psql -U "$user" -d "$db" -Atc "SELECT count(*) FROM $table;")

cat <<INFO
→ ready
  host:      127.0.0.1
  port:      $port
  database:  $db
  user:      $user
  password:  $password
  table:     $table
  rows:      $row_count

In the receiver app, click "Add Postgres" and paste these values.
INFO
