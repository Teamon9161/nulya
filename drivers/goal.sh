#!/bin/sh
# `/goal` — the first nulya driver, and the first consumer of `--pin`. It pins the
# bundled `handoff` tool into a new session and steps it one step at a time; when
# the model proposes a handover (a file under .nulya/handoffs/<session>-*.md) it
# forks through the bundled `compact` tool and carries on in the child: the model
# proposes, the driver decides. Nothing here parses JSON.
#
# STDOUT is control and only control — `session`, `handoff`, `done`, `evaluate` —
# so a front end can drive tabs off it; STDERR is the step's own `--stream` lines
# passed through verbatim, so a spawner sees token deltas live with no sidecar and
# no kernel change. Guards, verdicts and concurrent goals are future driver policy.
set -e
N=${NULYA:-nulya}
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
profile=''; max=50; href=''; cref=''; goal=''
while [ $# -gt 0 ]; do
  case $1 in
    --profile) profile=$2; shift 2 ;;
    --max-iterations) max=$2; shift 2 ;;
    --handoff) href=$2; shift 2 ;;
    --compact) cref=$2; shift 2 ;;
    --file) goal=$(cat "$2"); shift 2 ;;
    *) goal=$1; shift ;;
  esac
done
[ -n "$goal" ] || { echo "usage: goal.sh [--profile P] [--max-iterations N] [--handoff <id>[@v]] [--compact <id>[@v]] (<goal> | --file <path>)" >&2; exit 2; }
[ -n "$href" ] || href="handoff@$("$N" ext build "$repo/extensions/handoff" | grep -o 'v-[0-9a-f]*' | head -1)"
[ -n "$cref" ] || cref="compact@$("$N" ext build "$repo/extensions/compact" | grep -o 'v-[0-9a-f]*' | head -1)"
set --; if [ -n "$profile" ]; then set -- --profile "$profile"; fi
id=$("$N" session new "$@" --with "$href" --pin "ext:${href%@*}/handoff")
echo "session $id"
"$N" session append "$id" "You have a tool named handoff. Work in phases: the ones this goal names, otherwise
explore, design, implement, verify. When a phase is genuinely finished and the rest
of the work no longer needs the details of how you got there, call handoff once —
what the phase concluded, what the next phase must do, the facts to carry over
verbatim — then end your turn without calling anything else; work continues from
that brief in a fresh context. A goal small enough to simply finish needs none.

Goal:
$goal" >/dev/null
log=.nulya/goal-last-step.jsonl
i=0
while [ "$i" -lt "$max" ]; do
  i=$((i + 1))
  # The step's stdout goes to OUR stderr as it arrives, and to the log so the two
  # signals below can be read back. A failing left side of a pipe is invisible to
  # `set -e`, which is why the error line is checked explicitly.
  "$N" session step "$id" --max-steps 1 --stream | tee "$log" >&2
  if grep -q '"stream":"run","event":"error"' "$log"; then exit 1; fi
  # Disk before log: a handoff ends the turn too, and a proposal must win.
  brief=$(ls ".nulya/handoffs/$id"-*.md 2>/dev/null | head -1)
  if [ -n "$brief" ]; then
    new=$("$N" ext run "$cref" compact --arg session="$id" --arg brief_file="$brief" |
      grep -o '"session":"s-[^"]*' | head -1 | cut -d'"' -f4)
    [ -n "$new" ] || { echo "the handoff was recorded but the fork produced no session" >&2; exit 4; }
    echo "handoff $id -> $new"
    id=$new
    continue
  fi
  if grep -q '"stopped":"end_turn"' "$log"; then
    echo "done $id"
    echo "evaluate: $N session outcome $id <success|partial|failure>"
    exit 0
  fi
done
echo "goal not reached in $max iterations; the conversation is at $id" >&2
exit 3
