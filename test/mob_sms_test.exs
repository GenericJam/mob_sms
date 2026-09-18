defmodule MobSmsTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 3 (NIF + a demo screen)", %{manifest: m} do
      # Same shape as mob_biometric: capability NIF is tier 1, the bundled
      # demo screen lifts it to 3 (Manifest.tier reports the highest section).
      assert Manifest.tier(m) == 3
    end

    test "passes the full pre-publish validator (paths, NIF modules)",
         %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_sms_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_sms_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "registers NO permission capability (composer flow needs none)",
         %{manifest: m} do
      # No runtime permission dialog on either platform — the user must tap
      # Send inside the OS composer for anything to actually go out. So no
      # capability entry, no Android manifest permission, no iOS entitlement.
      assert Map.get(m, :permissions, []) == []
      assert m.android.permissions == []
    end

    test "Android bridge_class matches the Kotlin bridge's canonical name",
         %{manifest: m} do
      assert m.android.bridge_class == "io.mob.sms.MobSmsBridge"
      assert m.android.bridge_kt == "priv/native/android/MobSmsBridge.kt"
    end

    test "iOS declares the MessageUI framework (MFMessageComposeViewController)",
         %{manifest: m} do
      assert "MessageUI" in m.ios.frameworks
    end

    test "ships the demo screen as its default route", %{manifest: m} do
      assert [%{module: MobSms.DemoScreen, default_route: "/mob_sms/demo"}] = m.screens
    end
  end

  describe "MobSms.normalize_opts/1" do
    # The unit-testable half of compose/2, split out so the coercion is
    # observable without the NIF loaded. compose/2 itself is fire-and-forget
    # against a NIF that needs a device — those integration paths are pinned
    # by the mob_sms_verify physical-device harness, not by this suite.
    #
    # 0.1.1's tests wrapped this coercion inside assert_raise ErlangError,
    # which fired on the missing NIF rather than on the coercion. Deleting
    # the `|> to_string()` calls from compose/2 didn't fail the suite. This
    # rewrite actually observes normalize_opts's output so a regression to
    # the coercion is caught.

    test "coerces :to and :body strings through unchanged" do
      assert MobSms.normalize_opts(to: "+15551234567", body: "hi") ==
               {"+15551234567", "hi"}
    end

    test "coerces integer :to to a string (the common caller-writes-a-number shape)" do
      assert MobSms.normalize_opts(to: 15_551_234_567, body: "ping") ==
               {"15551234567", "ping"}
    end

    test "coerces atom :body via String.Chars (:hello → \"hello\")" do
      assert MobSms.normalize_opts(to: "+15551234567", body: :hello) ==
               {"+15551234567", "hello"}
    end

    test "empty binaries for missing :to and :body" do
      # An empty :to opens the composer with an empty recipient field (the
      # user picks from Contacts); an empty :body opens with no pre-filled
      # text. Both are legitimate uses of the plugin.
      assert MobSms.normalize_opts([]) == {"", ""}
    end

    test "propagates String.Chars-undefined values as a real Protocol.UndefinedError" do
      # Passing a bare map has no String.Chars implementation; to_string/1
      # raises Protocol.UndefinedError. The surface intentionally does not
      # swallow this — callers get the real error at the call site instead
      # of a confusing NIF-level crash on the wire.
      assert_raise Protocol.UndefinedError, fn ->
        MobSms.normalize_opts(to: %{}, body: "x")
      end
    end
  end
end
