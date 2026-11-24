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
| Key pair | Create new: `pvrc-key`, RSA, .pem. Never save it inside the repository (`.pem` is not git-ignored) |
| Network | default VPC, public subnet, auto-assign public IP: enabled |
| Security group, inbound | SSH (TCP 22) from **My IP** only. Nothing else (step 10 optionally adds the UI for named IPs) |
| Storage | 30 GiB gp3 |

Launch, wait for "Running" and "2/2 checks passed", and note the **Public IPv4 address**. Optional: Elastic IPs →
Allocate → Associate with the instance, so the address survives a stop and start.

## 2. Connect (laptop)

Keep the key in `$HOME\.ssh` (outside the repository, and outside OneDrive-synced folders) and make it readable by you
only, or ssh refuses it with "bad permissions" (`chmod 400` is the Linux equivalent; it does not work in PowerShell).
Quote paths that contain spaces:
```powershell
mkdir $HOME\.ssh -Force
Move-Item "$HOME\Downloads\pvrc-key.pem" "$HOME\.ssh\pvrc-key.pem"
cd $HOME\.ssh
icacls .\pvrc-key.pem /reset
icacls .\pvrc-key.pem /inheritance:r
icacls .\pvrc-key.pem /grant:r "$(whoami):R"
icacls .\pvrc-key.pem /remove "Users" "Authenticated Users" "Everyone"
ssh -i $HOME\.ssh\pvrc-key.pem ubuntu@<public-ip>
```
A "Connection timed out" means the security group does not allow your current IP (it changes on many home and mobile
connections): edit the SSH inbound rule's source to My IP. Run the later `scp` and tunnel commands in PowerShell from
the project folder.
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
scp -i $HOME\.ssh\pvrc-key.pem .env ubuntu@<public-ip>:~/pvrc/.env
scp -i $HOME\.ssh\pvrc-key.pem -r certs ubuntu@<public-ip>:~/pvrc/
ssh -i $HOME\.ssh\pvrc-key.pem ubuntu@<public-ip> "mkdir -p ~/pvrc/data/processed"
scp -i $HOME\.ssh\pvrc-key.pem data\processed\corpus_v1.jsonl data\processed\store.sqlite ubuntu@<public-ip>:~/pvrc/data/processed/
scp -i $HOME\.ssh\pvrc-key.pem -r data\processed\embeddings ubuntu@<public-ip>:~/pvrc/data/processed/
```
If the chat uses any other generated file that git ignores (an index or cache under `data/`), copy it the same way.

**EC2:** lock the secrets down, then make three random values:
```bash
cd ~/pvrc
chmod 600 .env
chmod -R a+rX certs      # CA certificates are public; the API container (another user) must be able to read them
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
write into folders the `ubuntu` user owns: traces and the token ledger in `observability/`, and `data/processed/` (the
response cache, and the side files SQLite creates even when `make embeddings-ec2` only reads `store.sqlite`):
```bash
mkdir -p observability data/processed/llm_cache
sudo chown -R 10001:10001 observability data/processed
```
To `scp` new files into `data/processed` later, hand it back first (`sudo chown -R ubuntu:ubuntu data/processed`) and
return it afterwards (`sudo chown -R 10001:10001 data/processed`).

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
ssh -i $HOME\.ssh\pvrc-key.pem -N -L 8501:localhost:8501 -L 3000:localhost:3000 -L 8000:localhost:8000 ubuntu@<public-ip>
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

Never use source 0.0.0.0/0 for port 8501. To let anyone open the app, use step 11 instead.

## 11. A public HTTPS link that opens from anywhere

Caddy, a small web server on the instance, answers on `https://<your-name>.duckdns.org`, gets a free Let's Encrypt
certificate by itself, asks for a username and password, and only then passes the request to the UI on
`127.0.0.1:8501`. Port 8501, the API, Langfuse and Postgres stay closed to the internet.

1. **Fixed address.** Console: EC2 → Elastic IPs → Allocate Elastic IP address → Actions → Associate → your instance.
   Use this IP from now on (SSH, scp, the tunnel); it no longer changes on stop and start.
2. **Free domain name.** Sign in at https://www.duckdns.org (GitHub or Google account), add a subdomain, for example
   `pvrc-demo`, set its **current ip** to the Elastic IP and click **update ip**. Check from the laptop:
   `Resolve-DnsName pvrc-demo.duckdns.org` must show the Elastic IP.
3. **Security group.** Add inbound rules **HTTP (80)** and **HTTPS (443)**, source **0.0.0.0/0** (Anywhere-IPv4).
   Let's Encrypt must reach port 80 to issue the certificate; Caddy redirects it to HTTPS. Remove any port-8501 rule
   from step 10, and keep SSH limited to My IP.
4. **EC2:** keep the UI on loopback (`UI_BIND=127.0.0.1` in `.env`; if you changed it, run `make up-ec2`).
5. **EC2: install Caddy** (official repository):
   ```bash
   sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
   curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
   sudo apt-get update && sudo apt-get install -y caddy
   caddy version                     # 2.8 or newer
   caddy hash-password               # type the password twice; copy the $2a$... line it prints
   ```
6. **EC2: configure it.** `sudo nano /etc/caddy/Caddyfile`, delete everything and paste (your subdomain, the hash):
   ```
   pvrc-demo.duckdns.org {
       basic_auth {
           pvrc <paste the $2a$... hash>
       }
       reverse_proxy 127.0.0.1:8501
   }
   ```
   Then:
   ```bash
   sudo systemctl reload caddy
   sudo journalctl -u caddy --no-pager -n 40 | grep -iE "certificate obtained|error"
   ```
   "certificate obtained successfully" means it works. An error about the challenge almost always means step 2 (the
   name does not point at the Elastic IP yet; DNS can take a few minutes) or step 3 (port 80 closed).
7. **Open** `https://pvrc-demo.duckdns.org` from any browser or phone, sign in as `pvrc` with your password.

Caddy starts on boot and renews the certificate by itself. Anyone with the password can use the whole UI, including
recording approval decisions with the UI's human key: share it only with the team and the evaluators, and change it
after the evaluation (`caddy hash-password`, edit the Caddyfile, `sudo systemctl reload caddy`). This is fine for a demo
on synthetic data; real vendor data would need a login per person (for example an Application Load Balancer with
Cognito) so that decisions are recorded under each approver's own name.

### 11b. Optional: the Langfuse dashboard on its own HTTPS link

Without this step Langfuse stays reachable only through the SSH tunnel (step 8), which is the safest choice. Langfuse has
its own email-and-password login, so it can also get a public address. The API keeps sending traces to Langfuse inside
Docker (`http://langfuse:3000`); nothing changes for it.

1. **Accounts first.** Through the tunnel, make sure everyone who needs the dashboard has an account (sign up, or invite
   them from the project settings): step 3 closes self sign-up.
2. **Second DuckDNS subdomain**, for example `pvrc-traces`, pointing at the same Elastic IP.
3. **EC2: `.env`** — add, with your subdomain:
   ```
   LANGFUSE_URL=https://pvrc-traces.duckdns.org
   LANGFUSE_DISABLE_SIGNUP=true
   ```
   then `make up-ec2`. `LANGFUSE_URL` is where Langfuse sends the browser after login; leave `LANGFUSE_HOST` as it is.
4. **EC2: Caddy.** `sudo nano /etc/caddy/Caddyfile`, add a second block under the first:
   ```
   pvrc-traces.duckdns.org {
       reverse_proxy 127.0.0.1:3000
   }
   ```
   then `sudo systemctl reload caddy` and check the log for "certificate obtained successfully".
5. **Open** `https://pvrc-traces.duckdns.org` and sign in with your Langfuse account.

The traces hold every prompt and answer, so use strong passwords. For a second lock, add the same `basic_auth { ... }`
block as the UI's inside this site block. With `LANGFUSE_URL` set, logging in through the tunnel (`localhost:3000`)
also redirects to the public address; that is expected.

## 12. Update, stop, clean up

| Task | Command |
|---|---|
| Deploy new code | **EC2:** `cd ~/pvrc && git pull && make up-ec2`, then `make smoke-ec2` |
| Changed `.env` | **EC2:** `make up-ec2` (recreates the containers that use it) |
| Stop the stack | **EC2:** `make down-ec2` (data, traces and Langfuse stay in the Docker volumes) |
| Stop paying for compute | Console: Instance state → Stop. Only the disk is billed while stopped. On start the stack comes back by itself (`restart: unless-stopped`); the public IP changes unless you attached an Elastic IP |
| End of project | Terminate the instance, delete its volume if kept, release the Elastic IP (an unattached one is billed), delete the DuckDNS subdomain and the key pair |
