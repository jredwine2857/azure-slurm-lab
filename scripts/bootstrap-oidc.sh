#!/usr/bin/env bash
# One-time setup: creates the resource group, Entra app registration + service
# principal, OIDC federated credentials, and a Contributor role assignment
# scoped ONLY to rg-slurm-lab (least privilege — this identity can never touch
# anything else in the subscription). Run this once locally after `az login`
# and `gh auth login`. Safe to re-run — each step checks for an existing
# resource before creating one, instead of guessing from a failed create.
set -euo pipefail

# --- Fill these in before running ---
GITHUB_ORG="jredwine2857"
GITHUB_REPO="azure-slurm-lab"
LOCATION="eastus"
RG_NAME="rg-slurm-lab"
APP_NAME="gh-actions-slurm-lab"
# -------------------------------------

echo "Subscription in use:"
az account show --query "{name:name, id:id, tenantId:tenantId}" -o table
read -p "Press enter to continue with this subscription, or Ctrl+C to abort and 'az account set' first... "

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

# GitHub's OIDC subject claim includes the numeric owner/repo IDs (not just
# names) as of their 2025+ immutable-ID format, e.g.
# "repo:owner@123/repo@456:environment:name". Federated credentials must
# match that exactly, so fetch the real IDs instead of hardcoding them.
OWNER_ID=$(gh api "repos/${GITHUB_ORG}/${GITHUB_REPO}" --jq '.owner.id')
REPO_ID=$(gh api "repos/${GITHUB_ORG}/${GITHUB_REPO}" --jq '.id')
SUBJECT_PREFIX="repo:${GITHUB_ORG}@${OWNER_ID}/${GITHUB_REPO}@${REPO_ID}"
echo "OIDC subject prefix resolved to: $SUBJECT_PREFIX"

echo "Creating resource group $RG_NAME in $LOCATION..."
az group create --name "$RG_NAME" --location "$LOCATION" --output none

echo "Creating (or reusing) app registration $APP_NAME..."
APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  echo "Created app $APP_ID"
else
  echo "Reusing existing app $APP_ID"
fi

echo "Ensuring service principal exists for the app..."
az ad sp show --id "$APP_ID" --output none 2>/dev/null || az ad sp create --id "$APP_ID" --output none

create_federated_credential() {
  local cred_name="$1" subject="$2" description="$3"
  local existing
  existing=$(az ad app federated-credential list --id "$APP_ID" --query "[?name=='${cred_name}'].id" -o tsv)
  if [ -n "$existing" ]; then
    echo "Federated credential '$cred_name' already exists, skipping."
    return
  fi
  local tmpfile
  tmpfile=$(mktemp)
  cat > "$tmpfile" <<EOF
{
  "name": "${cred_name}",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "${subject}",
  "description": "${description}",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
  az ad app federated-credential create --id "$APP_ID" --parameters "$tmpfile"
  rm -f "$tmpfile"
}

echo "Creating federated credential for the environment-gated deploy job..."
create_federated_credential \
  "slurm-lab-environment-azure-lab" \
  "${SUBJECT_PREFIX}:environment:azure-lab" \
  "Deploy job gated by the azure-lab GitHub Environment"

echo "Creating federated credential for branch-triggered jobs (smoke-test/destroy)..."
create_federated_credential \
  "slurm-lab-branch-main" \
  "${SUBJECT_PREFIX}:ref:refs/heads/main" \
  "smoke-test/destroy/auto-destroy-stale jobs, not environment-gated"

echo "Assigning Contributor on $RG_NAME only (not the subscription)..."
SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}"
existing_assignment=$(MSYS_NO_PATHCONV=1 az role assignment list --assignee "$APP_ID" --scope "$SCOPE" --query "[?roleDefinitionName=='Contributor'].id" -o tsv)
if [ -n "$existing_assignment" ]; then
  echo "Role assignment already exists, skipping."
else
  MSYS_NO_PATHCONV=1 az role assignment create --assignee "$APP_ID" --role "Contributor" --scope "$SCOPE" --output none
  echo "Created role assignment."
fi

echo
echo "Done. Set these as GitHub repo secrets (gh secret set, or the GitHub UI):"
echo "  AZURE_CLIENT_ID       = $APP_ID"
echo "  AZURE_TENANT_ID       = $TENANT_ID"
echo "  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
echo
echo "Then create a GitHub Environment named 'azure-lab' in the repo's Settings ->"
echo "Environments, and add yourself as a required reviewer."
