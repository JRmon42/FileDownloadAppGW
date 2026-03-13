#!/usr/bin/env bash
# Deploy the DLP Evidence download troubleshooting infrastructure
# Prerequisites: Azure CLI logged in (az login)

set -euo pipefail

RESOURCE_GROUP="rg-dlpevidence-test"
LOCATION="francecentral"
TEMPLATE_FILE="$(dirname "$0")/main.bicep"
PARAMS_FILE="$(dirname "$0")/main.bicepparam"

echo "=== DLP Evidence Infrastructure Deployment ==="

# 1. Login check
if ! az account show &>/dev/null; then
  echo "Not logged in — running az login..."
  az login
fi

echo "Subscription: $(az account show --query '[name,id]' -o tsv)"

# 2. Create resource group
echo ""
echo "Creating resource group: $RESOURCE_GROUP in $LOCATION..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output table

# 3. Validate the Bicep template
echo ""
echo "Validating Bicep template..."
az deployment group validate \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_FILE" \
  --parameters "$PARAMS_FILE"
echo "Validation passed."

# 4. Deploy
echo ""
echo "Deploying infrastructure (this takes ~10-15 min for the App Gateway)..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$TEMPLATE_FILE" \
  --parameters "$PARAMS_FILE" \
  --name "dlpevidence-$(date +%Y%m%d%H%M%S)" \
  --output table

# 5. Show outputs
echo ""
echo "=== Deployment Outputs ==="
az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$(az deployment group list -g "$RESOURCE_GROUP" --query '[0].name' -o tsv)" \
  --query 'properties.outputs' \
  --output yaml

# 6. Generate a short-lived SAS URL for prisma.txt to test the download
echo ""
# Retrieve deployment outputs
DEPLOY_NAME=$(az deployment group list \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].name' -o tsv)

STORAGE_ACCOUNT=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOY_NAME" \
  --query 'properties.outputs.storageAccountName.value' \
  -o tsv)

APPGW_FQDN=$(az deployment group show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOY_NAME" \
  --query 'properties.outputs.appGatewayFqdn.value' \
  -o tsv)

CONTAINER="prisma-access"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}"

# Get the signed-in user's object ID
USER_OID=$(az ad signed-in-user show --query id -o tsv)

echo ""
echo "=== Granting data-plane roles to signed-in user ==="
# Storage Blob Data Contributor — required to upload the blob
az role assignment create \
  --assignee-object-id "$USER_OID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$SCOPE" \
  --output none 2>/dev/null || echo "  Storage Blob Data Contributor already assigned"

# Storage Blob Delegator — required to sign a user-delegation SAS without account keys
az role assignment create \
  --assignee-object-id "$USER_OID" \
  --assignee-principal-type User \
  --role "Storage Blob Delegator" \
  --scope "$SCOPE" \
  --output none 2>/dev/null || echo "  Storage Blob Delegator already assigned"

echo "  Waiting 30s for RBAC propagation..."
sleep 30

echo ""
echo "=== Uploading prisma.txt to blob storage ==="
# Key-based auth is disabled on the subscription — use Entra ID (login) auth throughout
echo "Prisma Downloaded" > /tmp/prisma.txt
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "prisma.txt" \
  --file /tmp/prisma.txt \
  --auth-mode login \
  --overwrite \
  --output none
echo "  Upload complete."

echo ""
echo "=== Generating user-delegation SAS URL for prisma.txt ==="
# User-delegation SAS: signed with the user's Entra ID delegated key (not account key).
# The resulting URL is fully self-contained — paste it in Edge and it downloads directly.
# --https-only intentionally NOT set so the URL also works via App Gateway HTTP frontend.
EXPIRY=$(date -u -d '+24 hours' '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
  || date -u -v+24H '+%Y-%m-%dT%H:%MZ')  # macOS fallback

SAS_TOKEN=$(az storage blob generate-sas \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "prisma.txt" \
  --permissions r \
  --expiry "$EXPIRY" \
  --auth-mode login \
  --as-user \
  --output tsv)

DIRECT_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/prisma.txt?${SAS_TOKEN}"
APPGW_URL="http://${APPGW_FQDN}/${CONTAINER}/prisma.txt?${SAS_TOKEN}"

echo ""
echo "---------------------------------------------------------------------"
echo "1) Direct HTTPS URL (baseline — confirm the file is readable):"
echo ""
echo "   $DIRECT_URL"
echo ""
echo "---------------------------------------------------------------------"
echo "2) Via App Gateway URL (replicates the DLP redirect — open in Edge):"
echo ""
echo "   $APPGW_URL"
echo ""
echo "---------------------------------------------------------------------"
echo "Both URLs are valid for 24 hours. Paste either into Edge to download."
echo ""
echo "Quick curl tests:"
echo "  curl -v '$DIRECT_URL'"
echo "  curl -v '$APPGW_URL'"
