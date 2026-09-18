# Changelog

All notable changes to `mob_sms` are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - unreleased

Initial release. Cross-platform SMS composer plugin.

### Added

- `MobSms.compose/2` — opens the system SMS composer pre-filled with the given `:to` and `:body`. Async result delivered as `{:sms, atom}` to the calling process.
- iOS: `MFMessageComposeViewController` presented from the top VC, delegate reports `:sent | :cancelled | :failed`.
- Android: `Intent.ACTION_SENDTO` with `smsto:` hands off to the user's default SMS app, delivers `:composer_opened` (Android cannot observe the send outcome).
- Both platforms deliver `:not_available` when the device cannot send SMS (simulator on iOS; no SMS-capable app on Android).
- `MobSms.DemoScreen` — a ready-to-run screen exercising the composer flow, auto-listed by the host's plugin home if it enumerates `Mob.Plugins.screens/0`.
- Plugin manifest declares the MessageUI framework on iOS and no permissions on either platform.
