defmodule MobSms do
  @moduledoc """
  Send SMS via the user's default messaging app — a Mob plugin.

  Both platforms show a pre-filled composer sheet. The user taps Send inside
  the system messaging UI for anything to actually go out; the plugin can
  neither send silently nor bypass the confirmation. This is the sanctioned
  cross-platform path for "let my app compose an SMS" (invite codes, share a
  link, tell-a-friend, verification workaround) and requires no permission
  dialog on either platform.

  ## Usage

      MobSms.compose(socket, to: "+15551234567", body: "Join me: https://example.com/i/ABC")

  Both `:to` and `:body` are optional. Omit `:to` to let the user pick a
  recipient from Contacts inside the composer. Omit `:body` if you want the
  user to type from scratch (rare — the point of the plugin is usually to
  seed the message).

  Result arrives asynchronously as a message to the calling process:

      handle_info({:sms, :sent},             socket)
      handle_info({:sms, :cancelled},        socket)
      handle_info({:sms, :composer_opened},  socket)
      handle_info({:sms, :not_available},    socket)

  ## Per-platform delivery — the asymmetry to know

  * **iOS** — `MFMessageComposeViewController` is presented as a sheet inside
    your app. The system delegate reports `:sent`, `:cancelled`, or `:failed`
    reliably. `:not_available` is delivered on a device that cannot send SMS
    (simulator, no cellular / iMessage capability, no SIM).

  * **Android** — `Intent.ACTION_SENDTO` with `smsto:` opens the user's
    default SMS app externally. Android does not reliably tell the host app
    whether the user tapped Send or cancelled — most SMS apps do not set an
    activity result. The plugin delivers `:composer_opened` once the composer
    is showing (or `:not_available` if no SMS-capable app is installed) and
    stops there. If knowing what the user did afterwards matters to your
    flow, plan around this asymmetry rather than assuming a `:sent`.

  This asymmetry is by design at the platform layer, not something the
  plugin can paper over — Android intentionally hands the user off to a
  separate app rather than embedding a sheet.

  ## What the plugin is NOT

  Not a silent-send mechanism. iOS has no public API for sending SMS
  without the user tapping Send; Apple treats that as a bright-line spam
  surface. Android *can* do silent send via `SmsManager.sendTextMessage`
  under the `SEND_SMS` runtime permission, but Google Play rejects that
  permission request for most non-SMS-centric apps (the "Permissions
  Declaration" gate). If the user has a real reason to bypass the sheet on
  Android — and can accept iOS being permanently in composer mode — that
  can be a separate `Mob.Sms.send/2` in a later release.
  """

  @typedoc "Result atom delivered to the caller after the composer flow settles."
  @type result :: :sent | :cancelled | :composer_opened | :not_available

  @doc """
  Open the system SMS composer, pre-filled with the given recipient and body.

  Both `:to` and `:body` are optional. On iOS a missing `:to` opens the
  composer with an empty recipient field (the user picks from Contacts). On
  Android the same — a missing `:to` sends `smsto:` (no phone) which Google
  Messages and most third-party SMS apps interpret as "open composer, no
  recipient chosen."

  Returns the socket unchanged. The composer result arrives on this process
  as `{:sms, result}` — see the module doc for the per-platform behaviour.
  """
  @spec compose(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def compose(socket, opts \\ []) do
    to = opts |> Keyword.get(:to, "") |> to_string()
    body = opts |> Keyword.get(:body, "") |> to_string()
    :mob_sms_nif.sms_compose(to, body)
    socket
  end
end
