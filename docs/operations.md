# Running the lab

## Commands

The environment is always the first word; there is no default.

```
./startup main                        # bring an environment up (or production, or both): below
./teardown main                       # take its cluster down again, keeping the entrance and the chat data
./tf main cluster plan -out=tfplan    # Terraform for one environment and one layer (cluster or edge)
./tf main cluster apply tfplan
./bootstrap main                      # install Argo CD; it installs the apps from GitHub, branch main
./k main get nodes                    # kubectl for that environment's cluster
./h main list -A                      # Helm, same cluster
./check                               # offline checks for both environments; run before every push
./hotfix                              # an urgent fix for production, step by step (release-process.md)
```

- `./tf` runs Terraform as the account the environment's gcloud profile names, in `envs/<env>/<layer>`. Commands
  that change an environment (`apply`, `destroy`, `import`, `force-unlock`, `taint`, `untaint`, `state
  mv/rm/push/replace-provider`) run only from that environment's branch, with no uncommitted changes, and identical to
  GitHub's copy, and without `-var` or `-var-file`. `plan` and the other read-only commands run anywhere, so a change
  can be previewed from a short-lived branch. A saved plan (`plan -out=tfplan`) can be applied only on the commit it
  was made from, with nothing uncommitted then (`./tf` writes `tfplan.commit` beside it): a plan saved on a
  short-lived branch is refused on the environment's branch. The first time in a folder, run `./tf <env> <layer>
  init`.
- Who may connect is the one setting kept off GitHub. Once, before the first `./tf`, `./startup` or `./teardown`: copy
  `access.tfvars.example` to `access.tfvars` (git ignores it) and put your public address in it. `./tf` hands its
  `admin_cidr` (the control plane) and `allowed_cidrs` (Cloud Armor) to Terraform, and `./startup` and `./teardown`
  copy it into their fresh copy of GitHub's branch. If your address changes, kubectl times out and the page answers
  403: update the file, then plan and apply each environment's `cluster` and `edge`. `./startup` and `./teardown`
  notice a changed address before they start, and list those commands.
- `./k` and `./h` use `.kube/<env>/config`, so `~/.kube/config` is never touched and the two clusters never mix.

## Terraform habits

The four Terraform roots are identical apart from `terraform.tfvars` and where `versions.tf` keeps the state (`./check`
compares them). Lab answers go in [`notes.md`](../notes.md). Give each saved plan its own name (`-out=tfplan-gpu`), so
an applied plan is never mistaken for a new one.

## Start of a session

```
./startup main          # one environment (or production)
./startup both          # both side by side: the steps in the terminal, the full output in .logs/
```

It brings the environment from nothing to its page answering over HTTPS, in about 20 minutes (both side by side
also take about 20). What comes up is GitHub's branch, not this folder: it works in a fresh clone, on the branch named
after the environment, so merge first. Only the commands themselves (`./startup`, `./teardown`, `lib/`) run from this
folder, which can be on any branch, with anything uncommitted.

Before anything changes, it checks what it needs from outside this repository (`lib/preflight.sh`) and prints each
check as `ok` or `NO`:
- each environment's gcloud profile: it names an account (the one it names is the one checked) and the
  environment's project, and gets a fresh token without a prompt, so a run cannot stop halfway for a password;
- kubectl's GKE sign-in plugin, `gke-gcloud-auth-plugin`;
- this Mac's public address (asked of https://checkip.amazonaws.com) is in `access.tfvars`;
- each environment's Argo CD deploy key is on this Mac, and GitHub accepts it for this repository (`./bootstrap` needs
  it, about 12 minutes in).

If any is missing, it stops there, with nothing cloned or changed, and lists the commands that put it right, then to
run it again. Then, in order:

1. The entrance's certificate is ACTIVE, and the chat data disk `chat-data` is there (else it stops: both come from
   `./tf <env> edge`, see [architecture.md](architecture.md#public-https)).
2. Terraform plans the cluster and goes on only if the plan just adds; a plan that would change or remove anything
   stops it (look with `./tf <env> cluster plan`). Then it applies that saved plan, about 12 minutes.
3. Fresh credentials: the new cluster has a new address, so this folder's `.kube/<env>` goes.
4. `./bootstrap <env>`: Argo CD, which installs the apps from GitHub.
5. It waits for every Argo CD app to be Synced and Healthy (5 to 6 minutes; it gives up after 25), then for the page
   to answer 200 over HTTPS (it gives up after 15). While it waits it names each pod that is not running, with its
   latest warnings, such as `FailedScaleUp: ... GCE out of resources` when Google has no Spot GPU free in the zone,
   and every 5 minutes without a change it says it is still waiting.

Each step prints its time, and the run ends with a list of them. With `both`, the terminal shows each run's steps as
they happen, after the environment's name, and reports each run as soon as it ends; Terraform's and kubectl's own
output goes only to that run's log in `.logs/`. A run that failed part-way can simply be run again:
with the cluster up, the plan has nothing to add, and it carries on from there. Ctrl-C stops it (with `both`, both
runs), and Terraform stops cleanly on the first one; a second makes it stop at once, perhaps leaving its state locked.
The clone is removed only once nothing runs in it.

## End of a session

```
./teardown main         # or production, or both; asks for the word to be typed again
```

About 12 minutes, both side by side too. Like `./startup`, it works in a fresh clone on the environment's branch,
because `./tf <env> cluster destroy` runs only from that branch, clean and identical to GitHub. It makes the same
checks first, all but the deploy key; for a changed address, the fix is the cluster's control plane. In order:

1. It deletes the root app: Argo CD then removes everything it made, the Gateway (and with it the load balancer), the
   chat app and its 40 GB model disk. The chat data disk's volume goes too, but it is `Retain`, so the disk `chat-data`
   stays, and the accounts and chats with it. Deleting things one by one with `./k` does not work: Argo CD puts them
   back.
2. It waits for the load balancer to go (no forwarding rules left). A cluster destroyed while it still exists leaves
   it behind, still billing, and holding on to the IP and certificate map; so if it is not gone within 15 minutes,
   nothing is destroyed.
3. `./tf <env> cluster destroy`.
4. It removes this folder's `.kube/<env>` (the next cluster has a new address), then checks that no disk is left but
   `chat-data`.

By hand, the same steps for main, from the `main` branch (for production: `production` and `--configuration=gke-lab`,
from the `production` branch):

```
./k main -n argocd delete application root      # waits until Argo CD has removed it all
gcloud --configuration=gke-lab-main compute forwarding-rules list   # wait until empty
./tf main cluster destroy
rm -r ~/projects/gke-lab/.kube/main             # the next cluster has a new address
gcloud --configuration=gke-lab-main compute disks list   # only chat-data: no other disk left behind
```

Each environment's `edge` stays: roughly $15 a month each at list prices (about $7 for an idle fixed IP, about $7 for
a Cloud Armor policy with two rules, about $1 for the 10 GB data disk). To remove one as well, accounts and chats
included: take `prevent_destroy` off the data disk in `modules/edge/main.tf` through the usual pull requests, then
`./tf <env> edge destroy`, then delete its two records in Route 53.
