# Deploying Ansvisor to a small EC2 VM

Images are built on your machine, pushed to Amazon ECR, and pulled by a single
EC2 instance running Docker Compose. The app is reachable only through a
Cloudflare Tunnel at **https://aeo.b0tc0.net**, behind Cloudflare Zero Trust
(Access), so only internal users can open it. The VM never builds anything and
holds no source code. The database and auth are a hosted Supabase project, so
this deployment has no database.

```
internal user ──https──> Cloudflare Access ──tunnel──> cloudflared (host)
                                                        └─> 127.0.0.1:3000  web (Next.js)
                                                                             └─> server:80  server (Express API, workers, node-cron)
```

The instance accepts no inbound traffic. `cloudflared` makes an outbound
connection to Cloudflare. Browsers reach the API through the web app's
`/api/aeo` proxy, and the web container calls it directly as
`http://server:80`. The API's own hostname, **https://aeoapi.b0tc0.net**, is
blocked by Access except for `/cloro/callback`, so Cloro can push tracking
results.

| File | Where it goes |
| --- | --- |
| `build-and-push.sh` | Run locally from the repo |
| `docker-compose.yml`, `deploy.sh` | `/opt/ansvisor/` on the VM |
| `.env.example` → `.env` | `/opt/ansvisor/.env` (`REGISTRY`, `TAG`) |
| `web.env.example` → `web.env` | `/opt/ansvisor/web.env` (web runtime env, secrets) |
| `server.env.example` → `server.env` | `/opt/ansvisor/server.env` (server runtime env, secrets) |
| `vm-setup.sh` | Run once on the VM |
| `web/.env.build.example` → `web/.env.build` | Local only, read at web build time |

> **Run exactly one server.** It runs the daily tracking job in-process with
> node-cron (`DAILY_CRON_SCHEDULE`, default `0 6 * * *` UTC). A second instance
> would duplicate tracking runs and API spend. That includes a copy left
> running locally against the same Supabase project. Don't scale the `server`
> service.

## Environment: build time vs runtime

- **`web/.env.build`** (local, gitignored) holds only `NEXT_PUBLIC_*` values.
  Next.js inlines them into the browser bundle at build time, so changing them
  means rebuilding the web image. The web `.dockerignore` keeps every other
  `.env*` file out of the build context. The Dockerfile copies `.env.build` to
  `.env.production` for `next build`. That file, with public values only, is the
  one env file inside the web image. `build-and-push.sh` refuses to build if
  `.env.build` contains any key that isn't `NEXT_PUBLIC_*`.
- **`web.env` / `server.env`** (on the VM only) hold everything else, including
  all secrets. Compose passes them in with `env_file` when the containers start.
  The `NEXT_PUBLIC_*` values in `web.env` must match `web/.env.build`.
- **`NEXT_PUBLIC_API_URL=http://server:80`** in both web files. The web
  container calls the API server-side. A hostname behind Access would block
  those calls, because they carry no user login.
- **`NEXT_PUBLIC_APP_URL` / `PUBLIC_APP_URL` / `ALLOWED_ORIGINS`** are all
  `https://aeo.b0tc0.net`.
- `SUPABASE_SERVICE_ROLE_KEY` is needed by **both** web and server at runtime.
  Several web routes use a Supabase admin client.

### What the restricted API means

Only `/cloro/callback` is reachable from outside, so these features stay off:

- **AI-bot traffic connections** (Cloudflare Worker, Logpush, Vercel drain to
  `/bots/ingest`) can't be created without `PUBLIC_SERVER_URL`.
- **Content-publish webhook callbacks** (`/webhooks/content*`) can't reach the
  server.
- **The AI-traffic tracking snippet** (`/t.js`, `/track/*`), which visitors
  on a brand's website load.
- **External MCP clients and scripts** calling `https://aeo.b0tc0.net/api/mcp/*`
  are stopped by Access unless you give them an Access service token or a
  bypass policy.

To turn one on, add a Bypass for its path on `aeoapi.b0tc0.net`. For AI-bot
connections, also set `PUBLIC_SERVER_URL=https://aeoapi.b0tc0.net`. The
tracking snippet in Brand Settings shows `http://server:80/t.js`; change it to
`https://aeoapi.b0tc0.net/t.js` when you paste it into a site.

## One-time setup

### 1. Supabase (hosted project `ysolvwhbkizvijqbtkgp`, us-east-2)

1. Apply the schema from the repo root:
   `npx supabase link --project-ref ysolvwhbkizvijqbtkgp && npx supabase db push`
2. **Authentication → URL Configuration**: set the Site URL to
   `https://aeo.b0tc0.net`. Add the redirect URLs
   `https://aeo.b0tc0.net/auth/callback` and `https://aeo.b0tc0.net/auth/confirm`.
   Remove the `localhost` entries once you stop testing locally.
3. **Authentication → SMTP**: configure a real provider (e.g. SES). The built-in
   sender is rate-limited. Users who click email links must also pass Access.
4. Optional: create a public storage bucket named `brand-logos`.
5. Collect the keys from **Project Settings → API Keys**:
   - Project URL: `NEXT_PUBLIC_SUPABASE_URL` (web) and `SUPABASE_URL` (server)
   - Publishable key (`sb_publishable_…`): `NEXT_PUBLIC_SUPABASE_ANON_KEY`
     (web) and `SUPABASE_ANON_KEY` (server)
   - Secret key (`sb_secret_…`): `SUPABASE_SERVICE_ROLE_KEY` in `web.env` and
     `server.env`. Never put it in `web/.env.build`.

### 2. EC2

- Use a t3.small at minimum (t3.medium or t3a.medium recommended), with
  `PLATFORM=linux/amd64`.
- Use Ubuntu 24.04 or Amazon Linux 2023, in **us-east-2**, the same region as
  Supabase.
- No Elastic IP is needed.
- Security group: **no inbound rules**. Outbound is open by default, and
  `cloudflared`, ECR and Supabase all need it. For shell access, use SSM
  Session Manager or SSH through the tunnel.
- IAM instance role: `AmazonEC2ContainerRegistryReadOnly`, plus
  `AmazonSSMManagedInstanceCore` if you use SSM.

### 3. Prepare the VM

Copy `deploy/ec2/vm-setup.sh` to the VM and run `sudo ./vm-setup.sh`. It
installs Docker with the Compose plugin, the AWS CLI and
`amazon-ecr-credential-helper`. It points Docker at the credential helper for
your ECR registry, which it reads from the instance identity document (or set
`REGISTRY=...`). It adds 2 GB of swap if the instance has 4 GB of RAM or less,
and it creates `/opt/ansvisor`. Log out and back in afterwards so the docker
group membership takes effect.

### 4. Cloudflare Tunnel and Access (manual)

1. Zero Trust → Networks → Tunnels: create a tunnel and install `cloudflared`
   on the VM with the command Cloudflare gives you.
2. Add two public hostnames. Cloudflare creates the DNS records.
   - `aeo.b0tc0.net` → `http://localhost:3000`
   - `aeoapi.b0tc0.net` → `http://localhost:8080`
3. Zero Trust → Access → Applications: add these self-hosted apps.
   - `aeo.b0tc0.net`: Allow your Google Workspace users.
   - `aeoapi.b0tc0.net`: Block everyone.
   - `aeoapi.b0tc0.net/cloro/callback`: Bypass, everyone. Access applies the
     more specific path, so this is the only open route.
4. Cloro: in `server.env`, `CLORO_WEBHOOK_URL` is already
   `https://aeoapi.b0tc0.net/cloro/callback`. Turn on signed deliveries at
   dashboard.cloro.dev/webhooks and put the `whsec_…` secret in
   `CLORO_WEBHOOK_SECRET` **at the same time**. Changing only one of the two
   breaks delivery, and without the secret the open path accepts unsigned
   posts.

## Build and push (locally)

```bash
cp web/.env.build.example web/.env.build    # fill in the Supabase URL and publishable key
AWS_ACCOUNT_ID=<ACCOUNT_ID> AWS_REGION=us-east-2 \
  ./deploy/ec2/build-and-push.sh             # PLATFORM defaults to linux/amd64; TAG to the short git SHA
```

The script checks `web/.env.build`. It also builds each context once with
`.dockerignore` applied and confirms no env files leak into it. Then it
creates the `ansvisor-web` and `ansvisor-server` ECR repos if they're missing,
logs in to ECR, runs `docker buildx build --push` for both images, and prints
the image URIs. `PUSH=false` builds into your local Docker instead and makes
no AWS calls.

## First run (on the VM)

Copy `docker-compose.yml`, `deploy.sh` and your filled-in `.env`, `web.env` and
`server.env` to `/opt/ansvisor/`. Then:

```bash
chmod 600 /opt/ansvisor/*.env /opt/ansvisor/.env
cd /opt/ansvisor && ./deploy.sh
```

Then sign up at `https://aeo.b0tc0.net/sign-up`. The first user becomes the
org admin.

## Upgrades

1. Locally: pull upstream, run `npx supabase db push`, then run
   `build-and-push.sh`. Push migrations before deploying new images.
2. On the VM: set `TAG` in `/opt/ansvisor/.env` to the new tag and run `./deploy.sh`.

To roll back, set `TAG` back to the previous tag and run `./deploy.sh` again.
Old images pile up on a small disk, so run `docker image prune -f` now and then.

## Troubleshooting

- `docker compose logs -f server` / `web`
- The app fails with "Couldn't fetch …": check the web logs for
  `[aeo-proxy] upstream unreachable`. `NEXT_PUBLIC_API_URL` must be
  `http://server:80`, in `web/.env.build` (then rebuild) and in `web.env`.
- Tracking runs wait a long time for Cloro: check that
  `https://aeoapi.b0tc0.net/cloro/callback` is bypassed in Access (a `POST`
  from outside should reach the server, not an Access login page). Check the
  server logs for `/cloro/callback` requests too.
- `cloudflared` problems: `journalctl -u cloudflared -f`. The tunnel's status
  also appears in the Zero Trust dashboard.
- An ECR pull is denied: check the instance role, and check that
  `~/.docker/config.json` has a `credHelpers` entry for the registry.
- Sign-in redirects fail: check the Supabase URL configuration (step 1.2).
