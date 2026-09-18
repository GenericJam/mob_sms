defmodule MobSms.DemoScreen do
  @moduledoc """
  Ready-to-run sample screen exercising `MobSms.compose/2` and
  `MobSms.OneTimeCode.arm/2`. Auto-listed by any host that enumerates
  `Mob.Plugins.screens/0`. Delete this file (and the manifest `:screens`
  entry) in a real app.

  Two sections:

  * **Composer** — pre-fills the system SMS app with an invite body and
    hands off. Result flows to `handle_info/2` as `{:sms, atom}`.

  * **One-time code (OTP)** — arms the platform's OTP autofill on mount
    with `on_receive: :code` (matches the text field's
    `on_change={{self(), :code}}`).
    Both platforms deliver the received code as `{:change, :code, value}`
    — same shape as any keystroke — so one handler covers iOS
    QuickType autofill AND Android's SMS Retriever. The optional
    `{:sms_otp, :timeout}` handler surfaces the sad path (5-min
    Android timeout, GMS start failure, evicted by re-arm).
  """
  use Mob.Screen

  @sample_body "Join me on Sample App: https://example.com/i/ABC123"

  @impl true
  def mount(_params, _session, socket) do
    # Kick the OTP arm on mount. Idempotent on iOS (no-op); on Android,
    # starts a 5-minute retriever window. `:code` matches the text field's
    # on_change={{self(), :code}} tag so the retriever's delivery lands in
    # the same handler as user keystrokes / iOS QuickType.
    socket = MobSms.OneTimeCode.arm(socket, on_receive: :code)

    {:ok,
     Mob.Socket.assign(socket,
       compose_status: "Tap to open the SMS composer",
       code: "",
       code_status: "Waiting for OTP…"
     )}
  end

  @impl true
  def render(assigns) do
    tap_compose = {self(), :compose}
    # on_change must be a {pid, tag} tuple — Mob.Renderer's on_change
    # pattern match requires the pid, and an atom-only value is silently
    # dropped by the renderer.
    change_code = {self(), :code}

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="SMS composer" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text={assigns.compose_status} text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={12} />
        <Button
          text="Compose invite"
          background={:primary}
          text_color={:on_primary}
          padding={:space_md}
          fill_width={true}
          on_tap={tap_compose}
        />

        <Spacer size={32} />

        <Text text="One-time code (OTP)" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text={assigns.code_status} text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={12} />
        <TextField
          value={assigns.code}
          on_change={change_code}
          keyboard={:number}
          text_content_type={:one_time_code}
          placeholder="Verification code"
        />
      </Column>
    </Scroll>
    """
  end

  # ── Compose flow ────────────────────────────────────────────────────────
  @impl true
  def handle_info({:tap, :compose}, socket) do
    {:noreply,
     MobSms.compose(socket, body: @sample_body)
     |> Mob.Socket.assign(compose_status: "Opening composer…")}
  end

  def handle_info({:sms, :sent}, socket) do
    {:noreply, Mob.Socket.assign(socket, compose_status: "Sent ✓")}
  end

  def handle_info({:sms, :cancelled}, socket) do
    {:noreply, Mob.Socket.assign(socket, compose_status: "Cancelled")}
  end

  def handle_info({:sms, :composer_opened}, socket) do
    {:noreply,
     Mob.Socket.assign(socket,
       compose_status: "Composer opened (Android — outcome unobservable)"
     )}
  end

  def handle_info({:sms, :not_available}, socket) do
    {:noreply, Mob.Socket.assign(socket, compose_status: "SMS not available on this device")}
  end

  def handle_info({:sms, :failed}, socket) do
    {:noreply, Mob.Socket.assign(socket, compose_status: "Send failed")}
  end

  # ── OTP flow ────────────────────────────────────────────────────────────
  # Both platforms deliver the code as {:change, :code, value} — the same
  # shape a keystroke would take. iOS: QuickType autofill on a field with
  # text_content_type={:one_time_code}. Android: SMS Retriever delivery,
  # forwarded by MobSms.OneTimeCode as an on_change tuple keyed on the
  # tag arm/2 was called with.
  def handle_info({:change, :code, value}, socket) do
    {:noreply,
     Mob.Socket.assign(socket,
       code: value,
       code_status: "Code received (iOS QuickType, Android SMS Retriever, or manual entry)"
     )}
  end

  # Android-only sad path: retriever timed out, GMS failed to start, or
  # a subsequent arm/2 evicted this one. iOS never fires this.
  def handle_info({:sms_otp, :timeout}, socket) do
    {:noreply, Mob.Socket.assign(socket, code_status: "OTP timeout — retype below")}
  end
end
