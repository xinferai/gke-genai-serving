# Repository map

Every file and folder, with what it is for. `./check` fails if a file or folder is missing here, two levels down.

```text
gke-genai-serving/
├── README.md                 the overview: what the lab is, how to run it, where the details are
├── notes.md                  lab notes: the why behind each choice, session by session
├── LICENSE                   MIT
├── .gitignore                keeps state, saved plans, cluster credentials, logs and access.tfvars out of git (list
│                             at the bottom)
├── access.tfvars.example     who may connect: copy to access.tfvars and put your public address in it
│
│   ── Commands (each takes the environment first: main, production, or for startup and teardown, both) ──
├── startup                   bring an environment up, from nothing to the page answering over HTTPS
├── teardown                  take its cluster down; the entrance and the chat-data disk stay
├── hotfix                    an urgent fix for production, step by step (release-process.md; takes no environment)
├── tf                        Terraform for one environment and one layer; changes only from that environment's branch
├── k                         kubectl for that environment's cluster
├── h                         Helm, same cluster
├── bootstrap                 install Argo CD on a new cluster; Argo CD then installs everything else
├── check                     offline checks for both environments (takes no environment); run before every push
├── lib/
│   ├── env.sh                the environment word → its gcloud profile and its own kubeconfig (every command but check)
│   ├── preflight.sh          startup and teardown's checks before anything changes: sign-ins, plugin, address, keys
│   └── session.sh            startup and teardown's shared part: fresh clone, steps, timing, both side by side
│
│   ── Terraform: the infrastructure ──
├── modules/                  the building blocks, shared by both environments
│   ├── network/              VPC, subnet, Cloud Router and Cloud NAT (the private nodes' way out)
│   ├── gke-cluster/          the GKE Standard cluster: private nodes, control plane reachable from one IP only
│   ├── node-pool/            one node pool (≈ an EKS managed node group): machine, Spot or not, GPU, taints
│   ├── platform/             one environment's cluster: network, cluster, the nodes' service account, and the
│   │                           pools system, apps, gpu and gpu-ondemand
│   └── edge/                 what outlives the cluster: IP address, certificate, Cloud Armor, the chat-data disk
├── envs/                     the four Terraform roots, one state each
│   ├── main/
│   │   ├── cluster/          main's cluster: built by ./startup, destroyed by ./teardown
│   │   └── edge/             main's entrance and chat-data disk: kept
│   └── production/
│       ├── cluster/          the same, for production
│       └── edge/             the same, plus moved.tf (moved its first resources, of 2026-10-14, into the module)
│       (in each root: main.tf calls the module; terraform.tfvars holds this environment's values;
│        versions.tf pins the providers and says where the state lives in Cloud Storage;
│        .terraform.lock.hcl locks the provider versions)
│
│   ── Kubernetes: what runs on the clusters (Argo CD applies it from GitHub) ──
├── apps/chat/
│   ├── values.yaml           Open WebUI and Ollama (Helm values): models, the GPU's compute class, the kept disk's
│   │                           volume, NetworkPolicy, API key limits; the same in both environments
│   ├── env/                  main.yaml and production.yaml: only what differs (page address, the disk's project)
│   └── edge/                 the public entrance's in-cluster half
│       ├── base/edge.yaml    Gateway (it makes the load balancer), routes, HTTP → HTTPS, health check, Cloud Armor
│       └── main/, production/  each environment's hostname, patched onto base
├── argocd/
│   ├── values.yaml           Argo CD's own settings (installed by ./bootstrap, on the system pool)
│   ├── base/root/            the root app: keeps the environment's list of apps running (app of apps)
│   ├── base/apps/            the two apps: chat (the Helm chart) and chat-edge (the entrance)
│   ├── main/                 main's root app and apps: branch main, main's settings, main's entrance
│   └── production/           the same, for production
│
│   ── GitHub ──
├── .github/workflows/
│   └── into-production.yml   the two required checks on a pull request into production: source-allowed
│                               (it comes from main) and source-has-production
│
│   ── Tests (./check runs them all, offline, against stand-ins) ──
├── test/
│   ├── checks/               ./check's areas: 10 Terraform, 20 chat app, 30 entrance, 40 Argo CD,
│   │                           50 scripts (shellcheck and the tests below), 60 GitHub, 70 the README and docs
│   ├── wrappers_test.sh      tf, k and h: the environment word, the profile, the branch guard
│   ├── bootstrap_test.sh     bootstrap: order, environment, deploy key
│   ├── startup_teardown_test.sh  startup and teardown: steps, fresh clone, stops, both side by side
│   ├── hotfix_test.sh        hotfix: both paths, against a stand-in GitHub that really merges
│   ├── workflow_test.sh      the promotion checks and the urgent-fix git steps, on scratch histories
│   └── expected/             known-good lists: production's chat settings, production's entrance resources
│
│   ── Documents ──
└── docs/
    ├── .nojekyll             tells GitHub Pages to serve this folder as it is (without it, Jekyll rewrites the plans)
    ├── operations.md         the commands in detail, who may connect, the start and end of a session
    ├── release-process.md    branches and promotion, the required checks, an urgent fix step by step
    ├── architecture.md       node pools, the model's GPU, the public HTTPS entrance
    ├── argocd.md             installing Argo CD, its access to GitHub, its screen, changing an app
    ├── chat-app.md           the chat page, the kept chat data, calling the model from code, freeing the GPU
    ├── repository-map.md     this map
    ├── gke-lab-map.html      diagrams of the lab, its costs, the AWS equivalents
    └── superpowers/          designs (specs/) and the build plans that carried them out (plans/)

Ignored by git, on this machine only:
  .terraform/   each root's provider downloads         tfplan*   saved plans, with their .commit stamps
  .kube/<env>/  each cluster's kubeconfig              .logs/    the logs of ./startup both and ./teardown both
  access.tfvars who may connect (your public address)
```
