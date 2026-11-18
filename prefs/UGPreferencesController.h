#import <UIKit/UIKit.h>

/*
 * Grouped settings pane for the Usage Guard tweak.
 *
 * The same implementation is compiled for two hosts:
 *   - the jailbreak Settings bundle (default build), where PreferenceLoader
 *     instantiates the pane as a detail controller of the host application's
 *     own base class, resolved at load time;
 *   - the standalone app in app/, which defines UG_HOST_APP and links no
 *     Preferences framework at all, so a local UGControllerBase stands in for
 *     that base class.
 *
 * The pane is a plain UITableView built by hand on purpose: the specifier and
 * list-controller classes are private and their nib machinery is not worth
 * depending on for five sections. The pane still derives from the
 * host's detail-controller base class so the Settings host can push it and call
 * the controller methods it expects.
 *
 * Every row is configured from the live cycle state; the remaining-time rows
 * derive from the status heartbeat (`Remaining - (now - LastTick)`), so they
 * track the overlay within the ≤5 s status refresh interval.
 *
 * It keeps no copy of anything: reads and writes go through UGSettingsIPC,
 * which owns the preferences file and the notify(3) announcements.
 */

#ifndef UG_HOST_APP

/* Settings bundle build: the base class lives in the host application and is
 * bound when the bundle is dlopen()ed (-Wl,-undefined,dynamic_lookup). */
#import "UGPrivateHeaders.h"

@interface UGPreferencesController : PSViewController <UITableViewDataSource, UITableViewDelegate>

@end

#else

/* Standalone app build: nothing links Preferences, so the single piece of the
 * host base class this pane uses is declared here and implemented in the .m.
 * The public surface is the same as the Settings build's: the
 * initForContentSize: entry point plus UIViewController's title and view API. */
@interface UGControllerBase : UIViewController

- (id)initForContentSize:(CGSize)size;

@end

@interface UGPreferencesController : UGControllerBase <UITableViewDataSource, UITableViewDelegate>

@end

#endif /* UG_HOST_APP */
