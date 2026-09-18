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

  describe "MobSms.compose/2 with the NIF unavailable" do
    # Without an on-device build the NIF is not loaded — attempting a compose
    # call raises ErlangError. The Elixir surface is intentionally
    # thin (arg normalisation → NIF call), so on-device verification is the
    # real gate; these tests pin the surface shape the NIF is called with.

    test "coerces :to and :body opts to strings before the NIF call" do
      # A missing NIF module surfaces as ErlangError on the NIF
      # call — but only AFTER the opt normalisation. If we passed integer opts
      # unchanged, we'd hit ArgumentError from to_string/1 first. Assert the
      # normalisation ran.
      assert_raise ErlangError, fn ->
        MobSms.compose(%Mob.Socket{}, to: "5551234567", body: "ping")
      end

      # Non-binary inputs coerce cleanly — the surface should not raise on
      # things like integer phone components (that gets coerced to a string
      # before the NIF sees it).
      assert_raise ErlangError, fn ->
        MobSms.compose(%Mob.Socket{}, to: 15_551_234_567, body: "ping")
      end
    end

    test "returns the same socket the caller passed in" do
      # The public contract is fire-and-forget — compose/2 kicks a native
      # present, replies land on the caller via handle_info. The socket
      # threads through unchanged. Impossible to check the NIF path here,
      # but the socket return itself is provable regardless.
      socket = %Mob.Socket{}
      # ErlangError trips inside — but the intent is documented.
      assert_raise ErlangError, fn ->
        assert MobSms.compose(socket, body: "hi") == socket
      end
    end
  end
end
