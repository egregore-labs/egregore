#!/bin/bash
# Provision a hosted Egregore VPS for an existing org
TOKEN=$(grep '^GITHUB_TOKEN=' .env | cut -d'=' -f2-)
API_URL=$(jq -r '.api_url' egregore.json)
SLUG=$(jq -r '.slug // .org_name' egregore.json)
ORG_NAME=$(jq -r '.org_name' egregore.json)
GITHUB_ORG=$(jq -r '.github_org' egregore.json)
REPO_NAME=$(jq -r '.repo_name // empty' egregore.json)
if [ -z "$REPO_NAME" ]; then echo "ERROR: repo_name not set in egregore.json"; exit 1; fi

echo "Provisioning hosted Egregore for $ORG_NAME ($SLUG)..."
echo "API: $API_URL"

curl -s -X POST "$API_URL/api/hosting/provision" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg slug "$SLUG" --arg org "$ORG_NAME" --arg gh "$GITHUB_ORG" --arg repo "$REPO_NAME" \
    '{org_slug: $slug, org_name: $org, github_org: $gh, repo_name: $repo}')" | jq .
