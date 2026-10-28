#!/usr/bin/env bash
# =============================================================================
# Agent Observability & Security — Complete Lab Solution Script
# =============================================================================
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
export PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
export LOCATION="${LOCATION:-us-central1}"
export PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
export ORGANIZATION_ID="$(gcloud projects get-ancestors "${PROJECT_ID}" --format=json | jq -r '.[] | select(.type=="organization") | .id')"

echo "Project: ${PROJECT_ID} (${PROJECT_NUMBER}), Org: ${ORGANIZATION_ID}, Location: ${LOCATION}"

# -----------------------------------------------------------------------------
# Task 1: Enable Observability and Discovery APIs
# -----------------------------------------------------------------------------
gcloud services enable \
  observability.googleapis.com \
  cloudtrace.googleapis.com \
  telemetry.googleapis.com \
  apphub.googleapis.com \
  apptopology.googleapis.com \
  agentregistry.googleapis.com \
  cloudasset.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  --project="${PROJECT_ID}"

# -----------------------------------------------------------------------------
# Task 2: Grant Cloud Telemetry Traces Writer role & generate traces
# -----------------------------------------------------------------------------
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/telemetry.tracesWriter"

GITHUB_RESOURCE="$(curl -s \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://${LOCATION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/reasoningEngines" \
  | jq -r '(.reasoningEngines // [])[] | select(.displayName=="github_agent" or .displayName=="github-agent") | .name')"
export GITHUB_AGENT_URL="https://${LOCATION}-aiplatform.googleapis.com/v1/${GITHUB_RESOURCE}"

agents-cli run --url "${GITHUB_AGENT_URL}" --mode adk --app-name app "Find the google/adk-python repository"

# -----------------------------------------------------------------------------
# Task 3: Confirm Agent Runtime discovery in Agent Registry & App Hub
# -----------------------------------------------------------------------------
gcloud alpha agent-registry agents list --location="${LOCATION}" --project="${PROJECT_ID}"

curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://apphub.googleapis.com/v1/projects/${PROJECT_ID}/locations/${LOCATION}/discoveredWorkloads" \
  | jq -r '(.discoveredWorkloads // [])[] | "\(.name)\t\(.workloadReference.uri)"'

# -----------------------------------------------------------------------------
# Task 4: Register Cloud Run agent (salesforce-agent) in Agent Registry
# -----------------------------------------------------------------------------
gcloud beta services identity create --service=discoveryengine.googleapis.com --project="${PROJECT_ID}" || true

gcloud run services add-iam-policy-binding salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com" \
  --role="roles/run.invoker"

SF_URL="$(gcloud run services describe salesforce-agent \
  --region="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")"

curl -s -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  "${SF_URL}/a2a/app/.well-known/agent-card.json" | jq . > salesforce_card.json

gcloud alpha agent-registry services create salesforce-agent \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --agent-spec-type=a2a-agent-card \
  --agent-spec-content="$(cat salesforce_card.json)"

# -----------------------------------------------------------------------------
# Task 5: Register GitHub MCP server in Agent Registry
# -----------------------------------------------------------------------------
gcloud alpha agent-registry services create github-mcp \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}" \
  --display-name="GitHub MCP server" \
  --description="External GitHub Copilot MCP server used by github_agent" \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=https://api.githubcopilot.com/mcp/,protocolBinding=JSONRPC"

gcloud alpha agent-registry mcp-servers list --location="${LOCATION}" --project="${PROJECT_ID}"

# -----------------------------------------------------------------------------
# Tasks 7-9: Verify narrow roles & remove roles/editor from compute SA
# -----------------------------------------------------------------------------
for ROLE in roles/aiplatform.user roles/telemetry.tracesWriter roles/logging.logWriter roles/cloudtrace.agent; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
    --role="${ROLE}" >/dev/null
done

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --role="roles/editor"

gcloud projects get-iam-policy "${PROJECT_ID}" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com" \
  --format="table(bindings.role)"
