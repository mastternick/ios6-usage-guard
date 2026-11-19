#import <UIKit/UIKit.h>

#import "UGPrivateHeaders.h"

/*
 * Settings pane for Usage Guard, built the way Preferences.app expects a
 * preference bundle to be built.
 *
 * The previous pane was a hand-rolled grouped UITableView hosted on a bare
 * PSViewController. PreferenceLoader pushes such a controller like any other
 * detail controller, but the host's own contract for that base class goes
 * beyond the few lifecycle calls: the table it installs and the row objects it
 * hands around are private. Hosting our own table inside it made every visit a
 * bet on which private methods Preferences happened to call.
 *
 * This controller instead subclasses PSListController - the same class Apple
 * uses for its own panes - and describes the pane as PSSpecifier rows. The
 * host renders, scrolls, reloads and localises the table; the pane only answers
 * "which rows exist right now" and "what does this row say right now".
 *
 * It keeps no copy of the cycle state: reads and writes go through
 * UGSettingsIPC, which owns the preferences file and the notify(3)
 * announcements.
 */

@interface UGPreferencesListController : PSListController <UIAlertViewDelegate>

@end
