/* mob_sms_nif — iOS SMS composer plugin NIF (Objective-C).
 *
 * Presents MFMessageComposeViewController (MessageUI) modally from the
 * host's root view controller, hands back the composer's terminal result
 * via {:sms, atom} to the caller pid.
 *
 * The composer flow requires no permission dialog on iOS — the user must
 * explicitly tap Send inside the composer for anything to actually go out,
 * so no entitlement is needed.
 *
 * Self-contained — core's mob_send2 is a private static, so this ships its
 * own (sms_send2). Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF
 * path (manifest lang: :objc).
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MessageUI/MessageUI.h>
#include <erl_nif.h>

// Self-contained {atom, atom} send.
static void sms_send2(const ErlNifPid *pid, const char *a1, const char *a2) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, a1), enif_make_atom(e, a2));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

// The delegate needs to outlive the modal presentation. MFMessageComposeViewController's
// `messageComposeDelegate` is @property(assign) (unsafe_unretained), so the
// presenting VC never retains it — we do, in g_activeDelegates, until the sheet
// finishes and dismiss's completion block runs.
//
// Multi-flight matters. A caller can (and MOB-256's plugin verify session
// showed the pattern) fire compose again before an earlier sheet has finished
// dismissing. A previous version cleared g_activeDelegates on every finish
// (removeAllObjects), which dropped the OTHER delegate's only strong ref;
// UIKit then delivered didFinishWithResult: to a dangling pointer → crash.
// release_active: now removes ONLY the delegate that finished, so overlapping
// composes each survive to their own callback.
@interface MobSmsDelegate : NSObject <MFMessageComposeViewControllerDelegate>
@property (nonatomic, assign) ErlNifPid callerPid;
@end

@implementation MobSmsDelegate

- (void)messageComposeViewController:(MFMessageComposeViewController *)controller
                 didFinishWithResult:(MessageComposeResult)result {
  const char *outcome;
  switch (result) {
    case MessageComposeResultSent:      outcome = "sent";      break;
    case MessageComposeResultCancelled: outcome = "cancelled"; break;
    case MessageComposeResultFailed:    outcome = "failed";    break;
    default:                            outcome = "failed";    break;
  }
  ErlNifPid pid = self.callerPid;
  // ARC-strong self is captured by the block below; g_activeDelegates keeps
  // us alive through the dismiss animation, and release_active:self drops
  // that ref once the sheet is gone.
  [controller dismissViewControllerAnimated:YES completion:^{
    sms_send2(&pid, "sms", outcome);
    [MobSmsDelegate release_active:self];
  }];
}

// Multi-flight-safe retention holder. Each delegate is added on present and
// removed by its own didFinish callback; other in-flight delegates are
// untouched. The compose flow is USUALLY single-user (modal sheet blocks
// further UI) but the modal-vs-non-modal invariant is a UIKit convention,
// not something the plugin enforces.
static NSMutableArray<MobSmsDelegate *> *g_activeDelegates = nil;

+ (void)retain_active:(MobSmsDelegate *)delegate {
  @synchronized ([MobSmsDelegate class]) {
    if (g_activeDelegates == nil) g_activeDelegates = [NSMutableArray array];
    [g_activeDelegates addObject:delegate];
  }
}

+ (void)release_active:(MobSmsDelegate *)delegate {
  @synchronized ([MobSmsDelegate class]) {
    [g_activeDelegates removeObject:delegate];
  }
}

@end

// Locate a UIViewController we can present from. iOS 15+ uses the connected
// window scene set (multi-scene aware); we prefer the foreground-active
// scene, falling back to any window scene that has a key window.
static UIViewController *sms_top_view_controller(void) {
  UIWindow *targetWindow = nil;
  NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;
  for (UIScene *scene in scenes) {
    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
    UIWindowScene *ws = (UIWindowScene *)scene;
    for (UIWindow *w in ws.windows) {
      if (w.isKeyWindow) { targetWindow = w; break; }
    }
    if (targetWindow != nil) break;
  }
  if (targetWindow == nil) {
    for (UIScene *scene in scenes) {
      if (![scene isKindOfClass:[UIWindowScene class]]) continue;
      UIWindowScene *ws = (UIWindowScene *)scene;
      if (ws.windows.count > 0) { targetWindow = ws.windows.firstObject; break; }
    }
  }
  if (targetWindow == nil) return nil;

  UIViewController *vc = targetWindow.rootViewController;
  // Walk down any presented / navigation / tab hierarchy — presenting from a
  // VC that isn't at the top produces UIKit "not in view hierarchy" warnings
  // and often refuses outright.
  while (vc.presentedViewController != nil) vc = vc.presentedViewController;
  // If the top VC is mid-transition (being dismissed / presented), calling
  // presentViewController: on it silently no-ops — UIKit logs "Attempt to
  // present X on Y whose view is not in the window hierarchy" and drops the
  // request. Delegate never fires, caller hangs. Report :not_available instead.
  if (vc.isBeingDismissed || vc.isBeingPresented) return nil;
  return vc;
}

// enif_inspect_binary / enif_inspect_iolist_as_binary return 1 on success
// and 0 on failure. The `!x && !y` chain therefore fires only when BOTH
// return 0 — i.e. neither inspection accepted the term. Correct semantics
// but the double-negate reads oddly; kept in this form for parity with the
// mob-core NIF helpers and to make the "give up early" pattern greppable.
static NSString *sms_str_from_iolist(ErlNifEnv *env, ERL_NIF_TERM term) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, term, &bin) &&
      !enif_inspect_iolist_as_binary(env, term, &bin)) {
    return nil;
  }
  return [[NSString alloc] initWithBytes:bin.data
                                  length:bin.size
                                encoding:NSUTF8StringEncoding];
}

// sms_compose(to :: iodata, body :: iodata) — both may be empty binaries.
static ERL_NIF_TERM nif_sms_compose(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  NSString *to = sms_str_from_iolist(env, argv[0]);
  NSString *body = sms_str_from_iolist(env, argv[1]);
  if (to == nil || body == nil) return enif_make_badarg(env);

  ErlNifPid pid;
  enif_self(env, &pid);

  dispatch_async(dispatch_get_main_queue(), ^{
    if (![MFMessageComposeViewController canSendText]) {
      sms_send2(&pid, "sms", "not_available");
      return;
    }
    UIViewController *host = sms_top_view_controller();
    if (host == nil) {
      sms_send2(&pid, "sms", "not_available");
      return;
    }

    MFMessageComposeViewController *vc = [[MFMessageComposeViewController alloc] init];
    if (to.length > 0) vc.recipients = @[to];
    if (body.length > 0) vc.body = body;

    MobSmsDelegate *delegate = [[MobSmsDelegate alloc] init];
    delegate.callerPid = pid;
    vc.messageComposeDelegate = delegate;
    [MobSmsDelegate retain_active:delegate];

    [host presentViewController:vc animated:YES completion:nil];
  });

  return enif_make_atom(env, "ok");
}

// ── Registration ──────────────────────────────────────────────────────────
static ErlNifFunc nif_funcs[] = {
    {"sms_compose", 2, nif_sms_compose, 0},
};

ERL_NIF_INIT(mob_sms_nif, nif_funcs, NULL, NULL, NULL, NULL)
