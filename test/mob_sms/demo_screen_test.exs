defmodule MobSms.DemoScreenTest do
  use ExUnit.Case, async: true

  @demo_source Path.expand("../../lib/mob_sms/demo_screen.ex", __DIR__)

  describe "demo screen ~MOB template bindings" do
    # This test exists because of the 0.2.0 → 0.2.1 fix. Mob's renderer
    # pattern-matches `{:on_change, {pid, tag}} when is_pid(pid)` and
    # silently drops bare-atom forms — no error, no warning, no wiring.
    # The demo screen shipped with `on_change={:code}` in 0.2.0; the
    # field filled visually but state never updated. The docs taught the
    # same wrong pattern. This scan pins the {pid, tag} form so a future
    # edit can't silently regress the demo (or the snippet it teaches).

    test "no bare-atom on_change or on_tap bindings in the ~MOB template" do
      # Sanity: the demo screen's mount calls MobSms.OneTimeCode.arm/2,
      # which returns the socket unchanged on host (NIF not loaded). This
      # doubles as a smoke assertion that the sibling module is present.
      assert MobSms.OneTimeCode.arm(%Mob.Socket{}, on_receive: :code) ==
               %Mob.Socket{}

      source = File.read!(@demo_source)

      # Match any `on_change={...}` or `on_tap={...}` binding where the
      # first char inside the braces is `:` — i.e. a bare atom rather
      # than a `{pid, tag}` tuple form `{{...}, ...}`. Whitespace-tolerant.
      bad_bindings =
        Regex.scan(~r/(on_change|on_tap)=\{\s*:[a-z_]/, source)

      assert bad_bindings == [],
             """
             Found bare-atom on_change= or on_tap= bindings in demo_screen.ex.
             Mob's renderer silently drops these — the wiring will not fire.
             Change them to `{self(), :tag}` tuples (or the pre-extracted
             variable form used elsewhere in this screen).

             Matches: #{inspect(bad_bindings)}
             """
    end
  end
end
