#!/bin/bash
set -euo pipefail

CLIENT_ID="Ov23lizB4nYEeIRsHTdb"
SCOPE="repo,admin:org"
TIMEOUT=300
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# Request device code
response=$(curl -s -X POST "https://github.com/login/device/code" \
  -H "Accept: application/json" \
  -d "client_id=$CLIENT_ID&scope=$SCOPE")

device_code=$(echo "$response" | jq -r '.device_code')
user_code=$(echo "$response" | jq -r '.user_code')
verification_uri=$(echo "$response" | jq -r '.verification_uri')
verification_uri_complete=$(echo "$response" | jq -r '.verification_uri_complete // empty')
interval=$(echo "$response" | jq -r '.interval')

if [ "$device_code" = "null" ] || [ -z "$device_code" ]; then
  echo "Failed to get device code from GitHub."
  echo "$response" | jq . 2>/dev/null || echo "$response"
  exit 1
fi

# Copy code to clipboard
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$user_code" | pbcopy
  echo ""
  echo "  Code copied to clipboard: $user_code"
  echo "  Opening your browser — just paste and hit Continue."
  echo ""
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "$user_code" | xclip -selection clipboard
  echo ""
  echo "  Code copied to clipboard: $user_code"
  echo "  Opening your browser — just paste and hit Continue."
  echo ""
else
  echo ""
  echo "  Your code: $user_code"
  echo "  Opening your browser — enter the code above."
  echo ""
fi

# Open browser — use verification_uri_complete if available, otherwise plain URI
url="${verification_uri_complete:-$verification_uri}"
if command -v open >/dev/null 2>&1; then
  open "$url"
elif command -v xdg-open >/dev/null 2>&1; then
  xdg-open "$url"
else
  echo "  Open this URL manually: $url"
fi

# Poll for authorization
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  sleep "$interval"
  elapsed=$((elapsed + interval))

  token_response=$(curl -s -X POST "https://github.com/login/oauth/access_token" \
    -H "Accept: application/json" \
    -d "client_id=$CLIENT_ID&device_code=$device_code&grant_type=urn:ietf:params:oauth:grant-type:device_code")

  error=$(echo "$token_response" | jq -r '.error // empty')
  access_token=$(echo "$token_response" | jq -r '.access_token // empty')

  if [ -n "$access_token" ]; then
    # Write token to .env
    if [ -f "$ENV_FILE" ] && grep -q '^GITHUB_TOKEN=' "$ENV_FILE"; then
      # Replace existing token
      sed -i '' "s|^GITHUB_TOKEN=.*|GITHUB_TOKEN=$access_token|" "$ENV_FILE" 2>/dev/null \
        || sed -i "s|^GITHUB_TOKEN=.*|GITHUB_TOKEN=$access_token|" "$ENV_FILE"
    else
      echo "GITHUB_TOKEN=$access_token" >> "$ENV_FILE"
    fi

    # Configure git credential helper (local to this repo, not global)
    git config credential.helper store
    # Write credential for github.com
    protocol_line="protocol=https
host=github.com
username=x-access-token
password=$access_token
"
    echo "$protocol_line" | git credential-store store 2>/dev/null || true

    echo "  Authorized!"
    exit 0
  fi

  case "$error" in
    authorization_pending) continue ;;
    slow_down) interval=$((interval + 5)) ;;
    *)
      echo "  Authorization failed: $error"
      echo "$token_response" | jq -r '.error_description // empty'
      exit 1
      ;;
  esac
done

echo "  Timed out waiting for authorization (${TIMEOUT}s)."
exit 1
