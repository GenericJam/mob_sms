# mob_sms — Agent Instructions

You're in **mob_sms**, a Mob plugin that opens the user's default SMS app pre-filled with a recipient + body. Cross-platform surface (`MobSms.compose/2`), NIF + Kotlin bridge per platform, thin Elixir wrapper. Modeled on `mob_biometric` structurally; consult that repo when you need a reference for the NIF pattern or the plugin manifest shape.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view: the mob three-repo topology, the plugin manifest schema, `Mob.Composite` / `Mob.Sigil`, how to drive a running app from your session, and the cross-cutting pre-empt-failure rules. This file is mob_sms-specific.

> **Keep this file current.** When you change composer behaviour, add a new prop, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_sms is, in one paragraph

A small plugin whose only surface is `MobSms.compose(socket, to: ..., body: ...)`. On iOS it presents `MFMessageComposeViewController` (MessageUI framework) as a sheet inside the app; the delegate reports `:sent | :cancelled | :failed`. On Android it fires `Intent.ACTION_SENDTO` with `smsto:` to hand the user off to their default SMS app; the platform hands back no reliable outcome so the plugin delivers `:composer_opened` and stops there. Both platforms deliver `:not_available` when the device cannot send SMS. No permissions on either platform — the user must tap Send inside the OS composer for anything to go out, which is exactly why nothing needs granting.

## What mob_sms is NOT

- **Not silent-send.** iOS has no public API. Android has `SmsManager.sendTextMessage` under `SEND_SMS`, but Google Play rejects that permission for most non-SMS-centric apps. If a user comes back with a real reason, a separate `MobSms.send/2` can land later, gated on the Android runtime permission.
- **Not iMessage-aware.** On iOS the composer will use iMessage if the recipient is on it; the plugin doesn't know or care, and the delegate result is the same regardless.
- **Not a share sheet.** `UIActivityViewController` / `Intent.ACTION_SEND` is a different animal; that belongs in `mob_share` if we build it.

## The per-platform delivery asymmetry

This is the most important thing to know when working here.

| iOS | Android |
|---|---|
| Sheet inside your app | Hand-off to a separate SMS app |
| Delegate observes outcome | Outcome unobservable |
| `:sent` / `:cancelled` / `:failed` | `:composer_opened` |
| MessageUI framework | Intent resolver + user's SMS app |

Do not try to paper over this. It is by design at the platform layer, not a mob_sms limitation. Any API change that fabricates a `:sent` on Android is wrong; Android's `startActivityForResult` on `ACTION_SENDTO` returns `RESULT_CANCELED` reliably enough to look like "cancelled" from a naive callsite but says nothing about whether the user actually tapped Send inside the SMS app.

## Relationship to `mob_wake` and `mob_push`

- `mob_sms` = *outbound* messaging via the user's default SMS app. Composer-only. This plugin.
- `mob_push` (in progress) = *outbound* silent APNs / FCM data messages. Server-side send + on-device receive. Not related to SMS.
- `mob_wake` (planned; MOB-257 epic) = *inbound* wake events for the app (OS scheduler firings + silent-push receive). Not related to SMS.

No overlap. Do not entangle the identifier-based dispatch shape mob_wake uses with this plugin's simpler direct-call shape.

## Anatomy of the plugin

- `lib/mob_sms.ex` — public API. Just `compose/2`; keeps the surface small on purpose.
- `lib/mob_sms/demo_screen.ex` — a ready-to-run screen exercising the compose flow. Auto-listed in a host that enumerates `Mob.Plugins.screens/0`. Delete this and the manifest entry in a real app.
- `priv/mob_plugin.exs` — plugin manifest. Declares MessageUI on iOS, no permissions on either platform, no Android manifest queries (see `MobSmsBridge.kt` comments).
- `priv/native/ios/mob_sms_nif.m` — ObjC NIF presenting MFMessageComposeViewController, delegate lifecycle managed via a static retention array (the compose flow is single-user, so at most one active delegate at a time). Walks the connected-scene / window hierarchy to find the top VC to present from.
- `priv/native/android/MobSmsBridge.kt` — Kotlin bridge, `Intent.ACTION_SENDTO`, catches `ActivityNotFoundException` as the "no SMS-capable app" signal.
- `priv/native/jni/mob_sms_nif.zig` — Zig NIF exporting the `Java_io_mob_sms_MobSmsBridge_nativeRegister` + `_nativeDeliverSms` symbols, cache bridge jclass + method id at `nativeRegister` time, invoke `sms_compose(pid, to, body)` from the Elixir side. Mirrors `mob_biometric_nif.zig` structurally.

## Testing

Elixir suite:

```bash
mix deps.get
MIX_ENV=test mix test
```

Coverage:

- Plugin manifest loads + validates via `MobDev.Plugin.{Manifest, Validator}`.
- Manifest tier classification (tier 3 because of the demo screen; tier 1 for the NIF).
- Cross-platform NIF declaration shape.
- No permission capability, no Android manifest permission, no plist keys.
- `MobSms.compose/2` argument normalisation (integer opts coerce; nil `:to` becomes empty binary; socket returns unchanged).

The Elixir surface is intentionally thin — arg normalisation and one NIF call. On-device verification is the real gate; do not add "feature" tests that rely on native code executing.

## Physical-device verification is not optional

Every substantive change here needs a screenshot on **both** iOS and Android, deployed from an app that includes this plugin. Simulators do not tell you the truth for the composer flow:

- iOS Simulator: `canSendText` reports `NO`, so you always get `:not_available`. Cannot see the composer sheet in the sim.
- Android emulator: no default SMS app installed, so the intent resolves to nothing and you always get `:not_available`. Cannot see the SMS app hand-off in the emulator.

The verification loop:

1. Generate or use a host app that pins this plugin (`mob_sms` in `mix.exs`, `config :mob, :plugins, [:mob_sms]` in `mob.exs`). If none exists, spin up a `mob_sms_verify` scratchpad app the way MOB-246 spun up `mob-mishka-verify`.
2. Deploy to physical Moto G Power (Android 11) + physical iPhone (iOS 16+): `mix mob.deploy --native --all-physical` from that app.
3. Navigate to `MobSms.DemoScreen` (auto-listed if the host enumerates `Mob.Plugins.screens/0`) and tap the "Compose invite" button — iOS shows the sheet, Android hands off to the SMS app.
4. Screenshot the sheet on iOS and the SMS app hand-off on Android.
5. Actually type or don't type in the composer; assert the `handle_info` result the demo screen shows. On iOS, exercise both Send and Cancel — verify `:sent` and `:cancelled` both arrive. On Android, verify `:composer_opened` arrives immediately after the SMS app is up.

Kevin's memory has a `mishka_verify` / `mob-mishka-verify` throwaway app pattern used during the MOB-246 epic. A `mob_sms_verify` app spun up the same way is the verification harness for this plugin.

## Worktrees

**Default assumption: work happens in a git worktree.** Kevin runs multiple agents in parallel; each task in its own worktree prevents conflicts.

If a task is assigned to you and worktree usage isn't mentioned, ask:

> "Should I use a worktree for this?"

Yes for anything non-trivial or that touches native code. In-place is fine for a single-file doc edit, one-line config change, or a version bump.

```bash
cd ~/code/mob_sms
git worktree add ../mob_sms-worktrees/<slug> -b <branch>
cd ../mob_sms-worktrees/<slug>
```

Git stash stack is shared — never bare `git stash` / `git stash pop`. Prefer a temporary WIP commit; if you must stash, use `git stash push -u -m "<unique-tag>"`, capture the SHA via `git stash list --format='%H %gs'`, restore with `git stash apply <sha>`, drop by tag after.

## Pre-commit checklist

Before committing, run all in this order:

```bash
mix test                            # full suite must pass
mix format                          # apply formatting
mix credo --strict                  # whole tree, includes ExSlop
```

Pre-push hook (`.githooks/pre-push`) adds format + credo strict + fast tests on every push. Activate once:

```bash
git config core.hooksPath .githooks
```

### Tests are part of the change

New behaviour ships with a test unless the change is small enough that a test would only restate it. The bar is: **would this test fail if the fix were reverted?** Check by reverting it.

### Decision log — check both directions

Before committing, ask two questions (the log itself is described under "Decision log" below):

**Does this need a new record?** Anything non-obvious: a tradeoff, a workaround, a convention. The commit message explaining a decision means that decision belongs in `decisions/` where it's findable.

**Does this INVALIDATE an existing record?** More dangerous half. A record asserting a property the code no longer has is worse than no record. Grep `decisions/` for the mechanism you are changing before you commit, and act on what you find — see "Decision log" below for how; never quietly delete a record.

## Adversarial review — before every non-trivial commit

Spawn a subagent, point it at `git diff <base>..HEAD`, tell it to find defects rather than approve. Act on findings, then commit.

Especially important for this plugin:

- The iOS delegate retention lifecycle. `MobSmsDelegate` is retained in `g_activeDelegates` at present-time and released in `didFinishWithResult` after dismissal. Any change to that lifecycle can leak the delegate or double-free it. Review carefully.
- The Android bridge's Activity reference. `WeakReference<Activity>` can be null; the bridge must deliver `:not_available` rather than crash if the reference has been GC'd. Any Activity reference change wants a review.
- The NIF pid round-trip. `pidToJlong` / `pidFromLong` handle 32-bit vs 64-bit ErlNifPid sizes; changing that reaches into ABI territory.

Skip only for: formatting, a typo, a version bump, a changelog edit.

## Before the merge — a second review, on the PR

Same as mob_mishka. Give the reviewer the PR, what it claims, what you're least sure of, and ask for MERGE / DO NOT MERGE with reasons.

**Mechanical preconditions you check yourself:**

- CI is green AND the run is newer than the last commit.
- The branch is not behind master.
- The `mob` floor pin is a version that actually exists on Hex.

## Release flow

Canonical process lives in [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). mob_sms specifics:

- `mix.exs` `@version` is the source of truth and the trigger. Bump, commit, push to master — `.github/workflows/release.yml` detects the mix.exs change and tags / GH-releases / hex-publishes, each step idempotent.
- Every release must state the mob version it needs and pin its `mob` dep accordingly. This plugin's floor is `~> 0.9` because the plugin-manifest schema landed with mob 0.9.0 (MOB-247).
- The `mob` floor pin is load-bearing. Do not bump if the plugin uses a new mob feature that hasn't shipped yet.
- **Never ship without physical-device verification.** Simulators lie for this plugin — iOS Simulator's `canSendText` returns `NO`, Android emulators have no default SMS app.
- **Ships as a real Hex package.** Docs shipped in the same `mix hex.publish` call.
- **Review gate is on by default** (see mob/RELEASE.md § "Review gate"). Everything that landed since the last published version gets a code review before you publish. Skip only if the user says so.

## Decision log

Non-obvious decisions — tradeoffs, workarounds, conventions, "why we chose X over Y" — go in `decisions/`, one file per decision:

```
decisions/YYYY-MM-DD-short-slug.md
```

Each file is a lightweight ADR (`## Context / ## Decision / ## Consequences`). Append new files; never rewrite existing ones. If a decision changes, add a new file and mark the old `Status: superseded by <file>`. One file per decision keeps the log conflict-free across parallel worktrees. The one in-place edit besides that status line: a record that asserts something about the code that was never or is no longer true gets corrected in place with a note about what was wrong — don't quietly delete it.

Existing calls worth ADRing when they get revisited:

- Android SENDTO vs foreground SmsManager. Ship composer-only for 0.1, revisit if a user has a real need for silent send.
- No `<queries>` block. Package-visibility rules gate `resolveActivity`, not `startActivity` — the bridge relies on that.
- Delegate retention array vs per-call NSObject with `objc_setAssociatedObject`. The array is simpler and the compose flow is single-user; not worth changing unless a bug shows up.

## Issue tracking

Status lives in **Linear** (team `MOB`), the single board across mob, mob_dev, mob_new, mob_mishka, mob_wake, mob_sms. Short version:

- **Linear (`MOB`)** — live status, one issue per thread.
- **`decisions/`** — durable rationale. Link from the issue; don't copy.
- **PRs / git** — the code. Reference the issue id in branch, PR title, commits.

`LINEAR_API_KEY` in `~/code/mob/.env`. Team `MOB` uuid = `07dd0939-c66d-44f2-8da5-e3a4a243e953`. No Linear MCP; raw GraphQL endpoint (curl example in mob/AGENTS.md).

## Connecting an IEx session to a running Mob app

Full guide at `~/code/mob/AGENTS.md` § "Connecting an IEx session". Short version, from a host app that depends on this plugin:

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
