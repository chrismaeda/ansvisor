# Task: Prepare Ansvisor for deployment to a small EC2 VM (images built locally, pushed to ECR)

You are working in a local clone of https://github.com/ansvisor/ansvisor (main branch).
Ansvisor has two services: `web` (Next.js 16, port 3000) and `server` (Express API +
workers + in-process node-cron, port 80). The database and auth are a **hosted Supabase
project** that already exists. Do not add a database to the deployment.

Goal: build both Docker images on my machine, push them to Amazon ECR, and run them on a
small EC2 instance (t3.small/t3.medium) with Docker Compose and Caddy for HTTPS. The VM
must not build anything and must not hold source code.

## Placeholders (ask me for these before running anything that needs them)

- `<ACCOUNT_ID>` / `<REGION>`: AWS account and region (ECR registry: `<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com`)
- `<TAG>`: image tag (default: the short git SHA)
- `<PLATFORM>`: `linux/amd64` for t3 instances, `linux/arm64` for t4g/Graviton
- `app.example.com` / `api.example.com`: the web and API hostnames
- `<SUPABASE_PROJECT_REF>`

## Known issues to fix in the repo

1. **Web build fails as shipped.** `web/Dockerfile` copies `.next/standalone`, but
   `web/next.config.ts` doesn't set `output: 'standalone'`. Add `output: 'standalone'`
   to the `nextConfig` object. Change nothing else in that file.
2. **Secrets leak into images.** Neither `web/` nor `server/` has a `.dockerignore`, and
   both Dockerfiles run `COPY . .`, so any `.env` file gets copied into the image.
   - Create `server/.dockerignore` excluding `.env*` (keep `.env.example` excluded too),
     `node_modules`, `.git`, logs.
   - Create `web/.dockerignore` excluding `node_modules`, `.next`, `.git`, `.env.local`,
     `.env*.local`, and every `.env*` file EXCEPT a build-only file named `.env.build`
     (see below).
3. **Build-time vs runtime env for web.** All `NEXT_PUBLIC_*` values are inlined into the
   browser bundle at build time. Set up the web build so it reads ONLY public values:
   - Create `web/.env.build.example` containing just: `NEXT_PUBLIC_SUPABASE_URL`,
     `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_API_URL=https://api.example.com`,
     `NEXT_PUBLIC_APP_URL=https://app.example.com`, `NEXT_PUBLIC_IS_CLOUD=false`, plus the
     other optional `NEXT_PUBLIC_*` keys from `web/.env.example` left blank.
   - In the build script, copy `web/.env.build` to `web/.env.production` inside the build
     context only for the build (or pass the values as Docker build args via an `ARG`/`ENV`
     block in the `builder` stage, whichever is cleaner). Make sure no non-public secret
     ends up in any image layer. Add `web/.env.build` and `web/.env.production` to
     `.gitignore`.
   - Server-side web secrets (AI provider keys, etc.) are supplied at runtime via `env_file`.

## Files to create (put deployment files under `deploy/ec2/`)

1. `deploy/ec2/build-and-push.sh`
   - Inputs via env vars: `AWS_ACCOUNT_ID`, `AWS_REGION`, `PLATFORM` (default
     `linux/amd64`), `TAG` (default `git rev-parse --short HEAD`).
   - Creates the ECR repos `ansvisor-web` and `ansvisor-server` if missing.
   - Logs in with `aws ecr get-login-password`.
   - Fails early if `web/.env.build` is missing, or if `server/.env` would be included in
     the build context (sanity-check the `.dockerignore`).
   - `docker buildx build --platform $PLATFORM -t <registry>/ansvisor-<svc>:$TAG --push ./<svc>`
     for both services.
   - Prints the final image URIs.
   - Use `set -euo pipefail`.
2. `deploy/ec2/docker-compose.yml` (for the VM, no `build:` keys):
   - `web`: image `${REGISTRY}/ansvisor-web:${TAG}`, ports `127.0.0.1:3000:3000`,
     `env_file: ./web.env`, `restart: unless-stopped`.
   - `server`: image `${REGISTRY}/ansvisor-server:${TAG}`, ports `127.0.0.1:8080:80`,
     `env_file: ./server.env`, `restart: unless-stopped`.
   - `caddy`: optional third service is NOT wanted; Caddy runs on the host.
   - `REGISTRY` and `TAG` come from a `deploy/ec2/.env` file (create `.env.example`).
3. `deploy/ec2/Caddyfile`
   ```
   app.example.com {
     reverse_proxy 127.0.0.1:3000
   }
   api.example.com {
     reverse_proxy 127.0.0.1:8080
   }
   ```
4. `deploy/ec2/web.env.example` and `deploy/ec2/server.env.example`: runtime env
   templates derived from `web/.env.example` and `server/.env.example`, with production
   values pre-filled where known:
   - server: `NODE_ENV=production`, `PORT=80`, `IS_CLOUD=false`,
     `ALLOWED_ORIGINS=https://app.example.com`,
     `CLORO_WEBHOOK_URL=https://api.example.com/cloro/callback`,
     `PUBLIC_SERVER_URL=https://api.example.com`, `PUBLIC_APP_URL=https://app.example.com`.
   - web: the same `NEXT_PUBLIC_*` values as the build file plus the server-side keys.
5. `deploy/ec2/vm-setup.sh` (run once on a fresh Ubuntu 24.04 or Amazon Linux 2023 VM):
   installs Docker + the Compose plugin, Caddy, the AWS CLI and `amazon-ecr-credential-helper`;
   configures Docker to use the credential helper for the ECR registry; creates a 2 GB swap
   file if the instance has 4 GB RAM or less; creates `/opt/ansvisor`.
6. `deploy/ec2/deploy.sh` (run on the VM from `/opt/ansvisor`): `docker compose pull &&
   docker compose up -d`, then prints `docker compose ps` and tails the last 50 server log
   lines.
7. `deploy/ec2/README.md`: a short runbook covering everything below, including the
   manual steps.

## Manual steps for the README (things I do myself, not you)

- **Supabase** (hosted project in the same AWS region as the VM):
  - Apply the schema: `npx supabase link --project-ref <SUPABASE_PROJECT_REF> && npx supabase db push`.
  - Authentication → URL Configuration: Site URL `https://app.example.com`; Redirect URLs
    `https://app.example.com/auth/callback` and `https://app.example.com/auth/confirm`.
  - Authentication → SMTP: configure a real provider (e.g. SES); the built-in sender is
    rate-limited.
  - Optional: public storage bucket `brand-logos`.
  - Keys: Project URL, anon key (web + server), service_role key (server only).
- **EC2**:
  - t3.small minimum, t3.medium recommended (t4g if `PLATFORM=linux/arm64`).
  - Elastic IP.
  - Security group: 80/443 from anywhere, 22 from my IP only.
  - IAM instance role with `AmazonEC2ContainerRegistryReadOnly`.
- **DNS**: A records for both hostnames pointing to the Elastic IP.
- **First run**: copy `docker-compose.yml`, `.env`, `web.env`, `server.env` to
  `/opt/ansvisor`; copy the `Caddyfile` to `/etc/caddy/Caddyfile` and reload Caddy; run
  `deploy.sh`; sign up at `https://app.example.com/sign-up` (the first user becomes org admin).
- **Upgrades**:
  - Locally: pull upstream, `npx supabase db push`, run `build-and-push.sh`.
  - On the VM: bump `TAG` in `.env`, run `deploy.sh`.

## Constraints

- **Server stays at exactly one instance.** It runs the daily tracking job via node-cron
  (default 06:00 UTC, `DAILY_CRON_SCHEDULE`); a second instance would duplicate tracking
  runs and API spend.
- Don't modify application code beyond the `next.config.ts` change.
- Don't commit any real `.env`, `.env.build`, `web.env` or `server.env` file.
- Don't run `aws`, `docker push`, or anything that touches AWS or Supabase without asking
  me first.

## Verification (do these before reporting done)

1. Build both images locally for my host platform (no push). Confirm the web build
   succeeds with the standalone fix.
2. Inspect both images and confirm no secrets are inside:
   - `docker run --rm --entrypoint sh <img> -c 'ls -la; find / -name ".env*" -not -path "/proc/*" 2>/dev/null'`
   - Only `.env.production` with public values may appear in web; nothing in server.
3. Run the images locally with `deploy/ec2/docker-compose.yml` (using local image names
   and my real env files if I've provided them) and confirm:
   - `curl -I http://127.0.0.1:3000` returns a response;
   - the server container stays up for 60s without crashing.
4. Run `shellcheck` on the scripts if it's available.
5. Summarize what changed, list any assumptions, and list the manual steps I still need to do.
