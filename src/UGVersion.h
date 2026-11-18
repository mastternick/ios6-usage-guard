/*
 * UGVersion.h - release string and the cross-process status file path.
 * Shared by the tweak and the Preferences pane; keep both sides in step.
 */

#ifndef UG_VERSION_H
#define UG_VERSION_H

#define UG_VERSION "1.0.2"

/* Runtime heartbeat/state snapshot read by the Preferences pane. */
#define UG_STATUS_PATH "/var/mobile/Library/Preferences/org.usageguard.timer.status.plist"

#endif /* UG_VERSION_H */
