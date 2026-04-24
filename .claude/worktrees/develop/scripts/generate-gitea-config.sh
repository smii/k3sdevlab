#!/usr/bin/env bash

# Script to generate gitea-values.yaml from template and .env file
# Usage: ./generate-gitea-config.sh [env_file]

set -euo pipefail

ENV_FILE="${1:-.env_test}"
TEMPLATE_FILE="charts/gitea/gitea-values.yaml.template"
OUTPUT_FILE="charts/gitea/gitea-values.yaml"

echo "🔧 Generating gitea configuration..."
echo "   Environment file: ${ENV_FILE}"
echo "   Template file: ${TEMPLATE_FILE}"
echo "   Output file: ${OUTPUT_FILE}"

# Load environment variables
if [[ -f "$ENV_FILE" ]]; then
    echo "📥 Loading environment variables from ${ENV_FILE}..."
    set -a  # Export all variables
    source "$ENV_FILE"
    set +a  # Stop exporting
else
    echo "❌ Error: Environment file '${ENV_FILE}' not found."
    exit 1
fi

# Check if template exists
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "❌ Error: Template file '${TEMPLATE_FILE}' not found."
    exit 1
fi

# Create backup of existing file
if [[ -f "$OUTPUT_FILE" ]]; then
    echo "💾 Creating backup of existing configuration..."
    cp "$OUTPUT_FILE" "${OUTPUT_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
fi

# Generate configuration using envsubst
echo "🔄 Substituting environment variables..."
envsubst < "$TEMPLATE_FILE" > "$OUTPUT_FILE"

echo "✅ Gitea configuration generated successfully!"
echo "   Generated: ${OUTPUT_FILE}"
echo "   Backup created (if existed): ${OUTPUT_FILE}.backup.*"

# Show what changed
if command -v diff >/dev/null 2>&1 && [[ -f "${OUTPUT_FILE}.backup.*" ]]; then
    echo ""
    echo "📋 Configuration changes:"
    diff "${OUTPUT_FILE}.backup.*" "$OUTPUT_FILE" || true
fi

echo ""
echo "🚀 Next steps:"
echo "   1. Review the generated configuration: cat ${OUTPUT_FILE}"
echo "   2. Commit changes: git add ${OUTPUT_FILE} && git commit -m 'feat: update gitea config from template'"
echo "   3. Sync ArgoCD: argocd app sync gitea --grpc-web"