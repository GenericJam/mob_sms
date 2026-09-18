%% mob_sms_nif — Erlang NIF module for the SMS composer tier-1 plugin.
%%
%% iOS: priv/native/ios/mob_sms_nif.m (Objective-C, MFMessageComposeViewController).
%% Android: priv/native/jni/mob_sms_nif.zig (ACTION_SENDTO via the
%% io.mob.sms.MobSmsBridge Kotlin bridge). Both register this module via
%% ERL_NIF_INIT and are statically linked into the host binary on device.
%% On a host dev build neither is linked, so on_load tolerates the failure and
%% the NIFs fall back to nif_error until the native merge links one.
-module(mob_sms_nif).
-export([sms_compose/2, sms_arm_one_time_code/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_sms_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

sms_compose(_To, _Body) ->
    erlang:nif_error(nif_not_loaded).

sms_arm_one_time_code() ->
    erlang:nif_error(nif_not_loaded).
