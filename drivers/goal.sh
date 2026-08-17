#!/bin/sh
# `/goal` — the first nulya driver, and the first consumer of `--pin`. It pins the
# bundled `handoff` tool into a new session, steps it one step at a time, and when
# the model proposes a handover (a file under .nulya/handoffs/<session>-*.md) forks
# through the bundled `compact` tool and carries on in the child: model proposes,
# driver decides. Nothing parses JSON — the file IS the proposal, "calls":[] ends a
# turn, one regex lifts the new id (the first one — the child). Rebuilding both
# extensions each run is free. Guards and verdicts are future policy; goal.ps1 mirrors.
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
i=0
while [ "$i" -lt "$max" ]; do
  i=$((i + 1))
  out=$("$N" session step "$id" --max-steps 1)
  # Disk before transcript: a handoff ends the turn too, and a proposal must win.
  brief=$(ls ".nulya/handoffs/$id"-*.md 2>/dev/null | head -1)
  if [ -n "$brief" ]; then
    new=$("$N" ext run "$cref" compact --arg session="$id" --arg brief_file="$brief" |
      grep -o '"session":"s-[^"]*' | head -1 | cut -d'"' -f4)
    [ -n "$new" ] || { echo "the handoff was recorded but the fork produced no session" >&2; exit 4; }
    echo "handoff $id -> $new"
    id=$new
    continue
  fi
  case $out in *'"calls":[]'*)
    echo "done $id"
    echo "evaluate: $N session outcome $id <success|partial|failure>"
    exit 0 ;;
  esac
done
echo "goal not reached in $max iterations; the conversation is at $id" >&2
exit 3
