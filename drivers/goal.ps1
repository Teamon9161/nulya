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
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) # nulya speaks UTF-8; decode and re-emit it as UTF-8
$N = if ($env:NULYA) { $env:NULYA } else { 'nulya' }
$repo = Split-Path -Parent $PSScriptRoot
$profileName = ''; $max = 50; $href = ''; $cref = ''; $goal = ''
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        '--profile' { $profileName = $args[++$i] }
        '--max-iterations' { $max = [int]$args[++$i] }
        '--handoff' { $href = $args[++$i] }
        '--compact' { $cref = $args[++$i] }
        '--file' { $goal = (Get-Content -Raw $args[++$i]) }
        default { $goal = $args[$i] }
    }
}
if (-not $goal) { [Console]::Error.WriteLine('usage: goal.ps1 [--profile P] [--max-iterations N] [--handoff <id>[@v]] [--compact <id>[@v]] (<goal> | --file <path>)'); exit 2 }
if (-not $href) { $href = 'handoff@' + [regex]::Match((& $N ext build "$repo/extensions/handoff") -join "`n", 'v-[0-9a-f]+').Value }
if (-not $cref) { $cref = 'compact@' + [regex]::Match((& $N ext build "$repo/extensions/compact") -join "`n", 'v-[0-9a-f]+').Value }
$pargs = @(); if ($profileName) { $pargs = @('--profile', $profileName) }
$id = (& $N session new @pargs --with $href --pin ("ext:" + ($href -replace '@.*$', '') + "/handoff")).Trim(); if (-not $id) { [Console]::Error.WriteLine('session new failed'); exit 1 }
Write-Output "session $id"
& $N session append $id @"
You have a tool named handoff. Work in phases: the ones this goal names, otherwise
explore, design, implement, verify. When a phase is genuinely finished and the rest
of the work no longer needs the details of how you got there, call handoff once —
what the phase concluded, what the next phase must do, the facts to carry over
verbatim — then end your turn without calling anything else; work continues from
that brief in a fresh context. A goal small enough to simply finish needs none.

Goal:
$goal
"@ | Out-Null
$log = ".nulya/scratch/goal-$id.jsonl"; New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null   # per goal run (the root id), so two goals never share it
$i = 0
while ($i -lt $max) {
    $i++
    # Step stdout goes to OUR stderr live and to the log so the checks below can read it back. A failing native command does not throw, hence the explicit error check.
    & $N session step $id --max-steps 1 --stream | Tee-Object -FilePath $log | ForEach-Object { [Console]::Error.WriteLine($_) }
    $streamed = (Get-Content -Raw $log)
    if ($streamed -match '"stream":"run","event":"error"') { exit 1 }
    # Disk before log: a handoff ends the turn too, and a proposal must win.
    $brief = Get-ChildItem ".nulya/handoffs/$id-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($brief) {
        $new = [regex]::Match(((& $N ext run $cref compact --arg "session=$id" --arg "brief_file=$($brief.FullName)") -join "`n"),
            '"session":"(s-[^"]+)"').Groups[1].Value
        if (-not $new) { [Console]::Error.WriteLine('the handoff was recorded but the fork produced no session'); exit 4 }
        Write-Output "handoff $id -> $new"
        $id = $new
        continue
    }
    if ($streamed -match '"stopped":"end_turn"') {
        # A background task may still owe an answer: 0 = one landed (step again to read it), 3 = nothing left to wait for.
        & $N task wait --any --session $id | Out-Null; $w = $LASTEXITCODE; if ($w -eq 0) { continue } elseif ($w -ne 3) { exit 5 }
        Write-Output "done $id"
        Write-Output "evaluate: $N session outcome $id <success|partial|failure>"
        exit 0
    }
}
[Console]::Error.WriteLine("goal not reached in $max iterations; the conversation is at $id")
exit 3
