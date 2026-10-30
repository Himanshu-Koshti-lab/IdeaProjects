#!/usr/bin/env bash
# Builds the backend and frontend Docker images, then optionally exports them as upload-ready
# artifacts and/or pushes them to a registry. Also renders the Kubernetes manifests in k8s/ with
# the exact image references, so the pods run the images that were just built.
#
#   ./build-images.sh                                   # build, tag <version> and latest
#   ./build-images.sh --save                            # + artifacts/*.tar.gz for upload
#   ./build-images.sh --registry ghcr.io/me --push      # + push to a registry
#   ./build-images.sh --version 1.2.0 --platform linux/amd64 --save
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS="$ROOT/artifacts"

VERSION=""
REGISTRY=""
PLATFORM=""
SAVE=false
PUSH=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

  -v, --version <tag>       Image tag (default: git short SHA, with -dirty if there are local changes)
  -r, --registry <prefix>   Registry/namespace to prefix image names with, e.g. ghcr.io/me
  -p, --platform <os/arch>  Target platform, e.g. linux/amd64 (use when your cluster's CPU differs from this machine's)
  -s, --save                Export each image to artifacts/<name>-<version>.tar.gz
      --push                Push both tags to the registry (requires --registry and docker login)
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)  VERSION="$2"; shift 2 ;;
    -r|--registry) REGISTRY="${2%/}"; shift 2 ;;
    -p|--platform) PLATFORM="$2"; shift 2 ;;
    -s|--save)     SAVE=true; shift ;;
    --push)        PUSH=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if $PUSH && [[ -z "$REGISTRY" ]]; then
  echo "--push needs --registry <prefix>" >&2
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  if VERSION="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
    [[ -n "$(git -C "$ROOT" status --porcelain)" ]] && VERSION="$VERSION-dirty"
  else
    VERSION="dev"
  fi
fi

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# name -> build context
declare -A IMAGES=(
  [nomanualcode-backend]="$ROOT/nomanualcode"
  [nomanualcode-frontend]="$ROOT/nomanualcodeui"
)

declare -A REFS=()
for name in nomanualcode-backend nomanualcode-frontend; do
  repo="${REGISTRY:+$REGISTRY/}$name"
  ref="$repo:$VERSION"
  REFS[$name]="$ref"

  log "Building $ref"
  docker build ${PLATFORM:+--platform "$PLATFORM"} \
    --label "org.opencontainers.image.version=$VERSION" \
    --label "org.opencontainers.image.revision=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)" \
    -t "$ref" -t "$repo:latest" \
    "${IMAGES[$name]}"

  if $PUSH; then
    log "Pushing $ref"
    docker push "$ref"
    docker push "$repo:latest"
  fi

  if $SAVE; then
    mkdir -p "$ARTIFACTS"
    file="$ARTIFACTS/$name-$VERSION.tar.gz"
    log "Saving $file"
    docker save "$ref" | gzip > "$file"
  fi
done

# Kubernetes manifests pointing at the images just built.
log "Rendering Kubernetes manifests into artifacts/k8s"
mkdir -p "$ARTIFACTS/k8s"
for manifest in "$ROOT"/k8s/*.yaml; do
  sed -e "s|image: nomanualcode-backend:latest|image: ${REFS[nomanualcode-backend]}|" \
      -e "s|image: nomanualcode-frontend:latest|image: ${REFS[nomanualcode-frontend]}|" \
      "$manifest" > "$ARTIFACTS/k8s/$(basename "$manifest")"
done

echo
log "Done (version $VERSION)"
for name in nomanualcode-backend nomanualcode-frontend; do
  echo "    ${REFS[$name]}"
done
if $SAVE; then
  echo
  echo "Upload artifacts/*.tar.gz, then on the target machine / cluster node:"
  echo "    gunzip -c <file>.tar.gz | docker load        # or: ctr -n k8s.io images import <file>.tar"
fi
echo
echo "Run the pods:"
echo "    kubectl apply -f artifacts/k8s/"
