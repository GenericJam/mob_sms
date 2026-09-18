defmodule MobSms.OneTimeCodeTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("../..", __DIR__)

  describe "plugin manifest — 0.2.0 OTP additions" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "still passes the pre-publish validator with the Play Services gradle dep",
         %{manifest: m} do
      # The dep string doesn't invalidate the manifest — the validator gates
      # on paths + NIF modules, not on gradle dep identifiers. This test
      # exists so a future validator change that DOES parse deps trips here
      # (rather than silently rejecting the plugin at build time).
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the Play Services SMS Retriever gradle dep", %{manifest: m} do
      # The exact coordinate + version matters. Google renames dep artifacts
      # once every few years (see the androidx migration); pinning here
      # catches an accidental "upgrade" that breaks the retriever call.
      assert "com.google.android.gms:play-services-auth-api-phone:18.0.2" in m.android.gradle_deps
    end

    test "requires mob 0.9.1 or newer (text_content_type prop on TextField)",
         %{manifest: m} do
      # mob 0.9.1 shipped `text_content_type: :one_time_code` on :text_field.
      # The OTP flow's iOS half depends on that prop; older mob versions
      # would silently ignore the prop and QuickType autofill wouldn't fire.
      assert m.mob_version == "~> 0.9.1"
    end
  end

  describe "MobSms.OneTimeCode.arm/2 with the NIF unavailable" do
    # NIF is Android-only. On host + iOS the NIF is not loaded and the
    # spawned proxy catches nif_not_loaded and exits, so the caller sees
    # no delivery and no error — the same call site works cross-platform.

    test "returns the socket unchanged when the NIF is not loaded" do
      # The proxy's nif_error(:nif_not_loaded) catch collapses it before
      # any delivery. arm/2 itself returns the input socket synchronously.
      socket = %Mob.Socket{}
      assert MobSms.OneTimeCode.arm(socket, on_receive: :code) == socket
    end

    test "accepts opts without validating unknown keys" do
      # Keyword surface is deliberately lenient — extra opts are accepted
      # so future additions (e.g. per-tag proxy timeout, code-format
      # override) are non-breaking.
      assert MobSms.OneTimeCode.arm(%Mob.Socket{}) == %Mob.Socket{}

      assert MobSms.OneTimeCode.arm(%Mob.Socket{}, on_receive: :verification) ==
               %Mob.Socket{}
    end

    test "does not deliver anything when the NIF is unloaded (host / iOS)" do
      # Contract: on iOS the proxy catches nif_not_loaded and exits —
      # nothing lands on the caller. Assert no rogue message shows up.
      MobSms.OneTimeCode.arm(%Mob.Socket{}, on_receive: :code)
      refute_receive {:change, :code, _}, 200
      refute_receive {:sms_otp, _}, 200
    end
  end
end
