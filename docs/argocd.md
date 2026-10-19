# Argo CD

`./bootstrap <env>`, after `./tf <env> cluster apply`, installs Argo CD (chart `argo-cd` 10.10.5, which is Argo CD
3.5.5; settings in `argocd/values.yaml`, all on the `system` pool), gives it read access to this repository, and
applies `argocd/<env>`, the root app. The root app keeps `argocd/<env>/apps` running from the branch named after the
environment: `chat` (Open WebUI and Ollama) and `chat-edge` (the public entrance). Running it again is safe. Design:
[superpowers/specs/2026-10-15-argocd-design.md](superpowers/specs/2026-10-15-argocd-design.md).

## Read access to GitHub

Read access is one deploy key per environment, made once: its private half is `~/.ssh/gke-genai-serving-argocd-<env>` on
this Mac only, its public half is on GitHub as a read-only deploy key. `./bootstrap` puts it straight into a Kubernetes
Secret, never into git, Terraform or Helm. If the key is missing, `./bootstrap` stops and prints the two commands that
make and register it.

## The Argo CD screen

Open it with `./k <env> -n argocd port-forward svc/argocd-server 8081:443`, then http://localhost:8081, user
`admin`. The password, copied to the clipboard without showing it:

```
./k main -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | pbcopy
```

## Changing an app

Each Argo CD deploys what is on its own branch on GitHub, not what is in this folder. Change the file
on a short-lived branch, run `./check`, push, and open a pull request into `main`; merging it deploys to main within
about 3 minutes (Refresh in Argo CD's screen makes it look now). A pull request from `main` into `production` then
deploys to production. Pods whose settings changed restart, which ends a running port-forward; start it again. To undo
a change, revert it on `main` and promote again. A change made by hand with `./k` is put back within seconds. For an
emergency fix by hand, in Argo CD's screen first switch off automatic sync on `root`, then on the app itself: `root`
keeps the apps' own settings as they are in git, so with `root` still on, the app's sync is switched back on within
seconds and the fix is undone. Afterwards switch `root` back on; that also switches the app's sync back on, from git.

Whoever can merge into a branch can change that environment: its Argo CD applies whatever is there.
