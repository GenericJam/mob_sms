defmodule MobSms.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobSms.SelfTest

  @plugin_dir Path.expand("../..", __DIR__)

  describe "run/1" do
    test "on a host with no native library linked it fails, naming the NIF, instead of raising" do
      result = SelfTest.run(%{platform: :android, device: :emulator})

      assert {:fail, reason} = result
      assert reason =~ "mob_sms_nif is not linked"
      assert reason =~ "nif_not_loaded"
      assert Mob.Plugin.SelfTest.result?(result)
    end
  end

  describe "classify/1" do
    test "true and false both pass: either answer came from the native side" do
      # false is a device without SMS service (Simulator, emulator, tablet);
      # the NIF still proved it is linked and the bridge registered.
      for answer <- [true, false] do
        assert SelfTest.classify(answer) == :pass
        assert Mob.Plugin.SelfTest.result?(SelfTest.classify(answer))
      end
    end

    test "an unregistered Kotlin bridge fails" do
      result = SelfTest.classify({:error, :bridge_not_registered})

      assert {:fail, "sms_available/0 returned {:error, :bridge_not_registered}" <> _} = result
      assert Mob.Plugin.SelfTest.result?(result)
    end

    test "a bridge with no Activity fails" do
      result = SelfTest.classify({:error, :no_activity})

      assert {:fail, "sms_available/0 returned {:error, :no_activity}" <> _} = result
      assert Mob.Plugin.SelfTest.result?(result)
    end

    test "other error tuples and unexpected answers fail, naming what came back" do
      for answer <- [{:error, :no_jni_env}, {:error, :query_failed}, :ok, nil, 1] do
        result = SelfTest.classify(answer)

        assert {:fail, reason} = result
        assert reason =~ "sms_available/0 returned #{inspect(answer)}, expected true or false"
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end
  end

  describe "manifest" do
    test "declares the self-test, which passes the validator without a selftest warning" do
      {:ok, m} = Manifest.load(@plugin_dir)

      assert m.selftest == MobSms.SelfTest
      assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
      refute Enum.any?(warnings, &(&1 =~ "selftest"))
    end
  end

  describe "NIF stub agreement" do
    # Every function a native NIF table registers must exist in the .erl stub:
    # loading a library that exports a function the module lacks fails, and a
    # self-test calling a native-only export would hit undef instead.
    @native_tables %{
      "priv/native/jni/mob_sms_nif.zig" => ~S/\.name = "(\w+)", \.arity = (\d+)/,
      "priv/native/ios/mob_sms_nif.m" => ~S/\{"(\w+)", (\d+), nif_\w+, \d+\}/
    }

    for {path, pattern} <- @native_tables do
      # Guards the native tables vs the .erl stub, not app code — VacuousTest can't see that.
      # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
      test "#{path} registers only functions the stub exports, including sms_available/0" do
        source = File.read!(Path.join(@plugin_dir, unquote(path)))
        regex = Regex.compile!(unquote(pattern))

        native =
          for [_, name, arity] <- Regex.scan(regex, source),
              do: {String.to_atom(name), String.to_integer(arity)}

        assert {:sms_available, 0} in native
        stub = :mob_sms_nif.module_info(:exports)
        assert native -- stub == []
      end
    end
  end
end
