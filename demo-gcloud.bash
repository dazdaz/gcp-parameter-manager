#!/bin/bash

# Stop on error
set -e

# --- CONFIGURATION ---
# Use the gcloud found in your path or define specific path
GCLOUD="gcloud"

# Get Project details
PROJECT_ID=$($GCLOUD config get-value project)
PROJECT_NUMBER=$($GCLOUD projects describe $PROJECT_ID --format="value(projectNumber)")
REGION="us-central1"
SECRET_ID="weather-api-key"
PARAM_ID="json-weather-config"

echo "========================================================"
echo "🌤️  GOOGLE CLOUD PARAMETER MANAGER: GCLOUD EDITION"
echo "    Project: $PROJECT_ID"
echo "    Region:  $REGION"
echo "========================================================"

# 1. ENABLE APIS
echo -e "\n[1/7] 🛠️  Enabling APIs..."
$GCLOUD services enable \
    secretmanager.googleapis.com \
    parametermanager.googleapis.com \
    --quiet

# 2. CLEANUP (Ensure fresh start)
echo -e "\n[2/7] 🧹 Cleaning up old resources..."
$GCLOUD beta parameter-manager parameters delete $PARAM_ID --location=$REGION --quiet 2>/dev/null || true
# We don't delete the secret to avoid version history clutter, we just update it below.

# 3. CREATE SECRET
echo -e "\n[3/7] 🔐 Creating/Updating Secret..."
# Create secret if it doesn't exist
if ! $GCLOUD secrets describe $SECRET_ID --quiet >/dev/null 2>&1; then
    $GCLOUD secrets create $SECRET_ID --replication-policy="automatic" --quiet
fi
# Add a new version (the actual key)
printf "my-super-secret-weather-key-123" | $GCLOUD secrets versions add $SECRET_ID --data-file=- --quiet >/dev/null
echo "    -> Secret ready."

# 4. PREPARE PAYLOAD
echo -e "\n[4/7] 📦 Preparing JSON Payload..."
# We use the special __REF__ syntax to point to the 'latest' version of the secret
cat <<EOF > payload.json
{
  "version": "v1",
  "environment": "production",
  "apiKey": "__REF__(//secretmanager.googleapis.com/projects/${PROJECT_NUMBER}/secrets/${SECRET_ID}/versions/latest)",
  "settings": {
    "defaultLocation": "London",
    "units": "metric",
    "retries": 3
  }
}
EOF

# 5. CREATE PARAMETER & VERSION
echo -e "\n[5/7] ☁️  Creating Parameter Resource..."

# A. Create the Parameter (The Container)
$GCLOUD beta parameter-manager parameters create $PARAM_ID \
    --location=$REGION \
    --format="JSON" \
    --quiet

# B. Create the Version (The Data)
echo "    -> Pushing Version v1..."
$GCLOUD beta parameter-manager versions create $PARAM_ID \
    --location=$REGION \
    --version-id="v1" \
    --payload-file="payload.json" \
    --quiet

# 6. IAM PERMISSIONS (Crucial Step)
echo -e "\n[6/7] 👮 Granting Permissions to Service Agent..."
# We need the email of the Google-managed robot that acts on behalf of Parameter Manager
SERVICE_AGENT=$($GCLOUD beta services identity create --service=parametermanager.googleapis.com --project=$PROJECT_ID --format="value(email)")

echo "    -> Identity: $SERVICE_AGENT"
echo "    -> Granting 'Secret Accessor' role..."
$GCLOUD secrets add-iam-policy-binding $SECRET_ID \
    --member="serviceAccount:$SERVICE_AGENT" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None --quiet > /dev/null

# 7. VERIFY (Render)
echo -e "\n[7/7] 🚀 Verifying configuration..."
echo "    -> Fetching and Rendering..."

# We use --format="value(renderedPayload)" to get just the JSON string back
RENDERED_JSON=$($GCLOUD beta parameter-manager versions render $PARAM_ID \
    --location=$REGION \
    --version-id="v1" \
    --format="value(renderedPayload)")

# Parse the result with jq
API_KEY=$(echo "$RENDERED_JSON" | jq -r '.apiKey')
ENV=$(echo "$RENDERED_JSON" | jq -r '.environment')

echo -e "\n📊 RESULTS:"
echo "   Environment: $ENV"

if [[ "$API_KEY" == *"__REF__"* ]]; then
    echo -e "   🔑 API Key:   ❌ FAILED (Still shows reference string)"
    echo "      (IAM propagation might need a few more seconds. Run the render command again.)"
else
    echo -e "   🔑 API Key:   ✅ $API_KEY" 
fi

# Cleanup local file
rm payload.json

echo "========================================================"
