//! mob_sms_nif — Android SMS composer plugin NIF (Zig).
//!
//! Bridges to the Kotlin `io.mob.sms.MobSmsBridge`, which fires an
//! `Intent.ACTION_SENDTO` with `smsto:` to hand the user off to their
//! default SMS app pre-filled with recipient + body. The plugin cannot
//! observe what happens once the SMS app is up; nativeDeliverSms carries
//! back `composer_opened` (composer showing, outcome unobservable) or
//! `not_available` (no SMS-capable app installed).
//!
//! Modeled directly on mob_biometric_nif.zig (which was extracted from
//! mob-core's nif_biometric_authenticate); the bridge-class registration
//! pattern (nativeRegister + nativeDeliverXxx) is the tier-1 convention.
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`,
//! reaching mob-core ERTS / JNI bindings through `@import("erts")` /
//! `@import("jni")`. `get_jenv` + `g_jvm` are mob-core exports linked
//! into the same `.so`.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const SmsMethods = struct {
    compose: jni.JMethodID = null,
    arm_one_time_code: jni.JMethodID = null,
};

var g_sms: SmsMethods = .{};
var g_sms_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method ids ───────────
export fn Java_io_mob_sms_MobSmsBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_sms_cls = jni.newGlobalRef(jenv, cls);
    if (g_sms_cls == null) return;
    g_sms.compose = jni.getStaticMethodID(jenv, cls, "sms_compose", "(JLjava/lang/String;Ljava/lang/String;)V");
    g_sms.arm_one_time_code = jni.getStaticMethodID(jenv, cls, "arm_one_time_code", "(J)V");
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core / biometric) ──
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

// Send {:sms, <atom>} to `pid`. Used by every sad-path branch below AND by
// the inbound delivery thunk — the caller's contract is "you WILL get one
// {:sms, _} message" and every failure branch has to honour that or the
// caller hangs forever waiting.
fn sendSmsAtomC(pid: *erts.ErlNifPid, atom_c: [*:0]const u8) void {
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "sms"),
        erts.enif_make_atom(env, atom_c),
    });
    _ = erts.enif_send(null, pid, env, msg);
}

// Call `MobSmsBridge.sms_compose(pid_long, to, body)` — async; the result
// lands via nativeDeliverSms once the composer is showing (or the intent
// resolution fails). Returns :ok unconditionally on the happy path; on the
// two teardown/setup edges below, it delivers {:sms, :not_available} FIRST
// so the caller doesn't wait forever.
fn callBridgeCompose(env: ?*erts.ErlNifEnv, pid_in: erts.ErlNifPid, to: ?[*:0]const u8, body: ?[*:0]const u8) erts.ERL_NIF_TERM {
    var pid = pid_in;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse {
        // JVM shutting down or thread-attach refused. Deliver :not_available
        // before we bail so the caller isn't stranded.
        sendSmsAtomC(&pid, "not_available");
        return erts.atom(env, "error");
    };
    if (g_sms_cls == null or g_sms.compose == null) {
        // nativeRegister never ran (missing bridge class, or ClassLoader
        // couldn't find `sms_compose`). Calling into null jclass/jmethodID
        // is undefined behaviour — deliver :not_available and return.
        detachIfAttached(attached);
        sendSmsAtomC(&pid, "not_available");
        return erts.atom(env, "error");
    }
    const jto: jni.JString = if (to) |t| jni.newStringUTF(jenv, t) else null;
    const jbody: jni.JString = if (body) |b| jni.newStringUTF(jenv, b) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, g_sms_cls, g_sms.compose, pidToJlong(pid), jto, jbody);
    if (jto != null) jni.deleteLocalRef(jenv, jto);
    if (jbody != null) jni.deleteLocalRef(jenv, jbody);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Inbound delivery thunk — Kotlin bridge calls this ────────────────────
// Builds {:sms, :composer_opened | :not_available} and sends it to the
// waiting pid.
export fn Java_io_mob_sms_MobSmsBridge_nativeDeliverSms(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, result: jni.JString) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const result_c = jenv.*.GetStringUTFChars.?(jenv, result, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, result, result_c);
    sendSmsAtomC(&pid, result_c);
}

// ── OTP: arm SMS Retriever ────────────────────────────────────────────────
// Calls MobSmsBridge.arm_one_time_code(pid). The Kotlin side registers the
// GMS BroadcastReceiver + calls SmsRetrieverClient.startSmsRetriever;
// nativeDeliverSmsCode below sends {:sms_otp, code} back to the pid on SMS
// arrival (or {:sms_otp, ""} on timeout / failure).
fn callBridgeArmOtp(env: ?*erts.ErlNifEnv, pid_in: erts.ErlNifPid) erts.ERL_NIF_TERM {
    var pid = pid_in;
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse {
        sendSmsOtp(&pid, "");
        return erts.atom(env, "error");
    };
    if (g_sms_cls == null or g_sms.arm_one_time_code == null) {
        detachIfAttached(attached);
        sendSmsOtp(&pid, "");
        return erts.atom(env, "error");
    }
    jenv.*.CallStaticVoidMethod.?(jenv, g_sms_cls, g_sms.arm_one_time_code, pidToJlong(pid));
    detachIfAttached(attached);
    return erts.ok(env);
}

// Send {:sms_otp, "<code>"} to `pid`. Code is a variable-length string
// (usually 4-8 digits, but the format is per-server so we don't cap it here).
// Empty string signals "SMS Retriever timed out or failed" — the Elixir
// proxy translates it into {:sms_otp, :timeout} for the caller.
//
// OOM handling: on enif_alloc_binary failure fall back to a zero-size
// binary so the caller ALWAYS receives one {:sms_otp, _} message. Anything
// else strands the pid, and the plugin's contract is that arm/2 either
// forwards a code OR fires the timeout signal.
fn sendSmsOtp(pid: *erts.ErlNifPid, code_c: [*:0]const u8) void {
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    // Length of code_c up to a sane cap. OTPs are ≤ 8 digits typically;
    // 256 covers any pathological upstream string.
    var len: usize = 0;
    while (code_c[len] != 0 and len < 256) : (len += 1) {}

    // enif_alloc_binary returns 1 on success, 0 on OOM. On OOM retry with
    // zero size so the caller sees {:sms_otp, ""} — the proxy translates
    // that to :timeout. If even the zero-size alloc fails we're too deep
    // to recover; drop, let the proxy's 6-minute after-clause fire the
    // timeout instead. enif_make_binary transfers ownership of bin.data
    // to the BEAM once called.
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(len, &bin) == 0) {
        if (erts.enif_alloc_binary(0, &bin) == 0) return;
    } else if (len > 0) {
        @memcpy(bin.data[0..len], code_c[0..len]);
    }
    const bin_term = erts.enif_make_binary(env, &bin);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "sms_otp"),
        bin_term,
    });
    _ = erts.enif_send(null, pid, env, msg);
}

// ── Inbound OTP delivery thunk — Kotlin's BroadcastReceiver calls this ────
export fn Java_io_mob_sms_MobSmsBridge_nativeDeliverSmsCode(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, code: jni.JString) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const code_c = jenv.*.GetStringUTFChars.?(jenv, code, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, code, code_c);
    sendSmsOtp(&pid, code_c);
}

// ── NIFs ──────────────────────────────────────────────────────────────────

// Copy a binary/iolist arg into a null-terminated buffer. The bridge call
// (newStringUTF) copies the jstring synchronously, so a stack buffer is fine.
// Phone numbers and typical SMS bodies fit; longer bodies truncate — SMS
// itself is 160 chars per segment, so a 512-byte buffer is more than enough.
fn binArgZ(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM, buf: []u8) bool {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, term, &bin) == 0) return false;
    const n = @min(bin.size, buf.len - 1);
    @memcpy(buf[0..n], bin.data[0..n]);
    buf[n] = 0;
    return true;
}

fn nif_sms_compose(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    // Phone numbers: E.164 max is 15 digits + a plus. 64-byte buffer covers
    // any legal input.
    var to: [64]u8 = @splat(0);
    // SMS body: one message is 160 GSM-7 chars; concatenated messages can go
    // longer. 4KB buffer covers realistic pre-fill payloads (invite copy,
    // share links, etc.) without a heap alloc.
    var body: [4096]u8 = @splat(0);
    if (!binArgZ(env, argv[0], &to)) return erts.badarg(env);
    if (!binArgZ(env, argv[1], &body)) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgeCompose(env, pid, jni.asCStr(&to), jni.asCStr(&body));
}

fn nif_sms_arm_one_time_code(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgeArmOtp(env, pid);
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "sms_compose", .arity = 2, .fptr = nif_sms_compose, .flags = 0 },
    .{ .name = "sms_arm_one_time_code", .arity = 0, .fptr = nif_sms_arm_one_time_code, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_sms_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_sms_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
