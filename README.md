# azure-slurm-lab

A learning project: GitHub Actions CI/CD + Bicep IaC that deploys a minimal
2-node Slurm cluster (plus a Prometheus/Grafana monitoring node) to Azure, so
you can practice submitting jobs (including PyTorch jobs) to a real Slurm
scheduler without paying for it to sit idle.

## What gets created

- 1 resource group (`rg-slurm-lab`)
- 1 VNet/subnet (`10.0.0.0/24`), 1 NSG — default rules only (no inbound from
  the internet, VNet-internal traffic allowed, outbound allowed) plus one
  explicit rule allowing TCP 3000 (Grafana) from your IP to `vm-monitor` only
- `vm-controller` (10.0.0.4, runs `slurmctld` + `slurmd` + `node_exporter`,
  no public IP)
- `vm-compute` (10.0.0.5, runs `slurmd` + `node_exporter`, Python + CPU
  PyTorch installed, no public IP)
- `vm-monitor` (10.0.0.6, runs Prometheus + Grafana + `node_exporter`,
  **the only VM with a public IP** in this project, locked down to your IP
  on port 3000 only)

No SSH is exposed anywhere. All access to the Slurm nodes from CI (and from
your machine, if you want it) goes through `az vm run-command invoke`, which
executes scripts on the VM via the Azure control plane. Grafana is the one
exception — it's meant to be browsed interactively, so it gets a real public
IP instead.

## Monitoring

Prometheus scrapes `node_exporter` (host-level CPU/mem/disk/network metrics)
on all three nodes — this is host metrics only, not Slurm job/queue metrics.
There's no `apt`-packaged Slurm Prometheus exporter; adding one would mean
pulling a third-party binary release into cloud-init, which is more fragility
than this pass is taking on. A Slurm-specific exporter is a reasonable
follow-up once this is proven reliable.

Grafana comes up with the Prometheus datasource already provisioned (no
manual wiring) but ships at the default `admin`/`admin` login — **change the
password immediately**, since it's reachable from the public internet (just
restricted to the one IP you pass in as `allowedIp`). Add a dashboard like
"Node Exporter Full" (Grafana.com dashboard id `1860`) to actually see the
metrics.

## Cost

3x `Standard_B2s` (~$0.0416/hr each in East US, so ~$0.12/hr total) plus
trivial disk/network cost. A few hours of use is well under a dollar. The
real risk isn't the rate, it's forgetting to destroy — see the safety nets
below.

## Lifecycle

- **`Deploy Slurm Lab`** (manual, gated by the `azure-lab` GitHub Environment —
  you have to approve the run) deploys the cluster and **leaves it running**.
  Requires an `allowedIp` input — your current public IP (check
  `https://ifconfig.me`) in CIDR form, e.g. `203.0.113.5/32` — used to lock
  down Grafana access; if your IP changes, redeploy with the new value. It
  ends with a smoke test (`sinfo`, a two-node `srun hostname`, and confirming
  Prometheus sees all three `node_exporter` targets as up) so you know
  everything actually formed before you start using it.
- **`Destroy Slurm Lab`** (manual) deletes the resource group. Run this when
  you're done for the day.
- **`Auto-Destroy Stale Slurm Lab`** runs hourly and destroys the lab
  automatically if it's been up longer than 4 hours (configurable via the
  workflow's `ttl_hours` input when run manually). This is the backstop for
  "I forgot" — don't rely on it as your primary cleanup step.

## Running a PyTorch job

Once `Deploy Slurm Lab` finishes, from your machine (with `az login` and
rights to `rg-slurm-lab`):

```bash
az vm run-command invoke \
  --resource-group rg-slurm-lab \
  --name vm-controller \
  --command-id RunShellScript \
  --scripts "srun --nodes=1 --nodelist=compute python3 -c 'import torch; print(torch.rand(3,3))'"
```

`Standard_B2s` is CPU-only — fine for toy scripts and learning the Slurm
submission flow, not real training throughput. Swapping `vmSize` to a GPU
SKU (e.g. an NC-series) is a one-line param change for later, but costs
meaningfully more — treat that as a deliberate next step, not a default.

## One-time setup (before the first deploy)

1. Install tools: `winget install Microsoft.AzureCLI`, `winget install GitHub.cli`
2. `az login`, `gh auth login`
3. Push this repo to GitHub (`gh repo create` or push to an existing empty repo)
4. Edit the variables at the top of `scripts/bootstrap-oidc.sh` (your GitHub
   org/username and repo name), then run it. It creates the resource group,
   an Entra app registration + service principal, two OIDC federated
   credentials (one for the environment-gated deploy job, one for the
   branch-triggered smoke-test/destroy jobs), and a **subscription-scoped**
   Contributor role assignment. It's subscription-scoped rather than
   `rg-slurm-lab`-scoped deliberately: a resource-group-scoped role
   assignment is a child of that group and gets deleted along with it on
   every `az group delete` in `destroy.yml`, which breaks the *next* deploy
   (login succeeds but the identity has no role anywhere). The workflows
   themselves only ever touch `rg-slurm-lab`, but the identity technically
   could reach other resource groups in the subscription — worth knowing if
   you reuse this app registration for anything else.
5. Set the three secrets it prints out: `gh secret set AZURE_CLIENT_ID`,
   `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
6. In the repo's Settings → Environments, create an environment named
   `azure-lab` and add yourself as a required reviewer.

## Local validation before pushing changes

```bash
az bicep build --file infra/main.bicep
az deployment group what-if \
  --resource-group rg-slurm-lab \
  --template-file infra/main.bicep \
  --parameters mungeKeyBase64=$(head -c 32 /dev/urandom | base64 -w0) \
               adminPassword=$(openssl rand -base64 24) \
               allowedIp="$(curl -s https://ifconfig.me)/32"
```

## Manual cleanup fallback

If anything goes sideways and the workflows aren't available:

```bash
az group delete --name rg-slurm-lab --yes
```

or delete `rg-slurm-lab` from the Azure Portal.

## Recommended VSCode extensions

- `ms-azuretools.vscode-bicep` — Bicep syntax, validation, IntelliSense
- GitHub Actions extension — view/trigger workflow runs from the editor
- GitHub Pull Requests and Issues — review/merge without leaving VSCode

## Out of scope for now

GPU SKUs, SSH/interactive access, multi-job scheduling patterns, Slurm-level
job/queue metrics (vs. the host-level metrics this already has) — natural
next steps once this base deploy → use → destroy loop is proven reliable.
