#!/usr/bin/env bash
# One-time setup of a fresh Ubuntu 24.04 or Amazon Linux 2023 EC2 VM:
# Docker + Compose plugin, AWS CLI, amazon-ecr-credential-helper, Docker
# credential helper config for ECR, 2 GB swap on small instances, and
# /opt/ansvisor. Ingress is a Cloudflare Tunnel (cloudflared) installed
# separately; see README.md.
#
# Run as root (sudo ./vm-setup.sh). The ECR registry is read from REGISTRY
# if set, otherwise derived from the instance identity document.
set -euo pipefail

[[ $EUID -eq 0 ]] || {
  echo "run as root: sudo $0" >&2
  exit 1
}

# shellcheck disable=SC1091
. /etc/os-release
ARCH="$(uname -m)" # x86_64 | aarch64 (images must match PLATFORM)
case "$ARCH" in
  x86_64 | aarch64) ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

install_ubuntu() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl unzip

  # Docker Engine + Compose plugin (Docker's apt repo)
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
    amazon-ecr-credential-helper

  # AWS CLI v2 (official installer)
  if ! command -v aws >/dev/null; then
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o "$tmp/awscliv2.zip"
    unzip -q "$tmp/awscliv2.zip" -d "$tmp"
    "$tmp/aws/install"
    rm -rf "$tmp"
  fi
}

install_al2023() {
  dnf install -y docker amazon-ecr-credential-helper awscli-2

  # Compose plugin isn't packaged for AL2023: install the release binary.
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${ARCH}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

}

case "$ID" in
  ubuntu) install_ubuntu ;;
  amzn) install_al2023 ;;
  *)
    echo "unsupported OS: $ID (expected ubuntu or amzn)" >&2
    exit 1
    ;;
esac

systemctl enable --now docker

# --- ECR credential helper ---------------------------------------------------
# The instance role (AmazonEC2ContainerRegistryReadOnly) supplies credentials;
# docker-credential-ecr-login exchanges them for registry tokens on each pull.
if [[ -z "${REGISTRY:-}" ]]; then
  imds_token="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  identity="$(curl -fsS -H "X-aws-ec2-metadata-token: $imds_token" \
    http://169.254.169.254/latest/dynamic/instance-identity/document)"
  account_id="$(sed -n 's/.*"accountId" *: *"\([0-9]*\)".*/\1/p' <<<"$identity")"
  region="$(sed -n 's/.*"region" *: *"\([a-z0-9-]*\)".*/\1/p' <<<"$identity")"
  REGISTRY="${account_id}.dkr.ecr.${region}.amazonaws.com"
fi
echo "configuring Docker credential helper for $REGISTRY"

write_docker_config() {
  local home="$1" owner="$2"
  mkdir -p "$home/.docker"
  cat >"$home/.docker/config.json" <<JSON
{
  "credHelpers": {
    "${REGISTRY}": "ecr-login"
  }
}
JSON
  chown -R "$owner" "$home/.docker"
}
write_docker_config /root root:root

# Also for the login user (ubuntu / ec2-user), who gets docker group access.
login_user="${SUDO_USER:-}"
if [[ -n "$login_user" && "$login_user" != root ]]; then
  usermod -aG docker "$login_user"
  write_docker_config "$(getent passwd "$login_user" | cut -d: -f6)" "$login_user:$login_user"
fi

# --- Swap on small instances (<= 4 GB RAM) -----------------------------------
mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
if ((mem_kb <= 4 * 1024 * 1024)) && ! swapon --show=NAME --noheadings | grep -q .; then
  echo "creating 2 GB swap file"
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# --- App directory -----------------------------------------------------------
mkdir -p /opt/ansvisor
if [[ -n "$login_user" && "$login_user" != root ]]; then
  chown "$login_user:$login_user" /opt/ansvisor
fi

echo
echo "Done. Versions:"
docker --version
docker compose version
aws --version
docker-credential-ecr-login version 2>/dev/null || true
echo
echo "Log out and back in for docker group membership to apply."
