// mob_sms plugin — Android bridge (Intent.ACTION_SENDTO with smsto:).
//
// Opens the user's default SMS app pre-filled with recipient + body. Cannot
// observe the outcome — Android hands off to a separate activity and most
// SMS apps do not set an activity result, so the plugin delivers
// :composer_opened once the composer is up and stops there. The asymmetry
// vs iOS's inline sheet is documented in MobSms's @moduledoc.
//
// The native thunks (nativeRegister + nativeDeliverSms) are exported
// directly from the sibling zig NIF mob_sms_nif.zig. MobPluginBootstrap
// .registerAll() calls register() at startup and hands it the Activity
// (MobActivityAware). No MobPermissionProvider: composer flow needs no
// runtime permission — the user must tap Send inside the SMS app for
// anything to actually go out.
//
// Android 11+ package-visibility: no <queries> block is required. That
// system gates PackageManager.resolveActivity / queryIntentActivities but
// NOT startActivity itself for ACTION_SENDTO. The bridge catches
// ActivityNotFoundException as the "no SMS app installed" signal and
// delivers :not_available.
package io.mob.sms

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import java.lang.ref.WeakReference

object MobSmsBridge : io.mob.plugin.MobActivityAware {
    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // result: "composer_opened" | "not_available" -> {:sms, atom}. See the
    // MobSms @moduledoc for why Android cannot deliver :sent or :cancelled.
    @JvmStatic external fun nativeDeliverSms(pid: Long, result: String)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @JvmStatic
    fun sms_compose(pid: Long, to: String, body: String) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverSms(pid, "not_available"); return
        }

        activity.runOnUiThread {
            // smsto:PHONE (URL-encoded) if we have a recipient, else bare
            // smsto: — Google Messages and the popular third-party SMS apps
            // both interpret bare smsto: as "open composer, no recipient
            // chosen." Body rides as the sms_body extra (the widely
            // supported extra key across SMS apps; the URI ?body= form
            // works on Messages but not everywhere).
            val uri = if (to.isEmpty()) {
                Uri.parse("smsto:")
            } else {
                Uri.parse("smsto:${Uri.encode(to)}")
            }
            val intent = Intent(Intent.ACTION_SENDTO, uri).apply {
                if (body.isNotEmpty()) putExtra("sms_body", body)
                // FLAG_ACTIVITY_NEW_TASK — the SMS app runs in its own task
                // stack, so returning to our app via Back does not first
                // clear the composer. Also needed if the activity ref points
                // at a non-Activity context (shouldn't happen here, but the
                // flag is safe when it does).
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }

            try {
                activity.startActivity(intent)
                nativeDeliverSms(pid, "composer_opened")
            } catch (e: ActivityNotFoundException) {
                nativeDeliverSms(pid, "not_available")
            }
        }
    }
}
