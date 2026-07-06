#!/bin/bash
set -euo pipefail

UPSTREAM_OWNER=Kong
UPSTREAM_REPO=kong
VERSION="${1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

DOCKER_IMAGE_NAME="${UPSTREAM_OWNER}/${UPSTREAM_REPO}-build-env"
DOCKERFILE_PATH="${ROOT_DIR}/Dockerfile.build"

PLATFORM='linux/loong64'

echo "🚀 Starting build process..."
echo "   🏢 Organization: ${UPSTREAM_OWNER}"
echo "   📦 Project:      ${UPSTREAM_REPO}"
echo "   🏷️  Version:      ${VERSION}"
echo "   🐳 Image Name:   ${DOCKER_IMAGE_NAME}"

if [ ! -f "$DOCKERFILE_PATH" ]; then
    echo "❌ Error: Dockerfile.build not found at ${DOCKERFILE_PATH}"
    exit 1
fi

echo "🔨 Building Docker image: ${DOCKER_IMAGE_NAME} ..."
docker build -t "${DOCKER_IMAGE_NAME}" -f "${DOCKERFILE_PATH}" "${ROOT_DIR}"

echo "🏃 Running build inside container..."

docker run --rm \
    --platform "${PLATFORM}" \
    -v "${ROOT_DIR}:/src:z" \
    -w /src \
    -e VERSION="${VERSION}" \
    -e UPSTREAM_OWNER="${UPSTREAM_OWNER}" \
    -e UPSTREAM_REPO="${UPSTREAM_REPO}" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "${DOCKER_IMAGE_NAME}" \
    /bin/bash -c "./scripts/build.sh $VERSION"

echo "✅ Build completed successfully!"
