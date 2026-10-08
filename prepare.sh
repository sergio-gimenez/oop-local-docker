#!/usr/bin/env bash
# Clone the OOP components into ./src and write the partner client secrets FM reads.
# Re-running fetches and resets each checkout to its ref.
#   FM_REF, OEG_REF, SRM_REF   branch to build (defaults below)
#   SRM_MERGE                  extra SRM branch merged on top (empty to skip)
set -euo pipefail
cd "$(dirname "$0")"

BASE=https://labs.etsi.org/rep/oop/code
FM_REF=${FM_REF:-develop}
OEG_REF=${OEG_REF:-develop}
# The federated deploy lives on SRM's fix/fm-wait-for-partner (MR !31, stacked on !29 and !28);
# the HTTP seam tf-sdk-mock answers lives on test/mock-tfsdk. Neither is in develop yet.
SRM_REF=${SRM_REF:-fix/fm-wait-for-partner}
SRM_MERGE=${SRM_MERGE-test/mock-tfsdk}

checkout() {  # repo ref
  local dir="src/$1"
  [[ -d "$dir/.git" ]] || git clone -q "$BASE/$1.git" "$dir"
  git -C "$dir" fetch -q origin
  git -C "$dir" checkout -q --detach "origin/$2"
  git -C "$dir" reset -q --hard "origin/$2"
  echo "$1: $2 ($(git -C "$dir" rev-parse --short HEAD))"
}

mkdir -p src secrets
checkout federation-manager "$FM_REF"
checkout open-exposure-gateway "$OEG_REF"
checkout service-resource-manager "$SRM_REF"

if [[ -n "$SRM_MERGE" ]]; then
  if ! git -C src/service-resource-manager -c user.name=harness -c user.email=harness@localhost \
      merge -q --no-edit "origin/$SRM_MERGE" >/dev/null 2>&1; then
    git -C src/service-resource-manager merge --abort
    echo "service-resource-manager: origin/$SRM_MERGE does not merge cleanly onto $SRM_REF." >&2
    echo "Merge it by hand in src/service-resource-manager (keep both sides), then rerun without SRM_MERGE:" >&2
    echo "  SRM_MERGE= ./prepare.sh   # careful: this resets the checkout; or skip prepare.sh" >&2
    exit 1
  fi
  echo "service-resource-manager: merged $SRM_MERGE"
fi

# FM reads our client secret at each partner from a file; these are the dev secrets of the
# two partner clients in FM's own realm import, which Keycloak loads.
python3 - <<'PY'
import json
realm = json.load(open("src/federation-manager/keycloak/realm-import.json"))
for client in realm["clients"]:
    if client["clientId"] in ("originating-op-1", "originating-op-2"):
        with open(f"secrets/{client['clientId']}", "w") as f:
            f.write(client["secret"])
        print(f"secrets/{client['clientId']} written")
PY
