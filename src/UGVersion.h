/*
 * UGVersion.h - release string and the cross-process file paths.
 * Shared by the tweak and the Preferences pane; this header is the only place
 * a version string or an on-disk path may be written, so the two processes
 * cannot drift apart.
 */

#ifndef UG_VERSION_H
#define UG_VERSION_H

#define UG_VERSION "1.0.9"

/* Persisted cycle state, PIN vault and settings, written by the tweak/pane. */
#define UG_PREFS_PATH "/var/mobile/Library/Preferences/org.usageguard.timelock.plist"

/* Runtime heartbeat/state snapshot read by the Preferences pane. */
#define UG_STATUS_PATH "/var/mobile/Library/Preferences/org.usageguard.timer.status.plist"

/* Operator kill switch: while this file exists the runtime does nothing. */
#define UG_KILLSWITCH_PATH "/var/mobile/Library/Preferences/org.usageguard.timer.disable"

/* Local diagnostics trace written by the Preferences bundle (UGTrace); never
 * read by the runtime and never uploaded anywhere. */
#define UG_TRACE_PATH "/var/mobile/Library/Preferences/org.usageguard.timer.trace.log"

#endif /* UG_VERSION_H */
