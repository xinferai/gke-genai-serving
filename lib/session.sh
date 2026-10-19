# shellcheck shell=bash
# Shared by ./startup and ./teardown. The caller sets $here, sources lib/env.sh, and defines
# <command>_one <env> <copy>: the command's steps for one environment, run in <copy>.
#
# Both commands work from a fresh copy of GitHub's branch for each environment: a clone of the
# repository in a temporary folder, on the branch named after the environment, removed at the end.
# What comes up or goes is decided by what is on that branch, whatever this checkout holds (only these
# commands themselves run from here), and the copy's own ./tf allows changing commands in it: it is on
# the environment's branch, clean, and identical to GitHub's copy. The one file brought in from here is
# access.tfvars, who may connect, which git ignores and GitHub never holds. Before any of that, the
# checks in lib/preflight.sh: sign-ins, keys and this Mac's address, with the commands for what is missing.

# shellcheck source=lib/preflight.sh
. "$here/lib/preflight.sh"

# took <seconds>: "12m 15s".
took() { printf '%dm %02ds' $(($1 / 60)) $(($1 % 60)); }

# envs_for <word>: the environments a word names; anything else is a usage error (status 2).
envs_for() {
  case "${1:-}" in
    main | production) echo "$1" ;;
    both) echo "main production" ;;
    *)
      echo "The first word must be main, production or both (got '${1:-}')." >&2
      return 2
      ;;
  esac
}

# say <text>: a line of the run's progress. In a side-by-side run (side_env set) it also goes to the
# terminal (fd 3), after the environment's name, so the terminal shows both runs' steps as they happen;
# everything else (Terraform's output and the like) stays in the run's log.
say() {
  printf '%s\n' "$1"
  [ -z "${side_env:-}" ] || printf '%-11s %s\n' "$side_env" "$1" >&3
}

# step "<what>" <command...>: one step of an environment's run. Prints when it starts (time since the
# run began) and how long it took, or that it failed; the times also go into the run's summary.
step() {
  local what="$1" start=$SECONDS
  shift
  echo
  say "[$(took $((SECONDS - run_start)))] $what"
  if "$@"; then
    say "  ok, $(took $((SECONDS - start)))"
    done_steps+=("$(printf '%8s  %s' "$(took $((SECONDS - start)))" "$what")")
    return 0
  fi
  say "FAILED: $what, after $(took $((SECONDS - start)))"
  return 1
}

# poll <waits> <command...>: runs the command until it succeeds, waiting 15 seconds between tries, at
# most <waits> times (<waits> x 15 seconds in all). Status 2 from the command means stop trying now.
poll() {
  local waits="$1" i=0 status
  shift
  while :; do
    "$@"
    status=$?
    if [ "$status" -eq 0 ] || [ "$status" -eq 2 ] || [ "$i" -ge "$waits" ]; then return "$status"; fi
    i=$((i + 1))
    sleep 15
  done
}

# one_env <command> <env> <copy>: the command's steps for one environment, then a summary of each
# step's time. Run in a subshell: it sets the environment's gcloud profile.
one_env() {
  local cmd="$1" env="$2" copy="$3" run_start=$SECONDS status=0
  done_steps=()
  use_env "$env"
  echo "$cmd $env: from a fresh copy of GitHub's $env, at $(git -C "$copy" log -1 --format='%h (%s)')"
  "${cmd}_one" "$env" "$copy" || status=$?
  echo
  if [ "$status" -eq 0 ]; then
    say "$cmd $env: done in $(took $((SECONDS - run_start)))"
  else
    say "$cmd $env: FAILED after $(took $((SECONDS - run_start)))"
  fi
  [ "${#done_steps[@]}" -eq 0 ] || printf '%s\n' "${done_steps[@]}"
  return "$status"
}

# indent: its input, each line two spaces in.
indent() { sed "s/^/  /"; }

tmp_base() { local t="${TMPDIR:-/tmp}"; echo "${t%/}"; }
# remove_copies: on the way out. A copy goes only once no run can still be using it: any run still
# going is stopped first (Ctrl-C), and waited for.
remove_copies() {
  local pid dir
  for pid in ${pids[@]+"${pids[@]}"}; do
    if kill -0 "$pid" 2> /dev/null; then
      kill -INT -- "-$pid" 2> /dev/null
      wait_for "$pid"
    fi
  done
  for dir in ${copies[@]+"${copies[@]}"}; do
    [ -z "$dir" ] || rm -rf "$dir"
  done
}

# run_command <command> <envs...>: clones GitHub's repository once for each environment, on that
# environment's branch, and runs the command's steps: one environment here, in the terminal; two side
# by side, each writing its own log in .logs/, then a line on how each ended. Exits 1 if any failed.
run_command() {
  local cmd="$1" i url
  shift
  envs=("$@")
  url="$(git -C "$here" remote get-url origin)" || exit 1
  # Who may connect is not on GitHub: each copy gets this checkout's access.tfvars (see ./tf).
  [ -s "$here/access.tfvars" ] || {
    echo "No access.tfvars here. Copy access.tfvars.example to access.tfvars and put your public address in it." >&2
    exit 1
  }
  preflight "$cmd" "${envs[@]}" || exit 1
  copies=()
  pids=()
  trap remove_copies EXIT
  for i in "${!envs[@]}"; do
    copies[i]="$(mktemp -d "$(tmp_base)/gke-lab-${envs[i]}.XXXXXX")" &&
      git clone --quiet --branch "${envs[i]}" "$url" "${copies[i]}/gke-lab" || {
      echo "Could not clone GitHub's ${envs[i]} from $url." >&2
      exit 1
    }
    cp "$here/access.tfvars" "${copies[i]}/gke-lab/"
  done
  if [ "${#envs[@]}" -eq 1 ]; then
    # Ctrl-C reaches everything in the run itself. A signal to this script alone (TERM, or HUP from a
    # closed terminal) ends it only once the run has ended: bash runs a trap after the command in front
    # of it finishes, so the copy cannot go from under a running Terraform.
    trap 'exit 129' HUP
    trap 'exit 143' TERM
    (one_env "$cmd" "${envs[0]}" "${copies[0]}/gke-lab") || exit 1
    exit 0
  fi
  side_by_side "$cmd"
}

# side_by_side <command>: each environment's run in the background, in its own process group (set -m).
# Ctrl-C, and a closed terminal (HUP), then reach only this script, which passes Ctrl-C on to everything
# in both runs and waits for them to stop. (Without set -m, bash makes background commands ignore
# Ctrl-C, and the waits would carry on.) The runs cannot ask for anything at the terminal: a run that
# tried would be stopped, so git is told not to ask for a GitHub login, and fails instead.
# Each run writes its whole output to its log, and its progress lines (say) to the terminal too, through
# fd 3. Each run is reported as soon as it ends, whichever ends first.
side_by_side() {
  local cmd="$1" i stamp failed=0 logs=() pending still
  stamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$here/.logs"
  trap stop_all INT TERM HUP PIPE
  export GIT_TERMINAL_PROMPT=0
  set -m
  for i in "${!envs[@]}"; do
    [ -z "${stopping:-}" ] || break
    logs[i]="$here/.logs/$cmd-${envs[i]}-$stamp.log"
    (side_env="${envs[i]}" one_env "$cmd" "${envs[i]}" "${copies[i]}/gke-lab") 3>&1 > "${logs[i]}" 2>&1 < /dev/null &
    pids[i]=$!
    echo "${envs[i]}: started; its log is ${logs[i]}"
  done
  echo "To follow both in full: tail -f $here/.logs/$cmd-*-$stamp.log"
  pending=("${!pids[@]}")
  while [ "${#pending[@]}" -gt 0 ]; do
    still=()
    for i in "${pending[@]}"; do
      if kill -0 "${pids[i]}" 2> /dev/null; then
        still+=("$i")
      else
        wait_for "${pids[i]}"
        report "$cmd" "${envs[i]}" "${logs[i]}" "$?" || failed=1
      fi
    done
    pending=(${still[@]+"${still[@]}"})
    # The real sleep, not one a test puts on the PATH: this only paces the look at which run has ended.
    [ "${#pending[@]}" -eq 0 ] || /bin/sleep 1
  done
  [ "$failed" -eq 0 ] && [ -z "${stopping:-}" ] || exit 1
}
# stop_all: passes Ctrl-C on to both runs, once. Terraform stops cleanly on the first; a second would
# make it stop at once, perhaps leaving its state locked.
stop_all() {
  local pid
  if [ -n "${stopping:-}" ]; then
    echo "Still waiting for both runs to stop." >&2
    return
  fi
  stopping=1
  echo "Stopping both runs where they are (Terraform stops cleanly; run the command again to finish)." >&2
  for pid in ${pids[@]+"${pids[@]}"}; do kill -INT -- "-$pid" 2> /dev/null; done
}
# wait_for <pid>: its exit status. A trapped signal ends a wait early, and a stopped run ends every
# wait at once, so wait until it is really gone, without spinning.
wait_for() {
  while kill -0 "$1" 2> /dev/null; do
    wait "$1" 2> /dev/null
    if kill -0 "$1" 2> /dev/null; then sleep 1; fi
  done
  wait "$1" 2> /dev/null
}
# report <command> <env> <log> <status>: one line on how the environment's run ended.
report() {
  local failed_step
  if [ "$4" -eq 0 ]; then
    echo "$2: $(sed -n "s/^$1 $2: \(done in .*\)/\1/p" "$3" | tail -1)  (log: $3)"
    return 0
  fi
  failed_step="$(sed -n 's/^FAILED: \(.*\), after .*/\1/p' "$3" | tail -1)"
  if [ -z "$failed_step" ]; then
    echo "$2: FAILED, stopped part-way  (log: $3)"
    return 1
  fi
  echo "$2: FAILED at \"$failed_step\"  (log: $3). Its last lines:"
  grep -B 6 '^FAILED: ' "$3" | sed 's/^/    /'
  return 1
}
