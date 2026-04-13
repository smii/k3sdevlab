#!/bin/bash

# --- Configuration ---
TARGET_REGISTRY="registry.rtm.local"

# Corrected field selector syntax: apply the != operator to each namespace
EXCLUDE_SELECTOR="metadata.namespace!=kube-system,metadata.namespace!=kube-public,metadata.namespace!=kube-node-lease"

echo "Discovering unique container images running in all namespaces (excluding system namespaces)..."

# 1. Discover all unique running images using the corrected field selector
IMAGES=$(kubectl get pods --all-namespaces \
    --field-selector="${EXCLUDE_SELECTOR}" \
    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u)

if [ -z "$IMAGES" ]; then
    echo "No user-deployed images found to process. Exiting."
    exit 0
fi

echo "Found the following unique images to process:"
echo "$IMAGES"
echo "--------------------------------------------"

# 2. Loop through each unique image, pull, retag, and push
for SOURCE_IMAGE in $IMAGES; do
    # Extract the image name and tag (e.g., "argocd:v2.9.3")
    IMAGE_NAME_TAG=$(basename "$SOURCE_IMAGE")

    # Construct the new target image path
    TARGET_IMAGE="${TARGET_REGISTRY}/${IMAGE_NAME_TAG}"

    echo "Processing: ${SOURCE_IMAGE}"
    echo "  -> Targeting: ${TARGET_IMAGE}"

    # 3. Pull the source image
    if docker pull "$SOURCE_IMAGE"; then
        echo "  ✔️ Pull successful."

        # 4. Retag the image
        if docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"; then
            echo "  ✔️ Tag successful."

            # 5. Push the retagged image
            if docker push "$TARGET_IMAGE"; then
                echo "  🎉 Push to ${TARGET_REGISTRY} successful."
            else
                echo "  ❌ ERROR: Push failed for ${TARGET_IMAGE}. Check your login status."
            fi

        else
            echo "  ❌ ERROR: Tag failed for ${SOURCE_IMAGE}."
        fi

        # Optional cleanup: Remove the downloaded images after push to save space
        # docker rmi "$SOURCE_IMAGE" "$TARGET_IMAGE" 2>/dev/null
    else
        echo "  ❌ ERROR: Pull failed for ${SOURCE_IMAGE}. It may require authentication or be unavailable."
    fi

    echo "--------------------------------------------"
done

echo "Script complete."
