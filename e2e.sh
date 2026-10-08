#!/usr/bin/env bash
# Operator A deploys an App Provider's app on operator B's zone, over the GSMA EWBI:
#   1 federation (seed.sh)   2 ZoneSubscribe via OEG-A   3 onboard + InstallApp via FM-A
# Needs a stack from `docker compose up -d` that seed.sh has already run on.
set -euo pipefail

ZONE_B=0b1c7a52-4f3e-4c1a-9a53-6f0e6d2a2001
psql_at() { docker exec "oop-r2-postgres-$1-1" psql -U postgres -d "$2" -qAt -c "$3"; }
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

B=$(psql_at a fm "select id from partner_ops where name = 'Operator B'")
CTX=$(curl -sf "localhost:18081/platform/v1/federation/partners/$B/federations" \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["FederationContextId"])')
echo "partner B at A: $B, federation context: $CTX"

step "2 ZoneSubscribe paris-1 (OEG-A -> FM-A -> FM-B)"
curl -sf -o /dev/null -X POST "localhost:18081/platform/v1/federation/partners/$B/federations/$CTX/zones" \
  -H 'content-type: application/json' \
  -d "{\"acceptedAvailabilityZones\": [\"$ZONE_B\"],
       \"availZoneNotifLink\": \"http://fm-a:8082/operatorplatform/federation/v1/callbacks/zone-resource\"}"
FLAVOURS=$(psql_at a fm "select resource_data->>'flavour_ids' from shared_resource_catalogues where resource_type = 'accepted_zone'")
echo "FM-A accepted paris-1 with flavours $FLAVOURS"

step "3a App Provider registers nginx at operator A (OEG-A -> SRM-A)"
APP_ID=$(curl -sf -X POST localhost:18081/edge-application-management/vwip/apps \
  -H 'content-type: application/json' -d '{
    "name": "hello_nginx", "appProvider": "acme_apps_ltd", "version": "1.0.0", "packageType": "CONTAINER",
    "appRepo": {"type": "PUBLICREPO", "imagePath": "nginx:1.27-alpine"},
    "requiredResources": {"infraKind": "kubernetes", "isStandalone": false,
      "applicationResources": {"cpuPool": {"numCPU": 1, "memory": 256,
        "topology": {"minNumberOfNodes": 1, "minNodeCpu": 1, "minNodeMemory": 256}}}},
    "componentSpec": [{"componentName": "web", "networkInterfaces": [
      {"interfaceId": "http", "protocol": "TCP", "port": 80, "visibilityType": "VISIBILITY_EXTERNAL"}]}]}' \
  | python3 -c 'import sys, json; print(json.load(sys.stdin)["appId"])')
SPEC=$(psql_at a srm "select id from service_specification where name = 'hello_nginx' order by created_at desc limit 1")
ZONE_AT_A=$(curl -sf localhost:18083/internal/federated-zones | python3 -c 'import sys, json; print(json.load(sys.stdin)[0]["zone_id"])')
echo "SRM-A spec $SPEC, FM-A's id for paris-1 $ZONE_AT_A"

step "3b deploy on partner B (FM-A: UploadFile, UploadArtefact, OnboardApplication, InstallApp)"
RESULT=$(curl -sf -X POST "localhost:18083/internal/partners/$B/federations/$CTX/applications" \
  -H 'content-type: application/json' -d "{\"serviceSpecificationId\": \"$SPEC\", \"zoneId\": \"$ZONE_AT_A\"}")
echo "$RESULT"
INSTANCE=$(echo "$RESULT" | python3 -c 'import sys, json; print(json.load(sys.stdin)["appInstIdentifier"])')

step "FM-B side"
psql_at b fm "select resource_type, count(*) from shared_resource_catalogues where resource_type in ('file', 'artefact', 'application') group by 1 order by 1"
psql_at b srm "select 'SRM-B spec: ' || name || ', tenant ' || app_provider_id from service_specification where name = 'hello_nginx'"

step "waiting for onInstanceStatusEvent at FM-A"
for _ in $(seq 1 40); do
  STATUS=$(psql_at a fm "select status from federation_transactions where direction = 'outbound' and external_resource_id = '$INSTANCE'")
  [[ "$STATUS" == completed || "$STATUS" == failed ]] && break
  sleep 3
done
psql_at a fm "select 'FM-A install-app: ' || status || ' ' || response_summary from federation_transactions where external_resource_id = '$INSTANCE' and direction = 'outbound'"
[[ "$STATUS" == completed ]] || fail "instance did not become READY"

step "k3s-b (operator B's cluster)"
NS=$(docker exec oop-r2-k3s-b-1 kubectl get ns -o name | grep "oop-${INSTANCE:0:20}" | cut -d/ -f2)
docker exec oop-r2-k3s-b-1 kubectl get deploy,svc,pods -n "$NS" --no-headers
SVC=$(docker exec oop-r2-k3s-b-1 kubectl get svc -n "$NS" -o name | cut -d/ -f2)
# the Service can lag the pod by a few seconds, so retry before calling it a failure
for attempt in 1 2 3 4 5; do
  CODE=$(docker exec oop-r2-k3s-b-1 kubectl run "curl-check-$attempt" -n "$NS" --rm -i --restart=Never -q \
    --image=curlimages/curl:8.10.1 -- curl -s -m 5 -o /dev/null -w '%{http_code}' \
    "http://$SVC.$NS.svc.cluster.local" 2>/dev/null || true)
  [[ "$CODE" == 200 ]] && break
  sleep 3
done
echo "nginx answers: http $CODE"
[[ "$CODE" == 200 ]] || fail "nginx in k3s-b did not answer"


step "4 App Provider deploys on Paris through OEG-A (OEG-A -> SRM-A -> command.fm.service.deploy -> FM-A -> FM-B)"
INSTANCE_A=$(curl -sf -X POST localhost:18081/edge-application-management/vwip/appinstances \
  -H 'content-type: application/json' \
  -d "{\"name\": \"hello_paris\", \"appId\": \"$APP_ID\", \"edgeCloudZoneId\": \"$ZONE_AT_A\"}" \
  | python3 -c 'import sys, json; b = json.load(sys.stdin); print(b["appInstanceId"], b["status"])')
echo "OEG-A answered: $INSTANCE_A"
INSTANCE_A=${INSTANCE_A%% *}
for _ in $(seq 1 40); do
  STATE=$(psql_at a oeg "select state from app_instances where app_instance_id = '$INSTANCE_A'")
  [[ "$STATE" == ready || "$STATE" == failed ]] && break
  sleep 3
done
echo "OEG-A instance state: $STATE"
psql_at a srm "select 'SRM-A order: ' || state from service_order where operation_id = (select operation_id from service_order order by created_at desc limit 1)" || true
[[ "$STATE" == ready ]] || fail "OEG-A never reported the partner deploy ready"
docker exec oop-r2-k3s-b-1 kubectl get pods -A --no-headers | grep -v kube-system

echo; echo "PASS: operator A's app runs in operator B's cluster, from the operator and from the App Provider"
