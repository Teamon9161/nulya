/**
 * `state/envprofile.ts` (tui.md §11 T88): the per-exec-target-kind profile
 * that decides which packages ride along as `--with`, which extra tools get
 * `--pin`ned, and which packages render this session's `--prompt`.
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

  test("ssh: always has a destination", () => {
    expect(execTargetKind("ssh:box")).toBe("ssh")
    expect(execTargetKind("ssh:user@host")).toBe("ssh")
  })

  test("anything unrecognised reads as local — the fuller composition, not the stripped one", () => {
    // `session new` is the one that refuses a bad spelling; this classifier
    // only picks a profile, and the conservative pick costs nothing extra.
    expect(execTargetKind("docker:box")).toBe("local")
    expect(execTargetKind("ssh")).toBe("local")
  })

  test("surrounding whitespace does not change the kind", () => {
    expect(execTargetKind("  wsl:Ubuntu  ")).toBe("wsl")
  })
})

describe("resolveEnvProfile: zero-config defaults", () => {
  const session_with = ["handoff", "agent"]
  const session_prompts = ["ground"]
  const no_overrides: EnvProfiles = {}

  test("local is today's behaviour verbatim: not bare, the front end's own lists, no extra pins", () => {
    expect(resolveEnvProfile("local", session_with, session_prompts, no_overrides)).toEqual({
      bare: false,
      with: session_with,
      pins: [],
      session_prompts,
    })
  })

  test("wsl composes exactly like local — it shares the host filesystem through /mnt/", () => {
    expect(resolveEnvProfile("wsl", session_with, session_prompts, no_overrides)).toEqual({
      bare: false,
      with: session_with,
      pins: [],
      session_prompts,
    })
  })

  test("ssh only has shell: bare, no members, no renderers, no extra pins", () => {
    expect(resolveEnvProfile("ssh", session_with, session_prompts, no_overrides)).toEqual({
      bare: true,
      with: [],
      pins: [],
      session_prompts: [],
    })
  })
})

describe("resolveEnvProfile: field-level override", () => {
  const session_with = ["handoff", "agent"]
  const session_prompts = ["ground"]

  test("a field written in tui.toml replaces the default outright", () => {
    const overrides: EnvProfiles = { ssh: { with: ["ops"] } }
    const profile = resolveEnvProfile("ssh", session_with, session_prompts, overrides)
    expect(profile.with).toEqual(["ops"])
    // The fields NOT written keep the kind's own default — `bare` stays true
    // for ssh, `pins`/`session_prompts` stay empty, because only one field
    // was mentioned.
    expect(profile.bare).toBe(true)
    expect(profile.pins).toEqual([])
    expect(profile.session_prompts).toEqual([])
  })

  test("bare can be turned off for ssh without touching its other fields", () => {
    const profile = resolveEnvProfile("ssh", session_with, session_prompts, { ssh: { bare: false } })
    expect(profile.bare).toBe(false)
    expect(profile.with).toEqual([])
  })

  test("local can be narrowed to fewer members without becoming bare", () => {
    const profile = resolveEnvProfile("local", session_with, session_prompts, { local: { with: ["agent"] } })
    expect(profile.with).toEqual(["agent"])
    expect(profile.bare).toBe(false)
  })

  test("pins is additive tool ids, not a replacement for with — both apply at once", () => {
    const profile = resolveEnvProfile("ssh", session_with, session_prompts, {
      ssh: { pins: ["ext:std/read"], session_prompts: ["ground"] },
    })
    expect(profile.pins).toEqual(["ext:std/read"])
    expect(profile.session_prompts).toEqual(["ground"])
    expect(profile.with).toEqual([]) // not mentioned, still the ssh default
  })

  test("an empty override table for a kind is exactly its default", () => {
    expect(resolveEnvProfile("wsl", session_with, session_prompts, { wsl: {} })).toEqual(
      resolveEnvProfile("wsl", session_with, session_prompts, {}),
    )
  })

  test("a table for one kind never leaks into another", () => {
    const overrides: EnvProfiles = { ssh: { with: ["ops"], bare: false } }
    expect(resolveEnvProfile("local", session_with, session_prompts, overrides)).toEqual({
      bare: false,
      with: session_with,
      pins: [],
      session_prompts,
    })
    expect(resolveEnvProfile("wsl", session_with, session_prompts, overrides)).toEqual({
      bare: false,
      with: session_with,
      pins: [],
      session_prompts,
    })
  })
})
