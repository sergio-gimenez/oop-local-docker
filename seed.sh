#!/usr/bin/env bash
# After `docker compose up -d`: one zone per operator in SRM, each FM registers the other as
# a partner with an agreement permitting the other's zone, then A and B federate both ways.
set -euo pipefail
cd "$(dirname "$0")"

ZONE_A=0b1c7a52-4f3e-4c1a-9a53-6f0e6d2a1001
ZONE_B=0b1c7a52-4f3e-4c1a-9a53-6f0e6d2a2001
TOKEN_URL=http://keycloak:8080/realms/federation/protocol/openid-connect/token

wait_for() {
  for _ in $(seq 1 60); do curl -sf -o /dev/null "$1" && return; sleep 2; done
  echo "timed out waiting for $1" >&2; exit 1
}

seed_zone() {  # postgres zone_id ref name region provider
  PG_CONTAINER="oop-r2-$1-1" SRM_DB=srm ZONE_ID="$2" ZONE_REF="$3" ZONE_NAME="$4" \
    REGION="$5" PROVIDER="$6" CONTROL_PATH_REF="$3" ./seed-srm-topology.sh
}

register_partner() {  # fm_port name mcc_mnc their_client our_client their_fm
  curl -sf -X POST "localhost:$1/internal/partners" -H 'content-type: application/json' -d "{
    \"name\": \"$2\", \"mcc_mnc\": \"$3\", \"oauth2_client_id\": \"$4\",
    \"base_url\": \"http://$6:8082\", \"our_client_id\": \"$5\",
    \"our_client_secret_ref\": \"/secrets/$5\", \"token_endpoint\": \"$TOKEN_URL\",
    \"status\": \"active\"}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])'
}

# What each agreement grants in the zone: GSMA reservedComputeResources, quota and flavours.
ZONE_TERMS='{"reservedComputeResources": [{"cpuArchType": "ISA_X86_64", "numCPU": "4", "memory": 8192}],
 "computeResourceQuotaLimits": [{"cpuArchType": "ISA_X86_64", "numCPU": "8", "memory": 16384}],
 "flavoursSupported": [{"flavourId": "small", "cpuArchType": "ISA_X86_64", "numCPU": 1,
   "memorySize": 1024, "storageSize": 10,
   "supportedOSTypes": [{"architecture": "x86_64", "distribution": "UBUNTU",
     "version": "OS_VERSION_UBUNTU_2204_LTS", "license": "OS_LICENSE_TYPE_FREE"}]}]}'

agree() {  # postgres partner_id zone_id
  docker exec -i "oop-r2-$1-1" psql -v ON_ERROR_STOP=1 -qAt -U postgres -d fm \
    -v partner="$2" -v zone="$3" -v terms="$ZONE_TERMS" >/dev/null <<'SQL'
INSERT INTO federation_agreements (partner_op_id, permitted_api_types, permitted_zone_ids,
                                   zone_resources, valid_from, status)
VALUES (:'partner', '["edge-application-management", "install-app", "remove-app"]', jsonb_build_array(:'zone'),
        jsonb_build_object(:'zone', :'terms'::jsonb), now() - interval '1 day', 'active');
SQL
}

federate() {  # fm_port partner_id our_fm
  curl -sf -X POST "localhost:$1/internal/partners/$2/federations" -H 'content-type: application/json' \
    -d "{\"initialDate\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
         \"partnerStatusLink\": \"http://$3:8082/operatorplatform/federation/v1/callbacks/partner-status\"}" \
    | python3 -c 'import sys,json; b=json.load(sys.stdin); print(b["federationContextId"], [z["zoneId"] for z in b.get("offeredAvailabilityZones") or []])'
}

for url in localhost:18082/healthz localhost:28082/healthz localhost:18083/readyz localhost:28083/readyz \
           localhost:18080/realms/federation; do
  wait_for "$url"
done

seed_zone postgres-a "$ZONE_A" k3s-a madrid-1 Madrid operator-a
seed_zone postgres-b "$ZONE_B" k3s-b paris-1 Paris operator-b

B_AT_A=$(register_partner 18083 "Operator B" 001-02 originating-op-2 originating-op-1 fm-b)
A_AT_B=$(register_partner 28083 "Operator A" 001-01 originating-op-1 originating-op-2 fm-a)
echo "FM-A knows B as $B_AT_A, FM-B knows A as $A_AT_B"

agree postgres-b "$A_AT_B" "$ZONE_B"
agree postgres-a "$B_AT_A" "$ZONE_A"

echo "A -> B: $(federate 18083 "$B_AT_A" fm-a)"
echo "B -> A: $(federate 28083 "$A_AT_B" fm-b)"
