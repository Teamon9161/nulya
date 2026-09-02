/**
 * `state/envprofile.ts`: the per-exec-target-kind profile
 * that decides which packages ride along as `--with`, which extra tools get
 * render this session's `--prompt`.
 *
 * Pure functions only — no workspace, no kernel — because `App.tsx` reads the
 * exact same `resolveEnvProfile` for both what actually gets composed
 * (`sessionExtras()`) and what the draft screen counts (`plannedFaceTools`),
 * and that claim is what these pin.
 */
import { describe, expect, test } from "bun:test"
import { execTargetKind, resolveEnvProfile, type EnvProfiles } from "../src/state/envprofile.ts"

describe("execTargetKind", () => {
  test("local: absent, empty, or the word itself", () => {
    expect(execTargetKind("")).toBe("local")
    expect(execTargetKind("   ")).toBe("local")
    expect(execTargetKind("local")).toBe("local")
  })

  test("wsl: bare or with a distro", () => {
    expect(execTargetKind("wsl")).toBe("wsl")
    expect(execTargetKind("wsl:Ubuntu")).toBe("wsl")
    expect(execTargetKind("wsl:")).toBe("wsl")
  })

  test("anything unrecognised reads as local — the fuller composition, not the stripped one", () => {
    // `session new` is the one that refuses a bad spelling; this classifier
    // only picks a profile, and the conservative pick costs nothing extra.
    // `ssh:<dest>` used to be its own kind — retired 2026-08-30
    // — and now falls in here with any other
    // spelling `session new` will refuse.
    expect(execTargetKind("docker:box")).toBe("local")
    expect(execTargetKind("ssh")).toBe("local")
    expect(execTargetKind("ssh:box")).toBe("local")
    expect(execTargetKind("ssh:user@host")).toBe("local")
  })

  test("surrounding whitespace does not change the kind", () => {
    expect(execTargetKind("  wsl:Ubuntu  ")).toBe("wsl")
  })

  test("remote: covers the whole family — wsl, ssh, and exec — as one kind", () => {
    expect(execTargetKind("remote:wsl")).toBe("remote")
    expect(execTargetKind("remote:wsl:Ubuntu")).toBe("remote")
    expect(execTargetKind("remote:ssh:box")).toBe("remote")
    expect(execTargetKind("remote:exec:/bin/nulya remote serve")).toBe("remote")
  })
})

describe("resolveEnvProfile: zero-config defaults", () => {
  const session_with = ["handoff", "agent"]
  const session_prompts = ["ground"]
  const no_overrides: EnvProfiles = {}

  test("local is today's behaviour verbatim: not bare, the front end's own lists", () => {
    expect(resolveEnvProfile("local", session_with, session_prompts, no_overrides)).toEqual({
      bare: false,
      with: session_with,
      session_prompts,
    })
  })

  test("wsl composes exactly like local — it shares the host filesystem through /mnt/", () => {
    expect(resolveEnvProfile("wsl", session_with, session_prompts, no_overrides)).toEqual({
      bare: false,
      with: session_with,
      session_prompts,
    })
  })

  test("remote only has shell/workspace: bare, no members, no renderers", () => {
    expect(resolveEnvProfile("remote", session_with, session_prompts, no_overrides)).toEqual({
      bare: true,
      with: [],
      session_prompts: [],
    })
  })
})

describe("resolveEnvProfile: field-level override", () => {
  const session_with = ["handoff", "agent"]
  const session_prompts = ["ground"]

  test("a field written in tui.toml replaces the default outright", () => {
    const overrides: EnvProfiles = { remote: { with: ["ops"] } }
    const profile = resolveEnvProfile("remote", session_with, session_prompts, overrides)
    expect(profile.with).toEqual(["ops"])
    // The fields NOT written keep the kind's own default — `bare` stays true
    // for remote and `session_prompts` stays empty, because only one field was
    // mentioned.
    expect(profile.bare).toBe(true)
    expect(profile.session_prompts).toEqual([])
  })

  test("bare can be turned off for remote without touching its other fields", () => {
    const profile = resolveEnvProfile("remote", session_with, session_prompts, { remote: { bare: false } })
    expect(profile.bare).toBe(false)
    expect(profile.with).toEqual([])
  })

  test("local can be narrowed to fewer members without becoming bare", () => {
    const profile = resolveEnvProfile("local", session_with, session_prompts, { local: { with: ["agent"] } })
    expect(profile.with).toEqual(["agent"])
    expect(profile.bare).toBe(false)
  })

  test("a member may carry its own tool selection, and that is the only tool key", () => {
    const profile = resolveEnvProfile("remote", session_with, session_prompts, {
      remote: { with: ["std:read"], session_prompts: ["ground"] },
    })
    expect(profile.with).toEqual(["std:read"])
    expect(profile.session_prompts).toEqual(["ground"])
  })

  test("an empty override table for a kind is exactly its default", () => {
    expect(resolveEnvProfile("wsl", session_with, session_prompts, { wsl: {} })).toEqual(
      resolveEnvProfile("wsl", session_with, session_prompts, {}),
    )
  })

  test("a table for one kind never leaks into another", () => {
    const overrides: EnvProfiles = { remote: { with: ["ops"], bare: false } }
    expect(resolveEnvProfile("local", session_with, session_prompts, overrides)).toEqual({
      bare: false,
      with: session_with,
      session_prompts,
    })
    expect(resolveEnvProfile("wsl", session_with, session_prompts, overrides)).toEqual({
      bare: false,
      with: session_with,
      session_prompts,
    })
  })

  test("[env.remote] overrides remote alone, same field-level discipline as the other two", () => {
    const profile = resolveEnvProfile("remote", session_with, session_prompts, {
      remote: { bare: false, with: ["agent"] },
    })
    expect(profile.bare).toBe(false)
    expect(profile.with).toEqual(["agent"])
    expect(profile.session_prompts).toEqual([]) // not mentioned, stays remote's default
  })
})
