# mob_sms — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view. Together they cover the plugin anatomy, the per-platform delivery asymmetry (iOS reports outcome, Android doesn't), the physical-device verification discipline, and the mob three-repo topology. This file goes deeper on Claude Code-specific workflow detail.

> **Keep AGENTS.md up to date** when you change composer behaviour, add a new prop, or hit a new gotcha. Out-of-date guidance there causes wrong decisions downstream — fix it in the same commit, not in a follow-up.

## What this repo is

A small Mob plugin — one public function (`MobSms.compose/2`), an ObjC NIF wrapping `MFMessageComposeViewController`, a Zig NIF + Kotlin bridge wrapping `Intent.ACTION_SENDTO`. No permissions on either platform. Modeled on `mob_biometric` structurally; consult that repo when you need a reference for the NIF pattern or the plugin manifest shape.

## Worktrees

**Default assumption: work happens in a git worktree.** Kevin runs multiple agents in parallel; each task in its own worktree prevents conflicts.

If a task is assigned to you and worktree usage isn't mentioned, ask:

> "Should I use a worktree for this?"

Yes for anything non-trivial or that touches native code. In-place is fine for a single-file doc edit, one-line config change, or a version bump.

The git stash stack is shared across worktrees — never bare `git stash` / `git stash pop`.

## Pre-commit checklist

Before committing, run all in this order:

```bash
mix test                            # full suite must pass
mix format                          # apply formatting
mix credo --strict                  # whole tree, includes ExSlop
```

Pre-push hook adds format + credo strict + fast tests on every push. Activate once:

```bash
git config core.hooksPath .githooks
```

### Tests are part of the change

New behaviour ships with a test unless the change is small enough that a test would only restate it. The bar is: **would this test fail if the fix were reverted?** Check by reverting it.

### Decision log — check both directions

Before committing, ask two questions:

**Does this need a new record?** Anything non-obvious: a tradeoff, a workaround, a convention. The commit message explaining a decision means that decision belongs in `decisions/` where it's findable.

**Does this INVALIDATE an existing record?** More dangerous half. A record asserting a property the code no longer has is worse than no record. Grep `decisions/` for the mechanism you are changing before you commit. Correct in place with a note about what was wrong, don't quietly delete.

### Adversarial review — before every non-trivial commit

Spawn a subagent, point it at the diff, tell it to find defects rather than approve.

Especially for this plugin:

- **iOS delegate retention.** `MobSmsDelegate` is retained in a static array at present-time and released after `didFinishWithResult` runs. Any lifecycle change here can leak the delegate or double-free it.
- **Android Activity WeakReference.** Can be null; the bridge delivers `:not_available` rather than crash if the reference has been GC'd.
- **NIF pid round-trip.** `pidToJlong` / `pidFromLong` handle 32-bit vs 64-bit `ErlNifPid` sizes; changing that reaches into ABI territory.

Skip only for: formatting, a typo, a version bump, a changelog edit.

### Before the merge — a second review, on the PR

Same as mob_mishka. Give the reviewer the PR, what it claims, what you're least sure of, and ask for MERGE / DO NOT MERGE with reasons.

**Mechanical preconditions you check yourself:**

- CI is green AND the run is newer than the last commit.
- The branch is not behind master.
- The `mob` floor pin is a version that actually exists on Hex.

## Release flow

Canonical process in [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). mob_sms specifics:

- `@version` in `mix.exs` is the trigger. Push it to master, `.github/workflows/release.yml` handles tag / GH-release / hex-publish, each step idempotent.
- The `mob` floor pin is load-bearing. Do not bump if the plugin uses a new mob feature that hasn't shipped yet.
- **Never ship without physical-device verification.** Simulators lie for this plugin — iOS Simulator's `canSendText` returns `NO`, Android emulators have no default SMS app.

## Physical-device verification loop

Simulators return `:not_available` on both platforms; they cannot exercise the composer flow. Loop:

1. Have a host app that pins this plugin as a dep. If none exists, spin up a `mob_sms_verify` scratchpad app the way MOB-246 spun up `mob-mishka-verify`.
2. `mix mob.deploy --native --all-physical` from that app.
3. Navigate to `MobSms.DemoScreen` (auto-listed if the host enumerates `Mob.Plugins.screens/0`).
4. Tap "Compose invite" — iOS shows the sheet, Android hands off to the SMS app.
5. Screenshot both.
6. On iOS, exercise Send and Cancel — verify `:sent` and `:cancelled` both arrive.
7. On Android, verify `:composer_opened` arrives immediately after the SMS app is up.

## Issue tracking

Status lives in **Linear** (team `MOB`), one board across mob + mob_dev + mob_new + mob_mishka + mob_wake + mob_sms.

- Linear (`MOB`): live status, one issue per thread.
- `decisions/`: durable rationale.
- PRs / git: the code. Reference the issue id in branch, PR title, commits.

`LINEAR_API_KEY` in `~/code/mob/.env`. Team uuid = `07dd0939-c66d-44f2-8da5-e3a4a243e953`. No Linear MCP; raw GraphQL.

## Connecting an IEx session to a running Mob app

Full guide at `~/code/mob/CLAUDE.md` § "Connecting an IEx session". Short version, from a host app that depends on this plugin:

```bash
cd /path/to/host_app
mix mob.connect              # sets up tunnels, IEx attached to all devices
```

Then from any Mac-side IEx:

```elixir
node = :"host_app_ios@127.0.0.1"      # or ..._android_<suffix>
Node.connect(node)
:rpc.call(node, GenServer, :call, [:mob_screen, :get_current_module])
:rpc.call(node, Process, :send, [:mob_screen, {:tap, :compose}, []])
:rpc.call(node, :mob_nif, :screenshot, [:png, 90, 1.0])
```

Beats `xcrun simctl` / `adb shell input tap` for anything state-related.

## Decision log

Non-obvious decisions go in `decisions/YYYY-MM-DD-short-slug.md` as a lightweight ADR (`## Context / ## Decision / ## Consequences`). Append-only.
