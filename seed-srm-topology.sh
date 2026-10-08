#!/usr/bin/env bash
# Seed one deployable zone into an SRM database. Run after SRM has started, since SRM
# creates its tables on startup.
#
#   PG_CONTAINER=oop-r2-postgres-a-1 SRM_DB=srm \
#   ZONE_ID=0b1c7a52-4f3e-4c1a-9a53-6f0e6d2a1001 ZONE_REF=k3s-a ZONE_NAME=madrid-1 \
#   REGION=Madrid PROVIDER=operator-a CONTROL_PATH_REF=k3s-a ./seed-srm-topology.sh

set -euo pipefail

: "${PG_CONTAINER:?}" "${ZONE_ID:?}" "${ZONE_REF:?}" "${ZONE_NAME:?}" "${REGION:?}"
: "${PROVIDER:?}" "${CONTROL_PATH_REF:?}"
SRM_DB="${SRM_DB:-srm_db}"
PG_USER="${PG_USER:-postgres}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"

psql_srm() {
  docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -qAt -U "$PG_USER" -d "$SRM_DB" "$@"
}

deadline=$((SECONDS + WAIT_SECONDS))
until [[ "$(psql_srm -c "select to_regclass('public.control_path_binding') is not null" 2>/dev/null)" == "t" ]]; do
  if (( SECONDS >= deadline )); then
    echo "SRM tables not found in $SRM_DB after ${WAIT_SECONDS}s; is SRM running?" >&2
    exit 1
  fi
  sleep 2
done

psql_srm \
  -v zone_id="$ZONE_ID" -v zone_ref="$ZONE_REF" -v zone_name="$ZONE_NAME" \
  -v region="$REGION" -v provider="$PROVIDER" -v control_path_ref="$CONTROL_PATH_REF" \
  < "$(dirname "$0")/seed-srm-topology.sql"

echo "seeded zone $ZONE_NAME ($ZONE_ID) into $PG_CONTAINER/$SRM_DB"
