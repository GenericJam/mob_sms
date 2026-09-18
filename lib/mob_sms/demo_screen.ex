defmodule MobSms.DemoScreen do
  @moduledoc """
  A ready-to-run sample screen exercising `MobSms`, shipped so a generated
  app can kick the tires the moment the plugin is activated. Declared in
  the plugin manifest's `:screens`, so the host's home can surface it by
  route without writing any code. Delete it (and the manifest entry) in a
  real app.

  Fires a composer pre-filled with a sample invite-code body. Displays the
  result the plugin delivers — on Android that will always be
  `:composer_opened`, since the platform can't observe what happens once
  the SMS app is up.
  """
  use Mob.Screen

  @sample_body "Join me on Sample App: https://example.com/i/ABC123"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, status: "Tap to open the SMS composer")}
  end

  @impl true
  def render(assigns) do
    tap_compose = {self(), :compose}

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="SMS composer" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text={assigns.status} text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={16} />
        <Button
          text="Compose invite"
          background={:primary}
          text_color={:on_primary}
          padding={:space_md}
          fill_width={true}
          on_tap={tap_compose}
        />
      </Column>
    </Scroll>
    """
  end

  @impl true
  def handle_info({:tap, :compose}, socket) do
    {:noreply,
     MobSms.compose(socket, body: @sample_body)
     |> Mob.Socket.assign(status: "Opening composer…")}
  end

  def handle_info({:sms, :sent}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Sent ✓")}
  end

  def handle_info({:sms, :cancelled}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Cancelled")}
  end

  def handle_info({:sms, :composer_opened}, socket) do
    {:noreply,
     Mob.Socket.assign(socket, status: "Composer opened (Android — outcome unobservable)")}
  end

  def handle_info({:sms, :not_available}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "SMS not available on this device")}
  end

  def handle_info({:sms, :failed}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Send failed")}
  end
end
