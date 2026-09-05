/**
 * The kernel's gate and ACP's `session/request_permission`, which are the same
 * question asked twice.
 *
 * `nulya session step --gate` offers every call before it runs and reads one
 * line back: allow, or deny with a note the model then sees. ACP offers the
 * same call to the editor and reads back one of four options. So the whole of
 * this file is: decide with the policy that already exists (`approvals.ts`),
 * ask only when that policy says a person should be asked, and remember what
 * the person said.
 *
 * `allow_always` / `reject_always` are remembered HERE, per session and in
 * memory. The kernel has one semantic — allow, or deny — and does not know what
 * "always" is; a driver that taught it would be putting policy in the kernel.
 * They are two sets rather than one because a standing "never" must outrank a
 * standing "always", which `judge` already guarantees by reading the deny table
 * first.
 */
import type {
  PermissionOption,
  RequestPermissionRequest,
  RequestPermissionResponse,
  ToolCallUpdate,
} from "@agentclientprotocol/sdk"
import { alwaysKey, describeKey, judge, summarize, type ApprovalRules, type PermissionMode } from "../approvals.ts"
import type { GateRequest, GateVerdict } from "../nulya/cli.ts"

/** One session's permission state: the standing rules, the mode, and what was said here. */
export interface SessionPolicy {
  mode: PermissionMode
  rules: ApprovalRules
  /** `allow_always` keys (`approvals.alwaysKey`). */
  always: Set<string>
  /** `reject_always` keys, read as extra `deny` entries — the same spelling that table matches. */
  never: Set<string>
}

/**
 * The four options, in the order a client lists them. The two `_always` labels
 * name what would be remembered, because `shell` is remembered by its first
 * word: "always allow shell" would be "always allow everything", and a person
 * agreeing to `git` has not agreed to `rm`.
 */
export function permissionOptions(request: GateRequest): PermissionOption[] {
  const key = describeKey(alwaysKey(request))
  return [
    { optionId: "allow_once", name: "Allow once", kind: "allow_once" },
    { optionId: "allow_always", name: `Always allow ${key}`, kind: "allow_always" },
    { optionId: "reject_once", name: "Reject once", kind: "reject_once" },
    { optionId: "reject_always", name: `Always reject ${key}`, kind: "reject_always" },
  ]
}

/** The call as ACP describes one: the id the stream already used, and what it would do. */
function toolCallOf(request: GateRequest): ToolCallUpdate {
  const summary = summarize(request)
  return {
    toolCallId: request.call_id,
    title: summary.length > 0 ? summary : request.tool,
    name: request.tool,
    status: "pending",
    rawInput: parsed(request.args),
  }
}

function parsed(args: string): unknown {
  try {
    return JSON.parse(args)
  } catch {
    return undefined
  }
}

/** Ask the client, or answer from the tables. `ask` is one `session/request_permission`. */
export async function answerGate(
  request: GateRequest,
  sessionId: string,
  policy: SessionPolicy,
  ask: (params: RequestPermissionRequest) => Promise<RequestPermissionResponse>,
): Promise<GateVerdict> {
  // The session's `reject_always` keys join the standing deny table rather than
  // sitting in a third layer: `judge` reads that table first, so a "never" said
  // here outranks an "always" said here, whichever order they were said in.
  const rules: ApprovalRules = { ...policy.rules, deny: [...policy.rules.deny, ...policy.never] }
  const decision = judge(request, { mode: policy.mode, rules, always: policy.always }).decision
  if (decision === "allow") return { allow: true }
  if (decision === "deny") return { allow: false, note: "a standing rule forbids this call" }

  const response = await ask({ sessionId, toolCall: toolCallOf(request), options: permissionOptions(request) })
  const outcome = response.outcome
  // The client cancels the turn instead of answering. The kernel's own
  // cancellation is already on its way (`session/cancel` writes the marker), so
  // this only has to stop THIS call from running.
  if (outcome.outcome !== "selected") return { allow: false, note: "the turn was canceled before this was approved" }

  switch (outcome.optionId) {
    case "allow_always":
      policy.always.add(alwaysKey(request))
      return { allow: true }
    case "allow_once":
      return { allow: true }
    case "reject_always":
      policy.never.add(alwaysKey(request))
      return { allow: false }
    case "reject_once":
      // A bare deny: the model reads it as "somebody said no", which is the
      // whole of what happened. Notes are for the refusals nobody was asked
      // about.
      return { allow: false }
    default:
      // An option this side never offered. Fail closed, and say so — nobody
      // answered the question that was actually asked.
      return { allow: false, note: `the client chose '${outcome.optionId}', which was not offered` }
  }
}
