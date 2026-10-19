# The chat app

Open WebUI (a chat page, on `apps`) talking to Ollama (the model server, on an L4 GPU), with one Qwen model that stays
loaded on the GPU all the time: `qwen3.5:9b`, the default, which also runs the page's background jobs (titles, tags,
follow-up suggestions). The settings shared by both environments are in `apps/chat/values.yaml` (Open WebUI's
environment variables under `commonEnvVars`); each environment's own are in `apps/chat/env/<env>.yaml` (`WEBUI_URL`,
and `dataDisk.project`, the project of its data disk). The page takes them from there on every start. Reach it
through a port-forward, or publicly over HTTPS ([architecture.md](architecture.md#public-https)).

## Opening the page

```
./k main -n argocd get applications -w     # root, chat, chat-edge: wait for Synced and Healthy
./k main -n chat get pods -o wide -w       # watch the GPU node appear and the models download
./k main -n chat port-forward svc/chat-open-webui 8080:80
```

Then open http://localhost:8080. The first account created there, on a new data disk, becomes the admin; sign-up is off
for everyone after that. The first start downloads the model (6.6 GB) onto the Ollama disk, loads it into GPU memory,
sends it a warm-up question, and checks that it is 100% on the GPU (if not, the container restarts instead of running on
the CPU). The Ollama pod stays in `ContainerCreating` until all of that is done, a few minutes on the first start.
Thinking is off by default, so answers start right away.

## The chat data

Accounts, passwords, chats and API keys live in Open WebUI's database on the disk `chat-data` (10 GB), which Terraform
keeps with the entrance in `envs/<env>/edge`, so they outlive the cluster: `./teardown` leaves the disk, and the next
`./startup` brings the page up on it again. In the cluster the disk is the PersistentVolume `chat-data`
(`apps/chat/values.yaml`, under `extraResources`; the project is `dataDisk.project` in `apps/chat/env/<env>.yaml`). It
names the disk and is set to `Retain`, so deleting the volume never deletes the disk; the AWS equivalent is an EBS
volume made outside the EKS cluster and attached by its ID. The disk is in the cluster's zone, since a zonal disk
attaches only to nodes there (`./check` compares the two `zone` settings), and it has `prevent_destroy`: a plan that
would delete or replace it fails instead. The 40 GB model disk still comes and goes with the cluster, so each
`./startup` downloads the model again.

## Calling the model from code

Calling the model from code, two ways, both OpenAI-compatible:
- Through Open WebUI, with a key from Settings > Account > API keys (keys may call only `/api/models` and
  `/api/chat/completions`): `http://localhost:8080/api/chat/completions` with `Authorization: Bearer <key>`.
  Thinking is off by default here.
- Straight to Ollama, which has no authentication and is reachable only inside the cluster:
  `./k main -n chat port-forward svc/chat-ollama 11435:11434`, then `http://localhost:11435/v1/chat/completions`.
  Thinking is on by default here; send `"reasoning_effort": "none"` to turn it off.

## Who may reach Ollama

Only Open WebUI may reach Ollama (a NetworkPolicy in `values.yaml`, installed with the chart). To see it work, call
Ollama from Open WebUI and from a throwaway pod; the first answers, the second times out:

```
./k main -n chat exec chat-open-webui-0 -c open-webui -- curl -s -m 5 http://chat-ollama:11434/api/version
./k main -n chat run probe --rm -i --restart=Never --image=curlimages/curl -- curl -s -m 5 http://chat-ollama:11434/api/version
```

## Freeing the GPU

To free one environment's GPU without removing anything, add this to `apps/chat/env/<env>.yaml` (the setting is
`ollama.replicaCount`; nested one level deeper, under `ollama.ollama`, it would be silently ignored), then merge it
through the usual pull requests:

```
ollama:
  replicaCount: 0
```

The autoscaler removes the empty GPU node about 10 minutes later. Taking the lines out again brings it back, and the
model is still on its disk. Scaling by hand with `./k` no longer works: Argo CD puts it back.
