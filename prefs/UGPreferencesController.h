#import <UIKit/UIKit.h>

/*
 * Grouped settings pane for the Usage Guard tweak, loaded by PreferenceLoader
 * from UsageGuardPrefs.bundle.
 *
 * The pane is a plain UITableView built by hand on purpose: PSSpecifier and
 * PSListController are private and their nib machinery is not worth depending
 * on for five sections. Every row is configured from the live cycle state, so
 * the pane and the break overlay can never disagree.
 *
 * It keeps no copy of anything: reads and writes go through UGSettingsIPC,
 * which owns the preferences file and the notify(3) announcements.
 */

@interface UGPreferencesController : UITableViewController

@end
