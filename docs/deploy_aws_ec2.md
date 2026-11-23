# Deploying on AWS EC2

The whole stack (Postgres + pgvector, Langfuse, the API with the review agent and the Ask the Copilot chat, the Streamlit
UI) runs on one EC2 instance with Docker Compose, started by `make up-ec2`. The overlay `docker/docker-compose.ec2.yml`
keeps Postgres, the API and Langfuse on the instance's loopback interface, so only SSH (and, if you choose, the UI for
named IP addresses) faces the internet. Commands marked **laptop** run in PowerShell in the project folder; **EC2** runs
in the SSH session on the instance.

## 0. Before you start (laptop)

1. The repository must contain `Makefile` (with the `*-ec2` targets) and `docker/docker-compose.ec2.yml`. Commit and push:
   ```powershell
   git add Makefile docker/docker-compose.ec2.yml docs/deploy_aws_ec2.md
   git commit -m "Deploy on AWS EC2"
   git push
   ```
2. Check that `git status` does not list `.env`, `certs/` or `data/`: they must never be pushed (step 5 copies them).
3. The model, the embeddings and the chat answers come from the course endpoints. If those only accept connections from
   certain networks, an AWS instance cannot reach them; step 6 tests this before anything is built.

## 1. Launch the instance (AWS console, EC2 → Launch instance)

| Setting | Value |
|---|---|
| Name | `pvrc` |
| Region | Asia Pacific (Mumbai) ap-south-1, or the one nearest the team |
| AMI | Ubuntu Server 24.04 LTS, 64-bit (x86) |
| Instance type | t3.large (2 vCPU, 8 GB). t3.medium (4 GB) runs it but is tight with two Postgres servers and Langfuse |
| Key pair | Create new: `pvrc-key`, RSA, .pem. Save the file in the project folder's parent, never inside the repo |
| Network | default VPC, public subnet, auto-assign public IP: enabled |
| Security group, inbound | SSH (TCP 22) from **My IP** only. Nothing else (step 10 optionally adds the UI for named IPs) |
| Storage | 30 GiB gp3 |

Launch, wait for "Running" and "2/2 checks passed", and note the **Public IPv4 address**. Optional: Elastic IPs →
Allocate → Associate with the instance, so the address survives a stop and start.

## 2. Connect (laptop)

```powershell
icacls .\pvrc-key.pem /inheritance:r /grant:r "$($env:USERNAME):R"     # ssh refuses a key others can read
ssh -i .\pvrc-key.pem ubuntu@<public-ip>
```
Type `yes` to the fingerprint question the first time.

## 3. Install Docker, Compose, make and git (EC2)

```bash
sudo apt-get update && sudo apt-get install -y make git
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu && newgrp docker
docker compose version        # must be 2.24 or newer (the overlay uses !override)
docker run --rm hello-world   # Docker works without sudo
```

## 4. Get the code (EC2)

```bash
git clone https://github.com/<you>/<repo>.git pvrc && cd pvrc
```
For a private repository: when git asks for a password, paste a fine-grained personal access token (GitHub → Settings →
Developer settings → Fine-grained tokens, read access to this one repository's Contents). Check the branch if your work
is not on the default one: `git switch <branch>`.

## 5. Copy what git does not hold (laptop), then set up `.env` (EC2)

`.env`, `certs/` and `data/processed/` are git-ignored: secrets, and generated data of about 220 MB.

**Laptop:**
```powershell
scp -i ..\pvrc-key.pem .env ubuntu@<public-ip>:~/pvrc/.env
scp -i ..\pvrc-key.pem -r certs ubuntu@<public-ip>:~/pvrc/
ssh -i ..\pvrc-key.pem ubuntu@<public-ip> "mkdir -p ~/pvrc/data/processed"
scp -i ..\pvrc-key.pem data\processed\corpus_v1.jsonl data\processed\store.sqlite ubuntu@<public-ip>:~/pvrc/data/processed/
scp -i ..\pvrc-key.pem -r data\processed\embeddings ubuntu@<public-ip>:~/pvrc/data/processed/
```
If the chat uses any other generated file that git ignores (an index or cache under `data/`), copy it the same way.

**EC2:** lock the secrets down, then make three random values:
```bash
cd ~/pvrc
chmod 600 .env && chmod -R go-rwx certs
openssl rand -hex 32; openssl rand -hex 32; openssl rand -hex 32
nano .env
```
In `.env`, set or add:
```
POSTGRES_PASSWORD=<first random value>          # not change-me; DATABASE_URL is overridden inside Docker, leave it
LANGFUSE_NEXTAUTH_SECRET=<second random value>
LANGFUSE_SALT=<third random value>
API_DEMO_FAULTS=0
AGENT_ARCH=single                               # D44: the single agent is the deployed one
UI_BIND=127.0.0.1                               # UI through the SSH tunnel; step 10 explains 0.0.0.0
LLM_CACHE=0                                     # live answers in the deployed app
```
Keep `API_KEYS`, `API_KEY` (the UI's human key), the endpoint URLs and keys, and `EMBED_CA_BUNDLE` / `LLM_CA_BUNDLE`
(`certs/<file>`: the folder is mounted into the API container). `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` come in
step 9: this Langfuse is new and has no keys yet. Save with Ctrl+O, Enter, Ctrl+X.

Last, let the API container write where it needs to. It runs as uid 10001, and on Linux (unlike Docker Desktop) it cannot
write into folders the `ubuntu` user owns: traces and the token ledger in `observability/`, the response cache in
`data/processed/llm_cache/`:
```bash
mkdir -p observability data/processed/llm_cache
sudo chown -R 10001:10001 observability data/processed/llm_cache
```

## 6. Check the course endpoints are reachable from AWS (EC2)

```bash
grep -E "^(LLM|EMBED)_BASE_URL|_CA_BUNDLE" .env
curl -sS -o /dev/null -w "%{http_code}\n" --cacert certs/<embed-ca-file> "<EMBED_BASE_URL>/models"
curl -sS -o /dev/null -w "%{http_code}\n" "<LLM_BASE_URL>/models"      # add --cacert certs/<file> if LLM_CA_BUNDLE is set
```
Any HTTP status (200, 401, 404) means the network path works. A timeout or "connection refused" means the endpoint does
not accept this network: stop here and ask the course coordinator whether it is IP-restricted.

## 7. Build and start (EC2)

```bash
docker compose -f docker/docker-compose.yml -f docker/docker-compose.ec2.yml --env-file .env config --quiet && echo config OK
make up-ec2                  # first build downloads the Python packages: several minutes
make ps-ec2                  # repeat until api shows (healthy): 1-3 minutes, it loads the corpus first
make embeddings-ec2          # first deploy only: copies the 5,663 stored vectors into Postgres (hybrid search)
make smoke-ec2               # health, auth, full review, follow-up, refusal, UI
make chat-kb-ec2             # the chat's documentation knowledge base inside the container
```
If `make chat-kb-ec2` reports no files, or a missing folder: the chat reads documentation that is not in the API image
(`docker/Dockerfile.api` copies only `app/`, `scripts/`, `migrations/`). Add a `COPY <folder> ./<folder>` line for the
folder it names (for example `COPY docs ./docs`) after the other `COPY` lines, then `make up-ec2` again.

Check what listens on the public interface:
```bash
sudo ss -tlnp | grep -v 127.0.0.1
```
Only `:22` should appear (and `:8501` once you choose step 10). Anything else means a service is published to the
internet, for example a new service in `docker-compose.yml` that the overlay does not cover: add it to
`docker/docker-compose.ec2.yml` with `ports: !override ["127.0.0.1:<port>:<port>"]`.

If something fails: `make logs-ec2` (Ctrl+C to leave).

## 8. Open the UI through an SSH tunnel (laptop)

```powershell
ssh -i ..\pvrc-key.pem -N -L 8501:localhost:8501 -L 3000:localhost:3000 -L 8000:localhost:8000 ubuntu@<public-ip>
```
Leave the window open (it prints nothing), then browse to:
- http://localhost:8501: the UI. Run one of the demo paths, then ask a question in the chat (Ask the Copilot).
- http://localhost:8000/docs: the API.
- http://localhost:3000: Langfuse.

## 9. Connect Langfuse (browser + EC2)

At http://localhost:3000: Sign up (the account lives on your instance), create an organisation and a project, then
Settings → API keys → Create. **EC2:** put the two keys in `.env` as `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY`,
then `make up-ec2`. New requests now appear as traces.

## 10. Optional: the UI for the team without a tunnel

The UI has no login and holds a human API key that can record approval decisions, so open it only to known addresses:
- Console: the instance's security group → Edit inbound rules → Add rule: Custom TCP, port 8501, source
  `<teammate-ip>/32` (one rule per address; "My IP" fills in yours).
- **EC2:** set `UI_BIND=0.0.0.0` in `.env`, then `make up-ec2`.
- Browse to `http://<public-ip>:8501`.

Never use source 0.0.0.0/0. For anything beyond a demo, put the UI behind HTTPS and a login, for example an Application
Load Balancer with Cognito, or a reverse proxy with authentication.

## 11. Update, stop, clean up

| Task | Command |
|---|---|
| Deploy new code | **EC2:** `cd ~/pvrc && git pull && make up-ec2`, then `make smoke-ec2` |
| Changed `.env` | **EC2:** `make up-ec2` (recreates the containers that use it) |
| Stop the stack | **EC2:** `make down-ec2` (data, traces and Langfuse stay in the Docker volumes) |
| Stop paying for compute | Console: Instance state → Stop. Only the disk is billed while stopped. On start the stack comes back by itself (`restart: unless-stopped`); the public IP changes unless you attached an Elastic IP |
| End of project | Terminate the instance, delete its volume if kept, release any Elastic IP, delete the key pair |
