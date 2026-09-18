# Changelog

All notable changes to `mob_sms` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

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
- Rework the "not silent-send" section of `MobSms`'s @moduledoc and the same section in README.md so ex_doc's function-link resolver isn't asked to resolve `MobSms.send/2` — a hypothetical future silent-send API, not something that ships. Removes a `mix docs` warning; the deferred-until-a-user-asks stance on silent send is unchanged.

## [0.1.0] - 2026-09-18

Initial release. Cross-platform SMS composer plugin.

### Added

- `MobSms.compose/2` — opens the system SMS composer pre-filled with the given `:to` and `:body`. Async result delivered as `{:sms, atom}` to the calling process.
- iOS: `MFMessageComposeViewController` presented from the top VC, delegate reports `:sent | :cancelled | :failed`.
- Android: `Intent.ACTION_SENDTO` with `smsto:` hands off to the user's default SMS app, delivers `:composer_opened` (Android cannot observe the send outcome).
- Both platforms deliver `:not_available` when the device cannot send SMS (simulator on iOS; no SMS-capable app on Android).
- `MobSms.DemoScreen` — a ready-to-run screen exercising the composer flow, auto-listed by the host's plugin home if it enumerates `Mob.Plugins.screens/0`.
- Plugin manifest declares the MessageUI framework on iOS and no permissions on either platform.
