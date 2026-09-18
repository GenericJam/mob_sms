%{
  name: :mob_sms,
  mob_version: "~> 0.9",
  plugin_spec_version: 1,
  # Package description lives in mix.exs (that's what Hex publishes and what
  # `mix hex.info mob_sms` shows). The plugin manifest schema does not accept
  # a top-level :description key today — cf. mob_dev's Manifest.@known_keys.
  # A sample screen the host can navigate to by route (auto-listed by a home
  # that enumerates Mob.Plugins.screens/0). Pure-Elixir + hot-pushable; drop
  # it and this entry in a real app that builds its own UI.
  screens: [
    %{module: MobSms.DemoScreen, default_route: "/mob_sms/demo"}
  ],
  nifs: [
    # iOS: Objective-C NIF presenting MFMessageComposeViewController. lang:
    # :objc → compiled with -fobjc-arc. platform: :ios so it isn't pulled
    # into the Android build.
    %{module: :mob_sms_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to the platform Intent.ACTION_SENDTO via the
    # Kotlin MobSmsBridge (Activity-based). platform: :android so iOS skips
    # it.
    %{module: :mob_sms_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  # NO permissions capability entry: the composer flow shows no runtime
  # permission dialog on either platform. The user must tap Send inside the
  # system messaging app for anything to actually go out, so no SEND_SMS
  # permission is needed on Android and no entitlement is needed on iOS.
  #
  # NO Android <queries> block either. Android 11+ package-visibility rules
  # gate PackageManager.resolveActivity / queryIntentActivities but NOT
  # startActivity itself for well-known intents like ACTION_SENDTO. The
  # bridge catches ActivityNotFoundException as the "no SMS app installed"
  # signal and delivers :not_available.
  android: %{
    bridge_kt: "priv/native/android/MobSmsBridge.kt",
    bridge_class: "io.mob.sms.MobSmsBridge",
    permissions: []
  },
  ios: %{
    # MessageUI is the framework that ships MFMessageComposeViewController.
    frameworks: ["MessageUI"],
    plist_keys: %{}
  }
}
