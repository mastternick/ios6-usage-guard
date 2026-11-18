#import <Foundation/Foundation.h>

/*
 * Line-oriented trace log for the Preferences bundle.
 *
 * The pane is loaded into Preferences.app, which on a non-SSH device can only
 * be observed by exporting files with 3uTools: when the pane crashes there is
 * no syslog to read. This module writes one timestamped line per call to
 * UG_TRACE_PATH (src/UGVersion.h), so the next crash leaves behind the last
 * step that ran plus the uncaught-exception reason and call stack.
 *
 * Rules that make it safe to call from anywhere, including a crash path:
 *   - open / append / close per line, no state shared between calls, so any
 *     thread may call it and a process death cannot leave a locked handle;
 *   - the file is emptied before a line is written once it passes 64 KB, so it
 *     can never grow without bound on a 3.5" device;
 *   - the whole body is wrapped in @try/@catch and every failure is silent: a
 *     diagnostic helper must never turn a working pane into a crashing one.
 *
 * The log is local to the device; nothing is uploaded anywhere.
 */

/* Appends "<epoch> <ISO-8601 UTC> [<pid>] <text>\n". Never throws. */
void UGTrace(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/* Absolute path of the trace file, for the Information section. */
NSString *UGTracePath(void);

/* Current size in bytes, or 0 when the file is absent or unreadable. */
unsigned long long UGTraceFileSize(void);

/* Deletes the file. Returns YES when it no longer exists afterwards. */
BOOL UGTraceRemoveLog(void);
