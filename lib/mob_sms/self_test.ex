defmodule MobSms.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One synchronous, read-only native call: `:mob_sms_nif.sms_available/0`.
  It opens no composer, registers no receiver, sends nothing and needs no
  permission.

    * **iOS** — the Objective-C NIF answers
      `[MFMessageComposeViewController canSendText]`, the same check
      `MobSms.compose/2` makes before presenting the sheet.
    * **Android** — the zig NIF calls `MobSmsBridge.sms_available()` over JNI,
      which answers `TelephonyManager.isSmsCapable` through the Activity the
      plugin bootstrap handed the bridge.

  What each answer maps to:

    * `true` → `:pass`. The NIF is linked and initialised (Android: the
      Kotlin bridge is registered and has its Activity), and this device can
      send SMS, so `compose/2` would present the composer.
    * `false` → `:pass`. The same native path answered; this device has no
      SMS service (the iOS Simulator, an emulator or tablet without
      telephony), so `compose/2` delivers `{:sms, :not_available}`, which is
      the documented behaviour there. Sending needs telephony and a person
      tapping Send, so the composer itself is never the proof.
    * `{:error, :bridge_not_registered}` → fail: `MobSmsBridge.register()`
      never ran or the `sms_available` method-ID lookup failed, so every
      call into the bridge is dead in this host.
    * `{:error, :no_activity}` → fail: the bootstrap never called
      `setActivity`, so `compose/2` and `OneTimeCode.arm/2` would always
      give up.
    * `{:error, :no_jni_env}` / `{:error, :query_failed}` → fail: no JNIEnv
      for the scheduler thread, or the `TelephonyManager` lookup threw, a
      Java exception escaped the bridge or it answered an unknown code.
    * The host stub's `nif_not_loaded` (an `ErlangError`) → fail: the
      native library was not linked into this build.
    * Anything else → fail, naming what came back.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(_ctx) do
    classify(:mob_sms_nif.sms_available())
  rescue
    # Only the host stub's nif_not_loaded means "not linked"; any other raise
    # propagates and the runner counts it as a failure with its real message.
    e in ErlangError ->
      case e do
        %ErlangError{original: :nif_not_loaded} ->
          {:fail,
           "mob_sms_nif is not linked into this build: sms_available/0 raised #{Exception.message(e)}"}

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  @doc false
  # What the native side answered to sms_available/0, as a self-test result.
  @spec classify(term()) :: Mob.Plugin.SelfTest.result()
  def classify(answer) when is_boolean(answer), do: :pass

  def classify({:error, :bridge_not_registered}),
    do:
      {:fail,
       "sms_available/0 returned {:error, :bridge_not_registered}: MobSmsBridge.register() never ran or a method-ID lookup failed"}

  def classify({:error, :no_activity}),
    do:
      {:fail,
       "sms_available/0 returned {:error, :no_activity}: the plugin bootstrap never called MobSmsBridge.setActivity"}

  def classify(other),
    do: {:fail, "sms_available/0 returned #{inspect(other)}, expected true or false"}
end
