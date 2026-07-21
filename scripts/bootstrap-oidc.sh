#!/usr/bin/env bash
# One-time setup: creates the resource group, Entra app registration + service
# principal, OIDC federated credentials, and a Contributor role assignment
# scoped ONLY to rg-slurm-lab (least privilege — this identity can never touch
# anything else in the subscription). Run this once locally after `az login`
# and `gh auth login`. Safe to re-run — each step no-ops if it already exists.
set -euo pipefail

# --- Fill these in before running ---
GITHUB_ORG="<your-github-username-or-org>"
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

echo "Creating federated credential for the environment-gated deploy job..."
cat > /tmp/fed-env.json <<EOF
{
  "name": "slurm-lab-environment-azure-lab",
  "issuer": "https://token.actions.githubusercontent.com/",
  "subject": "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:azure-lab",
  "description": "Deploy job gated by the azure-lab GitHub Environment",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
az ad app federated-credential create --id "$APP_ID" --parameters /tmp/fed-env.json 2>/dev/null \
  || echo "Federated credential for environment:azure-lab already exists, skipping."

echo "Creating federated credential for branch-triggered jobs (verify/destroy)..."
cat > /tmp/fed-branch.json <<EOF
{
  "name": "slurm-lab-branch-main",
  "issuer": "https://token.actions.githubusercontent.com/",
  "subject": "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main",
  "description": "smoke-test/destroy/auto-destroy-stale jobs, not environment-gated",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
az ad app federated-credential create --id "$APP_ID" --parameters /tmp/fed-branch.json 2>/dev/null \
  || echo "Federated credential for ref:refs/heads/main already exists, skipping."

rm -f /tmp/fed-env.json /tmp/fed-branch.json

echo "Assigning Contributor on $RG_NAME only (not the subscription)..."
az role assignment create \
  --assignee "$APP_ID" \
  --role "Contributor" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}" \
  --output none 2>/dev/null || echo "Role assignment already exists, skipping."

echo
echo "Done. Set these as GitHub repo secrets (gh secret set, or the GitHub UI):"
echo "  AZURE_CLIENT_ID       = $APP_ID"
echo "  AZURE_TENANT_ID       = $TENANT_ID"
echo "  AZURE_SUBSCRIPTION_ID = $SUBSCRIPTION_ID"
echo
echo "Then create a GitHub Environment named 'azure-lab' in the repo's Settings ->"
echo "Environments, and add yourself as a required reviewer."
