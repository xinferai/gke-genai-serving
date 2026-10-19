# How it is built

Terraform builds each environment in two parts with different lifetimes: `cluster` (network, the private GKE
Standard cluster and its node pools), made at the start of a session and removed at the end, and `edge` (the public
entrance and the chat data disk), kept between sessions. Argo CD then installs the apps on the cluster from GitHub
([argocd.md](argocd.md)). Which file does what: [repository-map.md](repository-map.md).

## Node pools

The same in both environments: `system` (cluster add-ons and Argo CD, on-demand, 1–2 nodes), `apps` (tenant workloads,
the chat page among them; on-demand, 0–3, tainted `workload=apps:NoSchedule`), `gpu` and `gpu-ondemand` (one NVIDIA L4
per node, 0–1 each, tainted by GKE with `nvidia.com/gpu`; Spot and on-demand, see "The model's GPU" below). `apps` was
Spot until 2026-10-16, when Google took its machine back and had no Spot e2-standard-2 left in the zone
(`ZONE_RESOURCE_POOL_EXHAUSTED`): the page answered "unconditional drop overload" until a machine could come back.
On-demand machines are not taken back, and with the cluster up only during a session they cost a few cents more an hour.
If the GPU is lost, only the answers stop; the page stays up.

## The model's GPU

Ollama asks for the compute class `gpu-l4` (in `apps/chat/values.yaml`), not for a node pool. The class tries the pool
`gpu` first, on Spot (about $0.42 an hour for the node), and when Google has no Spot L4 free in the zone
(`ZONE_RESOURCE_POOL_EXHAUSTED`), the cluster autoscaler goes straight on to `gpu-ondemand` (about $0.71 an hour).
Both pools are the same machine and scale from zero, and each project's quota allows one GPU at a time, Spot or not,
so only one of them ever has a node. On 2026-10-16, before the fallback, main's model never started: Google took its
Spot L4 back twice within five minutes, then had none.

If Google takes the Spot node back mid-session (about 30 seconds' notice), Ollama comes back on whichever pool can
get a machine, Spot first, in a few minutes; the model stays on its disk, so nothing downloads again. Once on
`gpu-ondemand` it stays there until `./teardown`, and the next `./startup` tries Spot first again. Moving back to
Spot mid-session (`activeMigration` in the class) is off: GKE starts the new node before stopping the old one, which
takes two GPUs. With a quota of 2 GPUs (a free request to Google), it could be turned on.

If neither pool can get a machine, the Ollama pod stays `Pending`; `./startup`'s wait names it with the autoscaler's
warning, and so does `./k <env> -n chat describe pod -l app.kubernetes.io/name=ollama`.

## Public HTTPS

The page and its API, behind Cloud Armor (only `allowed_cidrs` in `access.tfvars` get through;
everyone else gets a 403 at Google's edge) and a Google-managed certificate. Sign-up is off. Ollama stays internal.

Two halves with different lifetimes, per environment:
- `envs/<env>/edge` (Terraform, kept between sessions): the fixed IP, the certificate and its DNS check, the
  certificate map, the Cloud Armor policy, all named `chat-lab` in the environment's project. Its `dns_records` output
  lists the two records in the liveinference.com zone in Route 53 (AWS profile `xinfer.ai`): an A record to the IP,
  and a CNAME Google uses to issue and renew the certificate. It also keeps the chat data disk `chat-data` (see
  [chat-app.md](chat-app.md#the-chat-data)).
- `apps/chat/edge/<env>` (Kubernetes, comes and goes with the cluster): a Kustomize overlay that adds the
  environment's hostname to the shared `apps/chat/edge/base` (the Gateway, which GKE turns into the load balancer, the
  routes, the load balancer's health check and the Cloud Armor attachment). Argo CD applies it as the app
  `chat-edge`. The load balancer takes about 5 to 10 minutes to start answering.
