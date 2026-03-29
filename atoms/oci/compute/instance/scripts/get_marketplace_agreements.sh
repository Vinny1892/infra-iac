#!/usr/bin/env bash
# Reads JSON from stdin: {"listing_id": "...", "listing_version": "...", "compartment_id": "..."}
# Returns JSON: {"signature": "...", "eula_link": "...", "oracle_terms_of_use_link": "...", "time_retrieved": "..."}
set -euo pipefail

input=$(cat)
listing_id=$(echo "$input"    | python3 -c "import sys,json; print(json.load(sys.stdin)['listing_id'])")
listing_version=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin)['listing_version'])")
compartment_id=$(echo "$input" | python3 -c "import sys,json; print(json.load(sys.stdin)['compartment_id'])")

result=$(oci compute pic agreements get \
  --listing-id "$listing_id" \
  --listing-resource-version "$listing_version" \
  --compartment-id "$compartment_id" 2>&1)

echo "$result" | python3 -c "
import sys, json
data = json.load(sys.stdin)
d = data['data']
print(json.dumps({
  'signature': d['signature'],
  'eula_link': d['eula-link'],
  'oracle_terms_of_use_link': d['oracle-terms-of-use-link'],
  'time_retrieved': d['time-retrieved']
}))
"
