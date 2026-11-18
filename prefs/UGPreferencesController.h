#import "UGPrivateHeaders.h"

/*
 * Grouped settings pane for the Usage Guard tweak, loaded by PreferenceLoader
 * from UsageGuardPrefs.bundle.
 *
 * The pane is a plain UITableView built by hand on purpose: PSSpecifier and
 * PSListController are private and their nib machinery is not worth depending
 * on for five sections. The class still derives from PSViewController so
 * Preferences can push it as a detail controller and call the controller
 * methods it expects.
 *
 * Every row is configured from the live cycle state; the remaining-time rows
 * derive from the status heartbeat (`Remaining - (now - LastTick)`), so they
 * track the overlay within the ≤5 s status refresh interval.
 *
 * It keeps no copy of anything: reads and writes go through UGSettingsIPC,
 * which owns the preferences file and the notify(3) announcements.
 */

@interface UGPreferencesController : PSViewController <UITableViewDataSource, UITableViewDelegate>

@end
