# Changelog

All notable changes to `mob_sms` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.2.1] - 2026-09-18

### ⚠ Consumer action required
If you copied the 0.2.0 OTP example from `README.md` or `MobSms.OneTimeCode`'s @moduledoc, your `<TextField>` currently reads `on_change={:code}` (bare atom). Mob's renderer silently drops that form, so no `handle_info({:change, :code, value}, _)` clause ever fires — the field fills visually from iOS QuickType or Android SMS Retriever, but your `assign` doesn't run. Change it to `on_change={{self(), :code}}` (a `{pid, tag}` tuple).

### Fixed
- **Demo screen `on_change` wiring**: `MobSms.DemoScreen`'s OTP `<TextField>` used the same wrong bare-atom form as the docs. Fixed to `on_change={{self(), :code}}`. Verified end-to-end on physical iPhone SE (iOS QuickType) and Moto G Power 5G 2024 (Android SMS Retriever) after the fix.
- **Regression test**: source-level assertion in `MobSms.DemoScreenTest` walks `demo_screen.ex` and fails if any `on_change=` or `on_tap=` binding is a bare atom rather than a `{pid, tag}` tuple. This exact bug is what slipped through 0.2.0's publish; the test pins the form so it can't silently regress.

### Docs
- **README + `MobSms.OneTimeCode` @moduledoc**: `on_change={:code}` → `on_change={{self(), :code}}` in the usage examples so the pattern the docs teach is one that actually fires. Same correction applied to `MobSms.DemoScreen`'s @moduledoc and inline comment.

## [0.2.0] - 2026-09-18

### Added
- **`MobSms.OneTimeCode.arm(socket, on_receive: tag)`** — cross-platform SMS-delivered OTP autofill. Both platforms deliver the code as `{:change, tag, code}` (same shape a text field's `on_change` fires), so one `handle_info` clause covers iOS QuickType autofill AND Android's SMS Retriever. Pass the SAME atom as your text field's `on_change` tag.
  - **iOS**: no-op at the Elixir layer. Autofill is driven by the new `text_content_type: :one_time_code` prop on `<TextField>` (added in mob 0.9.1). iOS Messages parses the incoming SMS, surfaces the code as a QuickType suggestion above the keyboard, user taps to fill. Code flows in via the field's normal `on_change`. No entitlement, no framework, no server-side hash.
  - **Android**: registers a scoped BroadcastReceiver (only Google Play Services can broadcast to it, via the `com.google.android.gms.auth.api.phone.permission.SEND` gate) and calls `SmsRetrieverClient.startSmsRetriever()`. Delivery lands via a short-lived Elixir proxy process that translates the raw `{:sms_otp, code}` into `{:change, tag, code}` and forwards to the caller. No `READ_SMS` permission, no Play Store review gate.
  - **Sad path**: on Android, `{:sms_otp, :timeout}` fires on 5-min retriever timeout, GMS start failure, or eviction by a subsequent `arm/2`. Optional handler — a retype prompt is a fine default.
  - Server-side SMS format for Android: body + blank line + 11-char hash suffix. Full spec + `AppSignatureHelper` snippet for computing the hash in `MobSms.OneTimeCode`'s @moduledoc.
- Demo screen now exercises the OTP flow alongside the composer.

### Changed
- **mob floor bumped to `~> 0.9.1`.** The OTP flow's iOS half needs the `text_content_type` prop, added in that release. Bump generated apps accordingly.
- Plugin manifest declares `com.google.android.gms:play-services-auth-api-phone:18.0.2` as a `gradle_deps` contribution. Present on 99%+ of Play-installed devices; aftermarket ROMs without Google Play Services fall straight to `{:sms_otp, :timeout}` from `arm/2`.

### Fixed (0.2.0 review pass, before publish)
- **Kotlin bridge**: re-arm evicts the previous receiver AND delivers `{:sms_otp, :timeout}` to the prior caller instead of leaving it hanging. Idempotency guard on `onReceive` (compare receiver identity, not just presence) prevents double-delivery on queued-post-unregister edge. `startSmsRetriever` wrapped in `try/catch` for the synchronous-throw path GMS-absent devices sometimes take.
- **Kotlin regex**: `extractCode` now prefers the LAST 4–8-digit run in the SMS body proper (stripping the 11-char hash suffix first). Previous `.find(body)` behaviour returned the first digit run — "MyApp2024 code is 123456" would deliver "2024" instead of "123456".
- **Zig NIF**: `sendSmsOtp` handles the `enif_make_new_binary` OOM path.

## [0.1.2] - 2026-09-18

### Fixed
- **iOS: use-after-free crash on overlapping composes** (adversarial review of 0.1.1 caught this). `MobSmsDelegate`'s `release_active` called `removeAllObjects` on the retention array — if two composes overlapped, the first one to finish dropped every strong ref, including the still-active second delegate. UIKit then delivered `didFinishWithResult:` on a dangling pointer. Now takes the finishing delegate and calls `removeObject:` so overlapping composes each survive to their own callback. Reproduction: fire `MobSms.compose/2` twice from a screen without waiting for the first `{:sms, _}` message; the second sheet's Send/Cancel crashed the app.
- **iOS: top-VC walk now bails when the top VC is mid-transition.** Presenting on a VC whose `isBeingDismissed` or `isBeingPresented` is set silently no-ops in UIKit and the delegate never fires, leaving the caller waiting forever for a `{:sms, _}`. The plugin now returns `:not_available` in that state.
- **Android: JVM-teardown and never-registered-bridge paths delivered no result to the caller.** `callBridgeCompose`'s `get_jenv` and null-bridge-class branches previously returned `:error` without sending `{:sms, :not_available}` — the caller waited forever. Both branches now honour the "one message per compose" contract.

### Docs
- Comment on `sms_str_from_iolist` (iOS NIF) explains the correct-but-double-negate `!enif_inspect_binary && !enif_inspect_iolist_as_binary` guard so a future reader doesn't "clean it up" into the wrong semantics.

### Tests
- `MobSms.compose/2`'s argument-coercion path is now split into `MobSms.normalize_opts/1`, a testable helper. The previous tests wrapped the coercion inside `assert_raise ErlangError`, which fired on the missing NIF instead of on the coercion — deleting the `|> to_string()` calls did not fail the suite. The rewritten tests observe `normalize_opts/1`'s output directly, so a regression to the coercion is caught. Also asserts `Protocol.UndefinedError` propagates for values with no `String.Chars` impl (rather than being swallowed).

## [0.1.1] - 2026-09-18

### Docs
- Rework the "not silent-send" section of `MobSms`'s @moduledoc and the same section in README.md so ex_doc's function-link resolver isn't asked to resolve a hypothetical future `send/2` on this module. Removes a `mix docs` warning; the deferred-until-a-user-asks stance on silent send is unchanged.

## [0.1.0] - 2026-09-18

Initial release. Cross-platform SMS composer plugin.

### Added

- `MobSms.compose/2` — opens the system SMS composer pre-filled with the given `:to` and `:body`. Async result delivered as `{:sms, atom}` to the calling process.
- iOS: `MFMessageComposeViewController` presented from the top VC, delegate reports `:sent | :cancelled | :failed`.
- Android: `Intent.ACTION_SENDTO` with `smsto:` hands off to the user's default SMS app, delivers `:composer_opened` (Android cannot observe the send outcome).
- Both platforms deliver `:not_available` when the device cannot send SMS (simulator on iOS; no SMS-capable app on Android).
- `MobSms.DemoScreen` — a ready-to-run screen exercising the composer flow, auto-listed by the host's plugin home if it enumerates `Mob.Plugins.screens/0`.
- Plugin manifest declares the MessageUI framework on iOS and no permissions on either platform.
