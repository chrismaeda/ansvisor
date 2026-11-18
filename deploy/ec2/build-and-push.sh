#!/usr/bin/env bash
# Build the web and server images locally and push them to Amazon ECR.
#
# Env:
#   AWS_ACCOUNT_ID  (required unless PUSH=false)
#   AWS_REGION      (required unless PUSH=false)
#   PLATFORM        default linux/amd64 (t3); linux/arm64 for t4g/Graviton
#   TAG             default: short git SHA
#   PUSH            default true; false builds into the local Docker image
#                   store (no AWS calls) as ansvisor-<svc>:$TAG
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PLATFORM="${PLATFORM:-linux/amd64}"
TAG="${TAG:-$(git rev-parse --short HEAD)}"
PUSH="${PUSH:-true}"
SERVICES=(web server)

die() {
  echo "error: $*" >&2
  exit 1
}

# --- Sanity checks (before anything touches AWS) -----------------------------

[[ -f web/.env.build ]] ||
  die "web/.env.build is missing. Copy web/.env.build.example and fill in the public values."

# .env.build is inlined into the browser bundle: only NEXT_PUBLIC_* allowed.
bad_keys="$(grep -vE '^[[:space:]]*(#|$)' web/.env.build | grep -vE '^NEXT_PUBLIC_[A-Z0-9_]+=' || true)"
[[ -z "$bad_keys" ]] ||
  die "web/.env.build may only contain NEXT_PUBLIC_* keys. Offending lines:
$bad_keys"

for key in NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY NEXT_PUBLIC_API_URL NEXT_PUBLIC_APP_URL; do
  grep -qE "^${key}=.+" web/.env.build || die "web/.env.build: $key is empty"
done

# Materialize each build context exactly as Docker sees it (.dockerignore
# applied) and make sure no env file other than web/.env.build is in it.
check_context() {
  local svc="$1" allowed="$2" ctx leaked
  ctx="$(mktemp -d)"
  printf 'FROM scratch\nCOPY . /\n' |
    docker buildx build --quiet --output "type=local,dest=$ctx" -f - "./$svc" >/dev/null
  leaked="$(cd "$ctx" && find . -name '.env*' ! -path "./$allowed" | sort)"
  rm -rf "$ctx"
  [[ -z "$leaked" ]] ||
    die "$svc/.dockerignore lets env files into the build context:
$leaked"
}
check_context server ""
check_context web ".env.build"
echo "build contexts OK: no env files besides web/.env.build"

# --- ECR ---------------------------------------------------------------------

if [[ "$PUSH" == "true" ]]; then
  : "${AWS_ACCOUNT_ID:?set AWS_ACCOUNT_ID}"
  : "${AWS_REGION:?set AWS_REGION}"
  REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

  for svc in "${SERVICES[@]}"; do
    repo="ansvisor-$svc"
    if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$repo" >/dev/null 2>&1; then
      echo "creating ECR repository $repo"
      aws ecr create-repository --region "$AWS_REGION" --repository-name "$repo" \
        --image-scanning-configuration scanOnPush=true >/dev/null
    fi
  done

  aws ecr get-login-password --region "$AWS_REGION" |
    docker login --username AWS --password-stdin "$REGISTRY"
  output_flag=--push
else
  REGISTRY=""
  output_flag=--load
fi

# --- Build -------------------------------------------------------------------

images=()
for svc in "${SERVICES[@]}"; do
  image="${REGISTRY:+$REGISTRY/}ansvisor-$svc:$TAG"
  echo "building $image ($PLATFORM)"
  docker buildx build \
    --platform "$PLATFORM" \
    --build-arg "VERSION=$TAG" \
    -t "$image" \
    "$output_flag" \
    "./$svc"
  images+=("$image")
done

echo
echo "Images:"
printf '  %s\n' "${images[@]}"
if [[ "$PUSH" == "true" ]]; then
  echo
  echo "On the VM, set in /opt/ansvisor/.env:"
  echo "  REGISTRY=$REGISTRY"
  echo "  TAG=$TAG"
fi
