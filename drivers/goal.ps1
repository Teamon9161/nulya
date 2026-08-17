# `/goal` — the first nulya driver, and the first consumer of `--pin`. It pins the
# bundled `handoff` tool into a new session, steps it one step at a time, and when
# the model proposes a handover (a file under .nulya/handoffs/<session>-*.md) forks
# through the bundled `compact` tool and carries on in the child: model proposes,
# driver decides. Nothing parses JSON — the file IS the proposal, "calls":[] ends a
# turn, one regex lifts the new id (the first one — the child). Rebuilding both
# extensions each run is free. Guards and verdicts are future policy; goal.sh mirrors.
$ErrorActionPreference = 'Stop'
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
$i = 0
while ($i -lt $max) {
    $i++
    $out = (& $N session step $id --max-steps 1) -join "`n"
    # Disk before transcript: a handoff ends the turn too, and a proposal must win.
    $brief = Get-ChildItem ".nulya/handoffs/$id-*.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($brief) {
        $new = [regex]::Match(((& $N ext run $cref compact --arg "session=$id" --arg "brief_file=$($brief.FullName)") -join "`n"),
            '"session":"(s-[^"]+)"').Groups[1].Value
        if (-not $new) { [Console]::Error.WriteLine('the handoff was recorded but the fork produced no session'); exit 4 }
        Write-Output "handoff $id -> $new"
        $id = $new
        continue
    }
    if ($out -match '"calls":\[\]') {
        Write-Output "done $id"
        Write-Output "evaluate: $N session outcome $id <success|partial|failure>"
        exit 0
    }
}
[Console]::Error.WriteLine("goal not reached in $max iterations; the conversation is at $id")
exit 3
