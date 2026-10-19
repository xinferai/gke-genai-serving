# Argo CD for the GKE lab: design

Status: design approved by Sam Wen on 2026-10-15; files built and `./check` passing offline; not yet run on a cluster.
Build plan: `docs/superpowers/plans/2026-10-15-argocd.md`. Pilot POC work (Session 3 of the
POC plan), not production.
Extended to two environments on 2026-10-15 by docs/superpowers/specs/2026-10-15-two-environments-design.md, whose
"What changes in the Argo CD design" replaces the single-environment details here.

## What this is for

Session 3 of the POC plan: Argo CD watching a private GitHub repository, deploys by commit, roll back with
`git revert`, and a change made by hand with `kubectl` that Argo CD puts back: Helm,
Argo CD and GitOps in practice.

Decided by Sam Wen on 2026-10-15:
- Argo CD deploys **the chat app as it is**: Open WebUI and Ollama (`apps/chat/values.yaml`) and the public entrance
  (`apps/chat/edge.yaml`). No new sample app and no tenants; those belong to Session 2.
- Argo CD itself is installed by **a bootstrap script** run after `./tf apply`, not by Terraform.
- The apps are laid out as **one root app with two child apps** ("app of apps").
- The four design parts below (layout, GitHub key and security, teardown and gotchas, testing) were approved one at a
  time in chat.

Assumed, and not corrected: Argo CD reads this same private repository (`xinferai/gke-genai-serving`) with a read-only deploy
key; its screen is reached by port-forward only; it is installed fresh on every rebuild like everything else; nothing
is applied or pushed without Sam's word.

## 1. Layout and flow

New files:

| File | Holds |
|---|---|
| `bootstrap` | Run after `./tf apply`. Installs Argo CD with Helm (chart `argo-cd` 10.10.5 from https://argoproj.github.io/argo-helm, which is Argo CD 3.5.5), creates the repository secret from the deploy key file, and applies the root app. Safe to run twice. |
| `argocd/values.yaml` | Argo CD's own settings: the single sign-on server (`dex`) and notifications off; `configs.params."server.insecure": true` (see part 2); resource requests on each component; every component on the `system` pool (`global.nodeSelector: {pool: system, kubernetes.io/os: linux}`). |
| `argocd/root.yaml` | The root app, `root`: keep whatever is in `argocd/apps/` on `main` running. |
| `argocd/apps/chat.yaml` | The `chat` app (below). |
| `argocd/apps/chat-edge.yaml` | The `chat-edge` app (below). |
| `check` | The offline checks (part 4): run before every push. |
| `test/bootstrap_test.sh` | Runs `bootstrap` against stand-ins for `./k` and `./h`; part of `./check`. |

Nothing existing moves. `apps/chat/values.yaml` and `apps/chat/edge.yaml` stay where they are.

The three apps, all in the `argocd` namespace and Argo CD's built-in `default` project, all with automatic sync,
`prune` and `selfHeal` on, all with `syncPolicy.retry` (limit 5, because automated sync does not try a failed sync
again for the same commit unless told to), and all with the finalizer `resources-finalizer.argocd.argoproj.io`
(part 3):

- **`root`**: source is this repository, `main`, folder `argocd/apps`. Destination is the `argocd` namespace (the two
  child apps are objects there).
- **`chat`**: two sources. The chart `open-webui` 17.0.0 from https://helm.openwebui.com, with Helm release name
  `chat` and the values file `$values/apps/chat/values.yaml`; and this repository at `main`, marked `ref: values`, so
  the chart can read our values file from git. Destination is the `chat` namespace, created by Argo CD
  (`CreateNamespace=true`).
- **`chat-edge`**: this repository at `main`, folder `apps/chat`, only the file `edge.yaml` (a directory `include`
  filter, because `values.yaml` in the same folder is not a Kubernetes object). Destination is the `chat` namespace,
  also with `CreateNamespace=true`, in case it arrives before `chat` has made it.

Argo CD runs on the `system` pool because that pool is on-demand: a Spot reclaim cannot stop the controller in the
middle of a change.

How a change reaches the cluster: a commit is pushed to `main`; Argo CD looks at git every 3 minutes (no webhook,
because its screen is not public; the Refresh button makes it look now); it renders the chart with our values and
applies the result. Self-heal puts back a change made by hand within seconds; prune deletes what was deleted from git.

Rebuild becomes `./tf apply`, then `./bootstrap`. Still about 25 minutes, mostly the GPU cold start.

**From now on, a deploy is a push to `main`.** Under the rule that nothing is pushed without Sam's word, every
deploying step is a push he approves (or a standing go he gives for one session).

## 2. The GitHub key and security

**Read access to the private repository: a read-only deploy key.**
- A new key pair made only for this. The private half is `~/.ssh/gke-genai-serving-argocd` on Sam's Mac, outside the
  repository, readable only by him. The public half is added once to `xinferai/gke-genai-serving` as a deploy key, read-only,
  and stays across rebuilds. Adding it changes GitHub, so this command is run only on Sam's word (read-only is the
  default; it would take `--allow-write` to make it writable):
  `gh repo deploy-key add ~/.ssh/gke-genai-serving-argocd.pub --repo xinferai/gke-genai-serving --title "argocd-lab (read-only)"`.
- A deploy key opens one repository, read-only: it cannot push and cannot see any other repository.
- On each rebuild, `./bootstrap` creates the Kubernetes Secret `repo-gke-genai-serving` in the `argocd` namespace (label
  `argocd.argoproj.io/secret-type: repository`; `type: git`, `url: git@github.com:xinferai/gke-genai-serving.git`, and the
  private key) straight from that file with `kubectl`. It exists only while the cluster does. It is never in git,
  never in Terraform state, and never passed to Helm, so it is not copied into Helm's release history.
- Argo CD already ships GitHub's SSH host keys, so nothing else is needed to trust github.com.
- Not chosen: a GitHub App (the better answer for a company: no personal key, short-lived tokens, many repositories);
  a personal access token (tied to Sam's account, expires); Secret Manager with External Secrets Operator (the
  production way to deliver this Secret; Session 5).

**Argo CD's screen and login.**
- Port-forward only: `./k -n argocd port-forward svc/argocd-server 8081:443`, then http://localhost:8081. Argo CD's
  own HTTPS is off (`server.insecure`) because the port-forward runs inside kubectl's own encrypted connection to the
  cluster; this avoids a browser certificate warning.
- The admin password is random, made by Argo CD at install, in the Secret `argocd-initial-admin-secret`. The README
  copies it to the clipboard without showing it:
  `./k -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | pbcopy`.

**The security fact this adds.** Argo CD's controller may create anything in any namespace, so whoever can push to
`main` can change the cluster: git access is cluster access. In the lab that is only Sam. On a real platform:
required reviews on `main`, and one Argo CD project per team or tenant, each listing the namespaces and kinds of
object its apps may touch. The lab keeps the `default` project, which allows everything; per-tenant projects belong to
Session 2.

## 3. Teardown, and the gotchas Argo CD adds

**Teardown.** Argo CD puts back anything deleted by hand (the root app even puts back a deleted child app), so
teardown goes through Argo CD. Every app carries the finalizer, so deleting the root removes the child apps, and each
child removes what it made: the Gateway (and with it the load balancer), Open WebUI, Ollama, and both disks (both are
PersistentVolumeClaims the charts create directly, so they are deleted with the app).

```
./k -n argocd delete application root           # waits until Argo CD has removed it all
gcloud --configuration=gke-lab compute forwarding-rules list   # wait until empty
./tf destroy
rm ~/projects/gke-lab/.kubeconfig
gcloud --configuration=gke-lab compute disks list              # should be empty
```

`./h uninstall chat` and the namespace delete go away (there is no Helm release, and the cluster goes with
`./tf destroy`). Argo CD itself needs no removal: it owns nothing outside the cluster. The two waits stay, because a
cluster destroyed too early still leaves the load balancer or the 40 GB disk behind, billing.

**Gotchas.**
1. **The GPU-off trick in the README stops working.** `./k scale deploy/chat-ollama --replicas=0` is put back to 1
   within seconds. The GitOps way is a commit: `ollama.replicaCount: 0` in `apps/chat/values.yaml` (the Ollama
   sub-chart has this setting, default 1). Argo CD scales it down within about 3 minutes; the autoscaler removes the
   GPU node about 10 minutes later. The README section is rewritten to say this.
2. **Emergency fixes by hand are undone.** In an incident, either fix it in git, or switch off automatic sync on
   `root` first and then on the app, and switch `root` back on afterwards (which also restores the app's own sync from
   git). Switching off only the app does not work: `root` self-heals the app's settings from git within seconds.
   (Found by the final review, 2026-10-15; Argo CD's cluster-bootstrapping docs show the other way out, an
   `ignoreDifferences` on `/spec/syncPolicy/automated` in the root app.) Forgetting to switch `root` back on is the usual
   mistake.
3. **Deploys are not instant**: up to about 3 minutes, unless Refresh is pressed.
4. **Fields GKE adds may show as "OutOfSync".** GKE's controllers write their own fields onto some objects (the
   Gateway's addresses and status, load-balancer annotations on Services). If Argo CD reports these as drift, each one
   gets an explicit `ignoreDifferences` entry on its app, with a comment saying what writes it. The chart has no
   values that change on every render (no random passwords, no lookups in the cluster), checked in chart 17.0.0.
5. **The two apps may show errors for a minute or two.** If `chat-edge` arrives before `chat`, its health check and
   Cloud Armor settings point at a Service that does not exist yet. GKE retries and it settles. No ordering machinery
   is added for this.
6. **Names stay the same.** The `chat` app keeps Helm release name `chat`, so objects are still `chat-open-webui` and
   `chat-ollama`, which `edge.yaml` and the NetworkPolicy rely on. Argo CD 3.x tracks its objects with an annotation;
   Argo CD 2.x used the label `app.kubernetes.io/instance`, overwriting the chart's own label of that name, which the
   NetworkPolicy matches on. Testing confirms the label is untouched.
7. **The chart's test pod.** The Ollama sub-chart ships a Helm test pod (`helm.sh/hook: test`); `chat` sets
   `helm.skipTests: true`, so Argo CD never deploys it. Testing confirms no `test-connection` pod.
8. **Cost.** Argo CD's pods (about five) on the `system` pool may push it to its second node, about $0.07 an hour at
   list price.
9. **No more `helm history`.** The history is the git log and Argo CD's own list of syncs; rollback is `git revert`
   and a push.

## 4. Testing

Sam checks the running system from the outside. Timings and findings go into the progress notes in `plan.md`.

**Before spending money (free):**
- `./check` passes: the chat chart renders the way Argo CD renders it and keeps the names `edge.yaml` and the
  NetworkPolicy use; Argo CD's settings render as intended; `edge.yaml` and the three apps match their schemas, with
  unknown (misspelt) fields rejected; the apps' fields follow the rules above; shellcheck; `bootstrap` run against
  stand-ins (order, the key kept from Helm and the screen, stopping on a missing key or a failed step); the README
  describes the Argo CD way of working.
- Order: commit and push the new files (Sam's word; Argo CD reads GitHub, not this folder), add the deploy key (Sam's
  word), and renew the gcloud login: `! gcloud --configuration=gke-lab auth login`.

**On the live cluster (one session, about 1.5 hours, roughly $1 at list prices):**

| # | Check | Expected |
|---|---|---|
| 1 | `./tf apply`, then `./bootstrap` | Argo CD's pods running on the `system` pool; `root`, `chat`, `chat-edge` Synced and Healthy within about 25 minutes |
| 2 | The public checks from 2026-10-14 | Page 200 from Sam's Mac; http 301; `/api/models` without a key 401; the Cloud NAT address 403; backend HEALTHY |
| 3 | NetworkPolicy and labels | Pods still carry `app.kubernetes.io/instance: chat`; the README's two-command check: Open WebUI reaches Ollama, a throwaway pod times out. The first live test of the NetworkPolicy |
| 4 | Deploy by commit: change `WEBUI_NAME`, push | The new name is on the page within about 3 minutes, with no `helm` or `kubectl` from us |
| 5 | Roll back with `git revert`, push | The old name returns |
| 6 | Drift: scale Ollama to 0 by hand; delete the HTTPRoute `chat` by hand; switch off automatic sync on `chat` alone | All three put back within seconds (the last by `root`) |
| 7 | GPU off by commit (`ollama.replicaCount: 0`), push; then revert, push | The Ollama pod goes, the GPU node is removed about 10 minutes later; after the revert it returns, faster than a first start, because the model disk keeps the model |
| 8 | Gotcha checks | Any OutOfSync fields noted, each with an ignore entry; no `test-connection` pod; whether the `system` pool went to 2 nodes recorded |
| 9 | Teardown: delete `root` | The delete returns only when the apps, the Gateway, the pods and both disks are gone; forwarding rules clear; after `./tf destroy`, `disks list` is empty |

Pass: all nine as expected. A failure in 1, 3 or 9 (access, security, leftovers that keep billing) stops the session
until it is fixed. Anything new goes into the README and `plan.md`.

Pushes in the session: checks 4, 5 and 7 need five pushes in all.

## Files changed besides the new ones

- `README.md`: the rebuild (`./tf apply`, `./bootstrap`), Argo CD's screen and password, deploying by commit, the
  GPU-off section (by commit now), and the new end-of-session order.
- `.gitignore`: nothing new (the deploy key lives outside the repository).
- The session notes outside this repository: progress notes after the test session.

## Not in this design

Tenants, ApplicationSets and per-tenant Argo CD projects (Session 2); image builds and image-tag updates by CI
(Session 4); Secret Manager for the deploy key (Session 5); Argo CD managing its own installation; a public Argo CD
screen; webhooks from GitHub.
