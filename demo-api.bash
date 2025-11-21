#!/bin/bash

# Stop on error
set -e

# --- CONFIGURATION ---
GCLOUD_BIN="$HOME/google-cloud-sdk/bin/gcloud"

PROJECT_ID=$($GCLOUD_BIN config get-value project)
PROJECT_NUMBER=$($GCLOUD_BIN projects describe $PROJECT_ID --format="value(projectNumber)")
USER_EMAIL=$($GCLOUD_BIN config get-value account)

REGION="us-central1"
SECRET_ID="weather-api-key"
PARAM_ID="json-weather-config"

# CRITICAL FIX: Use the REGIONAL Endpoint
# The global endpoint often rejects 'curl' requests for regional resources
API_ENDPOINT="https://parametermanager.$REGION.rep.googleapis.com/v1/projects/$PROJECT_ID/locations/$REGION"

# Service Account Config
SA_NAME="gpm-demo-runner"
SA_EMAIL="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
KEY_FILE="/tmp/gpm-demo-key.json"

echo "========================================================"
echo "üå§Ô∏è  GOOGLE CLOUD PARAMETER MANAGER: REGIONAL EDITION"
echo "    Endpoint: $API_ENDPOINT"
echo "========================================================"

# --- CLEANUP FUNCTION ---
cleanup() {
    echo -e "\n[Cleanup] removing key file..."
    rm -f $KEY_FILE
}
trap cleanup EXIT

# 1. ENABLE APIS
echo -e "\n[1/7] üõ†Ô∏è  Enabling APIs..."
$GCLOUD_BIN services enable \
    secretmanager.googleapis.com \
    parametermanager.googleapis.com \
    serviceusage.googleapis.com \
    --quiet

# 2. CREATE SERVICE ACCOUNT & KEYS
echo -e "\n[2/7] ü§ñ Setting up Service Account..."
if ! $GCLOUD_BIN iam service-accounts describe $SA_EMAIL --quiet >/dev/null 2>&1; then
    $GCLOUD_BIN iam service-accounts create $SA_NAME --display-name="Demo Runner" --quiet
    echo "    -> Created $SA_EMAIL"
fi

# Grant Permissions
$GCLOUD_BIN projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SA_EMAIL" \
    --role="roles/editor" \
    --condition=None --quiet > /dev/null

# Create Key
echo -e "\n[3/7] üîë Creating Key..."
$GCLOUD_BIN iam service-accounts keys create $KEY_FILE --iam-account=$SA_EMAIL --quiet

echo "    -> Waiting 10s for key propagation..."
sleep 10

# 3. AUTHENTICATE & PREPARE CURL
# We manually extract the token from the key file using gcloud
$GCLOUD_BIN auth activate-service-account --key-file=$KEY_FILE --quiet
# Scoped token for Cloud Platform
SA_TOKEN=$($GCLOUD_BIN auth print-access-token --scopes=https://www.googleapis.com/auth/cloud-platform)

# Switch back to user immediately to avoid messing up your terminal
$GCLOUD_BIN config set account $USER_EMAIL --quiet

AUTH_HEADER="Authorization: Bearer $SA_TOKEN"
CONTENT_HEADER="Content-Type: application/json"
# We send the Project ID header just in case
PROJECT_HEADER="X-Goog-User-Project: $PROJECT_ID"

# 4. CREATE SECRET (As User)
echo -e "\n[4/7] üîê Creating Secret (as User)..."
printf "my-super-secret-weather-key-123" | $GCLOUD_BIN secrets create $SECRET_ID --data-file=- --replication-policy="automatic" 2>/dev/null || true

# 5. CLEANUP OLD PARAMETER
echo -e "\n[5/7] üßπ Cleaning old state..."
curl -s -X DELETE -H "$AUTH_HEADER" -H "$PROJECT_HEADER" "$API_ENDPOINT/parameters/$PARAM_ID" > /dev/null || true
sleep 2

# 6. CREATE PARAMETER (Regional Endpoint)
echo -e "\n[6/7] ‚òÅÔ∏è  Creating Parameter Resource..."

# We use a loop because IAM permissions (Service Usage) take time to propagate
create_param_curl() {
    curl -s -X POST -H "$AUTH_HEADER" -H "$CONTENT_HEADER" -H "$PROJECT_HEADER" \
    "$API_ENDPOINT/parameters?parameter_id=$PARAM_ID" \
    -d '{"format": "JSON"}'
}

MAX_RETRIES=12
COUNT=0
SUCCESS=false

while [ $COUNT -lt $MAX_RETRIES ]; do
    echo -n "    -> Attempt $((COUNT+1))/$MAX_RETRIES: "
    RESPONSE=$(create_param_curl)
    
    if echo "$RESPONSE" | grep -q '"name":'; then
        echo "‚úÖ Success!"
        SUCCESS=true
        break
    elif echo "$RESPONSE" | grep -q "ALREADY_EXISTS"; then
        echo "‚úÖ Already Exists (OK)."
        SUCCESS=true
        break
    else
        # Clean error message
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // .')
        echo "‚è≥ Failed ($ERROR_MSG)"
        echo "       Waiting 5s..."
        sleep 5
        COUNT=$((COUNT+1))
    fi
done

if [ "$SUCCESS" = false ]; then
    echo "‚ùå FATAL: Failed after retries."
    exit 1
fi

# Create Version
echo "    -> Pushing Version..."
RAW_PAYLOAD=$(cat <<EOF
{
  "version": "v1",
  "environment": "production",
  "apiKey": "__REF__(//secretmanager.googleapis.com/projects/${PROJECT_NUMBER}/secrets/${SECRET_ID}/versions/latest)",
  "settings": {
    "defaultLocation": "London",
    "units": "metric"
  }
}
EOF
)
B64_PAYLOAD=$(echo -n "$RAW_PAYLOAD" | base64 | tr -d '\n')

curl -s -X POST -H "$AUTH_HEADER" -H "$CONTENT_HEADER" -H "$PROJECT_HEADER" \
  "$API_ENDPOINT/parameters/$PARAM_ID/versions?parameter_version_id=v1" \
  -d "{\"payload\": {\"data\": \"$B64_PAYLOAD\"}}" | jq -r '.name // .error.message'

# 7. VERIFY
echo -e "\n[7/7] üöÄ Verifying..."

# Service Identity for Resolution
SERVICE_AGENT=$($GCLOUD_BIN beta services identity create --service=parametermanager.googleapis.com --project=$PROJECT_ID --format="value(email)")
$GCLOUD_BIN secrets add-iam-policy-binding $SECRET_ID \
    --member="serviceAccount:$SERVICE_AGENT" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None --quiet > /dev/null

# Render
RENDER_RESPONSE=$(curl -s -X GET -H "$AUTH_HEADER" -H "$PROJECT_HEADER" \
  "$API_ENDPOINT/parameters/$PARAM_ID/versions/v1:render")

API_KEY=$(echo "$RENDER_RESPONSE" | jq -r '.renderedPayload | fromjson | .apiKey')

if [[ "$API_KEY" == *"__REF__"* ]] || [[ "$API_KEY" == "null" ]]; then
    echo -e "   üîë API Key:   ‚ùå FAILED"
    echo "      Response: $RENDER_RESPONSE"
else
    echo -e "   üîë API Key:   ‚úÖ $API_KEY" 
fi
echo "========================================================"
