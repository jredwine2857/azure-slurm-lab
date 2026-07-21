# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A learning project: GitHub Actions CI/CD + Bicep IaC that deploys a minimal 2-node Slurm cluster to Azure (one controller, one compute, both CPU-only `Standard_B2s`), so PyTorch jobs can be submitted to a real scheduler without paying for it to sit idle. No SSH, no public IPs — everything is driven through `az vm run-command invoke` over the Azure control plane.

## Commands

Local validation before pushing infra changes:
```bash
az bicep build --file infra/main.bicep
az deployment group what-if \
  --resource-group rg-slurm-lab \
  --template-file infra/main.bicep \
  --parameters mungeKeyBase64=$(head -c 32 /dev/urandom | base64 -w0) adminPassword='Temp123!Temp123!'
```

Driving the pipeline (requires `gh auth login` with a token that has the `workflow` scope):
```bash
gh workflow run deploy-slurm.yml     # deploys, leaves cluster running; gated by the azure-lab environment
gh workflow run destroy.yml          # tears down rg-slurm-lab, no gate
gh run watch <run-id> --exit-status  # follow a run to completion
```

`deploy-slurm.yml`'s `deploy` job requires manual approval (GitHub Environment `azure-lab`). To approve programmatically instead of clicking in the UI:
```bash
gh api repos/jredwine2857/azure-slurm-lab/actions/runs/<run-id>/pending_deployments \
  -F "environment_ids[]=<env-id>" -f "state=approved" -f "comment=..."
```

Poking at a live cluster (once `deploy-slurm.yml` has finished) — this is the *only* access path, there is no SSH:
```bash
az vm run-command invoke --resource-group rg-slurm-lab --name vm-controller \
  --command-id RunShellScript --scripts "sinfo -N -l"

az vm run-command invoke --resource-group rg-slurm-lab --name vm-controller \
  --command-id RunShellScript \
  --scripts "srun --nodes=1 --nodelist=compute python3 -c 'import torch; print(torch.rand(3,3))'"
```
Output from `run-command` is capped at 4096 bytes — keep diagnostic scripts narrow (pipe through `grep`/`tail`) or you'll silently lose the part you need.

One-time environment bootstrap: `scripts/bootstrap-oidc.sh` (edit the `GITHUB_ORG`/`GITHUB_REPO` vars at the top first). It's idempotent — safe to re-run.

## Architecture

**Three independent workflows, not one lifecycle job:**
- `deploy-slurm.yml` — `workflow_dispatch` only. `deploy` job (environment-gated) runs `az deployment group create`; `smoke-test` job polls `sinfo`/`srun` via run-command, then **leaves the cluster running**. There is deliberately no auto-destroy — the cluster needs to stay up long enough to actually run jobs on.
- `destroy.yml` — manual, no gate, blocking `az group delete` (no `--no-wait`, so success in the log means Azure has confirmed full deletion, not just queued it).
- `auto-destroy-stale.yml` — hourly cron backstop that reads a `deployedAt` tag on `rg-slurm-lab` (set by the deploy job) and destroys if older than the TTL. This exists because destroy is otherwise manual and cost risk is "forgot to run it," not "rate is too high."

**Static IPs, not service discovery.** Controller is always `10.0.0.4`, compute is always `10.0.0.5`, assigned in Bicep (`privateIPAllocationMethod: 'Static'`). `slurm.conf` is baked into both cloud-init files with these literal addresses — there's no runtime discovery logic to reason about.

**Controller runs both `slurmctld` and `slurmd`.** It's not a pure control node; it's also schedulable, so a 2-node partition (`debug`, in `infra/cloud-init/*.yaml`) actually has two working `slurmd`s. If you add a third pure-controller node, you'd need to remove it from `PartitionName=... Nodes=...`.

**Only the munge key is templated at deploy time** (`__MUNGE_KEY__` in the cloud-init YAML, substituted via Bicep's `replace(loadTextContent(...), ...)`). Everything else in `slurm.conf`/cloud-init is static committed text — IPs and hostnames are design-time constants, not something Bicep computes.

**Cloud-init `write_files` ordering is load-bearing.** `write_files` runs *before* the `packages` install step in cloud-init's module order. The `munge.key` entry must NOT set `owner: munge:munge` in `write_files` — the `munge` user doesn't exist yet at that point in boot, the `chown` lookup throws, and **that failure aborts the entire `write_files` module**, silently dropping every other file in it (`slurm.conf`, the `/etc/hosts` entries) with no obvious error at the cloud-init level. Ownership/permissions on the key are fixed up in `runcmd` instead, which runs after packages install. If you add more `write_files` entries, keep this ordering constraint in mind.

**`customData` only applies at first boot.** Changing cloud-init content and re-running `az deployment group create` against existing VMs does *not* re-trigger cloud-init — Bicep will happily "update" the VM resource but the new customData is inert. To pick up a cloud-init change you must destroy and recreate (`destroy.yml` then `deploy-slurm.yml`), not just redeploy.

## OIDC auth (GitHub Actions → Azure)

No stored credentials — federated identity via `azure/login@v2`. Two gotchas that cost real debugging time and are easy to reintroduce if the federated credentials are ever recreated by hand instead of via `scripts/bootstrap-oidc.sh`:

1. **The OIDC subject claim includes numeric owner/repo IDs**, not just names: `repo:OWNER@OWNERID/REPO@REPOID:environment:azure-lab` (or `:ref:refs/heads/main`), not the older `repo:OWNER/REPO:...` format. `bootstrap-oidc.sh` resolves these via `gh api repos/OWNER/REPO --jq '.owner.id'` / `.id` rather than hardcoding.
2. **The issuer must be `https://token.actions.githubusercontent.com` with no trailing slash.** Azure AD does exact string matching; a trailing slash produces `AADSTS700211: No matching federated identity record found` even when subject and audience are correct.

**The role assignment is subscription-scoped, not resource-group-scoped**, and that's deliberate, not an oversight: RBAC role assignments are children of the scope they're assigned to, so a `rg-slurm-lab`-scoped assignment gets deleted along with the resource group on every `destroy.yml` run, breaking the *next* deploy (`azure/login` succeeds but reports no subscriptions). See the comment in `scripts/bootstrap-oidc.sh` above the role assignment for the full reasoning.

Git Bash/MSYS on Windows mangles leading-slash arguments (like `/subscriptions/...` resource IDs) into fake Windows paths. `bootstrap-oidc.sh` sets `MSYS_NO_PATHCONV=1` for the role-assignment calls specifically — don't set it globally in a script that also passes real file paths (e.g. `az ad app federated-credential create --parameters /tmp/foo.json`), or those file paths break instead.
