defmodule MobSms.OneTimeCode do
  @moduledoc """
  Cross-platform one-time-code (OTP) SMS autofill for Mob apps.

  Opinionated wiring around the two platforms' native mechanisms — iOS reads
  the code from QuickType above the keyboard, Android reads it via Google
  Play Services' SMS Retriever — presented as one consistent shape for the
  common case: "I sent a code via SMS; when it arrives, put it in my text
  field."

  ## Cross-platform behaviour

  The received code arrives as `{:change, tag, code}` on both platforms —
  the same shape a text field's `on_change` fires. Iron out the asymmetry
  at the plugin layer so the screen has one handler for both paths:

      # On the screen
      def mount(_params, _session, socket) do
        {:ok, MobSms.OneTimeCode.arm(socket, on_receive: :code)}
      end

      def render(assigns) do
        ~MOB\"""
        <Column>
          <TextField
            value={@code}
            on_change={{self(), :code}}
            keyboard={:number}
            text_content_type={:one_time_code}
            placeholder="Verification code"
          />
        </Column>
        \"""
      end

      def handle_info({:change, :code, value}, socket) do
        # Fires on BOTH platforms:
        #   • iOS  — user tapped the QuickType suggestion above the
        #            keyboard (Messages parsed the SMS, offered the code)
        #   • Android — SMS Retriever delivered the code, plugin forwarded
        #            it in the same shape a keystroke would have taken
        {:noreply, Mob.Socket.assign(socket, code: value)}
      end

      def handle_info({:sms_otp, :timeout}, socket) do
        # Optional. Fires on Android when the 5-minute Retriever window
        # closes with no SMS, GMS failed to start, or a subsequent arm/2
        # evicted this one. Ignore if you're happy to let the user retype.
        {:noreply, Mob.Socket.assign(socket, status: "Please retype the code")}
      end

  Under the hood each platform uses a different native mechanism.

  ### iOS

  Setting `text_content_type: :one_time_code` on a `<TextField>` sets
  `UITextContentType.oneTimeCode` on the underlying SwiftUI TextField.
  iOS Messages parses incoming SMSes looking for natural-language code
  patterns (e.g. "Your code is 123456") and, when the tagged field is
  focused, surfaces the code as a QuickType suggestion above the
  keyboard. The user taps it; the code flows in as the field's normal
  `on_change` value.

  No `arm/2` call is required on iOS. No entitlement, no framework, no
  server-side hash. Requires mob 0.9.1+ (the `text_content_type` prop is
  new in that release).

  The SMS just needs to contain the code in a natural-language pattern
  that iOS Messages recognises. `"Your code is 123456"` works.

  ### Android

  `arm/2` registers a scoped BroadcastReceiver (only Google Play Services
  can broadcast to it — the receiver is gated on
  `com.google.android.gms.auth.api.phone.permission.SEND`) and calls
  `SmsRetrieverClient.startSmsRetriever()` to tell GMS to route matching
  SMSes to your app. When a matching SMS arrives, the plugin extracts
  the code from the body and forwards it to the screen as
  `{:change, tag, code}`.

  The server-side SMS must be in the format Google requires:

      Your ExampleApp code is: 123456
      <blank line>
      FA+9qCX9VSu

  where `FA+9qCX9VSu` is the 11-char hash unique to this app's package +
  signing cert (see below). The Retriever needs no user permission and
  no user-visible dialog — the hash is the routing key.

  #### Computing the 11-char hash

  The hash is `base64(sha256("<package_name> <signing_cert_sha256_lowercase_hex>"))[:11]`.
  For the release cert it is a stable value computed once; for the debug
  cert it differs per developer. Log both during development using
  Google's `AppSignatureHelper.getAppSignatures()` (drop it into
  `MainActivity.kt`, Logcat prints the hash on first run, delete after
  copying). Full source at
  https://developers.google.com/identity/sms-retriever/verify.

  The hash is a routing key, not a security boundary — a spoofed SMS
  with a valid hash reaches your app, but Google Messages' spam filters
  + the scoped-permission BroadcastReceiver make cross-app spoofing
  effectively impossible.

  ### Requirements

  * mob `~> 0.9.1` (`text_content_type` prop on `<TextField>`).
  * Android target: Google Play Services present — 99%+ of Play-installed
    devices. Aftermarket ROMs / de-Googled devices without GMS fall
    straight to the `{:sms_otp, :timeout}` path from `arm/2`.

  ## What this is NOT

  Not a full SMS-reading API. iOS has no such thing for third-party apps
  and Google Play locks `READ_SMS` behind a review gate that rejects most
  non-SMS-centric apps. If the app needs to browse SMS history or
  intercept all incoming messages, this plugin is not the right shape —
  see the "What this plugin is NOT" section in `MobSms`'s @moduledoc.
  """

  @typedoc "The extracted verification code from the SMS body."
  @type code :: String.t()

  @doc """
  Arm the platform's OTP delivery.

  Cross-platform delivery model: on **both platforms** the received code
  arrives as `{:change, tag, code}` — the same shape a text field's
  `on_change` handler fires. iOS emits this through QuickType autofill
  directly (nothing to arm), Android emits it through this plugin when
  Google Play Services delivers the SMS.

  Set the SAME atom as your text field's `on_change`:

      MobSms.OneTimeCode.arm(socket, on_receive: :code)

      # in render:
      <TextField
        value={@code}
        on_change={{self(), :code}}
        text_content_type={:one_time_code}
      />

      # one handle_info clause covers both platforms:
      def handle_info({:change, :code, value}, socket), do: ...

  On the sad path (Android 5-minute timeout, GMS start failure, or an
  arm/2 re-arm evicting a prior one), the plugin sends
  `{:sms_otp, :timeout}` to the caller so screens that want to surface
  "code didn't arrive" can distinguish it. Ignore the message if you don't
  care — the user can always type the code manually.

  ## Options

    * `:on_receive` — the tag to fire on the caller as `{:change, tag,
      code}` when Android's SMS Retriever delivers a code. Should match the
      `on_change` atom on the destination text field so the same handler
      catches both keyboard input (including iOS QuickType autofill) and
      SMS Retriever delivery. Default `:otp` (rename it — this default is
      only useful for the demo screen; production apps should pass their
      field's tag explicitly).

  Returns the socket unchanged.

  ## Per-platform notes

  * **iOS**: no NIF is loaded, so this call falls straight through to a
    no-op. The autofill mechanism is entirely native — set
    `text_content_type: :one_time_code` on the TextField and iOS Messages
    surfaces the code as a QuickType suggestion above the keyboard when
    the field is focused; the user taps it, the code flows in as the
    field's normal `on_change` value. `arm/2` returning early on iOS
    keeps your `mount/3` cross-platform.

  * **Android**: spawns a short-lived proxy process that catches the SMS
    Retriever's raw delivery and forwards it as `{:change, tag, code}`
    to the calling process. Idle for 6 minutes then dies (SMS Retriever's
    own timeout is 5 min; the extra minute absorbs the late-delivery
    edge). Re-arming from the same screen replaces the prior arm and
    delivers `{:sms_otp, :timeout}` to the prior proxy so nothing hangs.
  """
  @spec arm(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def arm(socket, opts \\ []) do
    tag = Keyword.get(opts, :on_receive, :otp)
    target = self()

    spawn(fn ->
      # NIF's enif_self resolves to THIS proxy's pid, so the {:sms_otp,
      # code} delivery lands here — we translate to the on_change shape
      # and forward to the screen. On iOS the NIF isn't loaded; the
      # catch collapses this proxy immediately, no delivery expected.
      try do
        :mob_sms_nif.sms_arm_one_time_code()
      catch
        :error, :nif_not_loaded -> exit(:normal)
      end

      receive do
        {:sms_otp, ""} ->
          # Timeout / GMS failure / evicted by a re-arm. Signal it
          # distinctly rather than firing the on_change with "" —
          # a blank on_change would clear the user's typed input.
          send(target, {:sms_otp, :timeout})

        {:sms_otp, code} when is_binary(code) ->
          send(target, {:change, tag, code})
      after
        # Retriever's own timeout is 5 minutes. Give the proxy a bit
        # longer so late deliveries still land; otherwise we bail and
        # tell the screen so it can offer manual retype.
        6 * 60 * 1000 -> send(target, {:sms_otp, :timeout})
      end
    end)

    socket
  end
end
