/*
 * UGNotify.h - Darwin notification names shared by the tweak and the
 * Preferences pane. The pane posts the first two; the runtime observes them
 * and posts the third. Each name is an NSString literal, so it can be used
 * directly with -isEqualToString: and via -UTF8String with the notify(3) API.
 */

#ifndef UG_NOTIFY_H
#define UG_NOTIFY_H

/* Preferences pane -> SpringBoard: the settings plist changed on disk. */
#define kUGNotifySettingsChanged @"org.usageguard.timer.settingschanged"

/* Preferences pane -> SpringBoard: preview the break overlay for 5 seconds. */
#define kUGNotifyTestOverlay @"org.usageguard.timer.testoverlay"

/* SpringBoard -> Preferences pane: the status file was rewritten. */
#define kUGNotifyStatusChanged @"org.usageguard.timer.statuschanged"

#endif /* UG_NOTIFY_H */
