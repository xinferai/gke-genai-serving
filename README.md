# Generative AI model serving on Google Kubernetes Engine

A pilot POC project: an open-weight model (`qwen3.5:9b` on Ollama, behind Open WebUI) served on a GPU in Google
Kubernetes Engine, all of it in code: Terraform for the infrastructure, Argo CD for the apps, GitHub for the release
rules. It is a POC, not production: "production" is the name of one of its two environments.

The lab on one page, in diagrams: https://xinferai.github.io/gke-genai-serving/gke-lab-map.html

## What it is

- **The model:** Ollama serves `qwen3.5:9b` on one NVIDIA L4 GPU. Open WebUI is the chat page in front of it, and
  an OpenAI-compatible API. Only Open WebUI can reach Ollama.
- **The GPU:** Spot first, on-demand when Google has no Spot L4 free in the zone.
- **The infrastructure (Terraform):** a VPC with private nodes, a GKE Standard cluster with four node pools (`system`,
  `apps`, `gpu`, `gpu-ondemand`), and a public entrance: a fixed IP, a Google-managed certificate, and Cloud Armor,
  which lets in only the addresses in `access.tfvars`.
- **The apps (Argo CD):** an app of apps installs the chat app and its HTTPS entrance from GitHub, from the branch
  named after the environment.
- **Two environments:** `main` and `production`, in separate GCP projects, the same apart from a few files named after
  the environment.
- **The release rules (GitHub):** no direct pushes; a change reaches production only by pull request from `main`, and
  two required checks guard each one.
- **Paid by the session:** the cluster exists only while in use. The entrance and the disk with accounts and chats stay
  between sessions, at about $15 a month per environment.

## Two environments

| | main | production |
|---|---|---|
| Branch | `main`: testing, collecting changes, the checkpoint | `production`: changes only by pull request from `main` |
| GCP project | `samwen-gke-lab-main` | `samwen-gke-lab` |
| gcloud profile | `gke-lab-main` | `gke-lab` |
| Terraform state | `gs://samwen-gke-lab-main-tfstate` | `gs://samwen-gke-lab-tfstate` |
| Public address | https://chat-lab-main.liveinference.com | https://chat-lab.liveinference.com |

## Running it

Once: copy `access.tfvars.example` to `access.tfvars` (git ignores it) and put your public address in it. Then, for a
session:

```
./startup main      # about 20 minutes: cluster, Argo CD, apps; done when the page answers over HTTPS
./teardown main     # about 12 minutes: the cluster goes; the entrance and the chat data stay
./check             # offline checks for both environments; run before every push
```

Each command takes the environment first (`main`, `production`, or for `./startup` and `./teardown`, `both`).
`./startup` and `./teardown` first check that you are signed in to Google Cloud, that your address is in
`access.tfvars` and that the deploy keys are in place; if not, they stop before changing anything and list the commands
that fix it. The other commands, `./tf`, `./k`, `./h`, `./bootstrap` and `./hotfix`, are in
[docs/operations.md](docs/operations.md).

## How a change ships

A short-lived branch off `main` → pull request into `main` → test on the main environment → pull request from `main`
into `production`, merged with a merge commit → production. Urgent fixes go the same way; `./hotfix` walks through
one. The rules and the steps: [docs/release-process.md](docs/release-process.md).

## Documentation

| Document | What it covers |
|---|---|
| [docs/operations.md](docs/operations.md) | the commands, who may connect, the start and end of a session |
| [docs/release-process.md](docs/release-process.md) | branches and promotion, the required checks, an urgent fix step by step |
| [docs/architecture.md](docs/architecture.md) | node pools, the model's GPU, the public HTTPS entrance |
| [docs/argocd.md](docs/argocd.md) | installing Argo CD, its access to GitHub, its screen, changing an app |
| [docs/chat-app.md](docs/chat-app.md) | the chat page, the kept chat data, calling the model from code, freeing the GPU |
| [docs/repository-map.md](docs/repository-map.md) | every file and folder, and what it is for |
| [docs/gke-lab-map.html](https://xinferai.github.io/gke-genai-serving/gke-lab-map.html) | the lab in diagrams, its costs, the AWS equivalents |
| [docs/superpowers/](docs/superpowers/) | the designs (`specs/`) and the build plans that carried them out (`plans/`) |
| [notes.md](notes.md) | lab notes: the why behind each choice |

## License

MIT: [LICENSE](LICENSE).
