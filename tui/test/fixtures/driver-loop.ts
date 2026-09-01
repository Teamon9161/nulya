/**
 * A driver script: it decides WHEN a session
 * steps, and nothing else. Stands in for "another terminal running a loop" so
 * that the observer path can be tested unattended.
 *
 *   bun driver-loop.ts <bin> <workspace> <session-id> <stop-file>
 *
 * It holds the writer lease for the duration of each step and drops it between
 * steps — exactly the pattern that makes a single "the lock is free" probe
 * meaningless and take-over a deliberate gesture.
 */
const [bin, dir, id, stopFile] = process.argv.slice(2)
if (!bin || !dir || !id || !stopFile) throw new Error("usage: driver-loop.ts <bin> <workspace> <id> <stop-file>")

let steps = 0
while (!(await Bun.file(stopFile).exists())) {
  const proc = Bun.spawnSync({
    cmd: [bin, "session", "step", id, "--max-steps", "4"],
    cwd: dir,
    env: { ...process.env, NULYA_SCRIPTED_MODE: "finish" },
  })
  steps += 1
  // SessionBusy is a legitimate outcome for a driver script too; it just means
  // somebody took over. Keep looping until told to stop.
  if (steps > 2000) break
  await Bun.sleep(60)
}
process.stdout.write(`driver-loop: ${steps} steps\n`)
