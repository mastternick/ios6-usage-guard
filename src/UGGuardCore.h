/*
 * UGGuardCore.h - deterministic usage/break cycle state machine.
 *
 * Pure C99: no Foundation, no UIKit, no allocation. This source is compiled
 * both into the tweak and into the host-side unit tests.
 */

#ifndef UG_GUARD_CORE_H
#define UG_GUARD_CORE_H

#include <stddef.h>

/* Serialized form fits comfortably in this buffer (worst case < 128 bytes). */
#define UG_STATE_BUFFER_SIZE 512

/* Largest wall-clock delta ever credited to usage in one tick. Ticks run at
 * 1 Hz, so a value of 2 covers a slightly late timer while never handing out a
 * free minute after the phone wakes from sleep. */
#define UG_MAX_CREDIT_SECONDS 2

#define UG_DEFAULT_USAGE_MINUTES 20
#define UG_DEFAULT_BREAK_MINUTES 30
#define UG_MIN_MINUTES 1
#define UG_MAX_MINUTES 240

typedef enum {
    UGPhaseUsage = 0,
    UGPhaseBreak = 1
} UGPhase;

typedef enum {
    UGEventNone = 0,
    UGEventBreakBegan = 1 << 0,
    UGEventBreakEnded = 1 << 1,
    UGEventOverrideEnded = 1 << 2
} UGEvent;

typedef struct {
    int enabled;
    int phase;              /* UGPhase */
    int usageMinutes;
    int breakMinutes;
    long long remaining;    /* seconds left in the current phase */
    long long lastWall;     /* wall clock (epoch seconds) of the last tick */
    long long overrideUntil;/* wall clock when the parent override expires; 0 = none */
} UGState;

/* Fresh state: enabled, usage phase, configured durations, full allowance. */
void ug_state_defaults(UGState *state, long long now);

/* Restores a state loaded from disk. An interrupted usage phase gets no credit
 * for the downtime; an interrupted break continues to elapse in real time. */
void ug_state_startup(UGState *state, long long now);

/* Advances the machine. screenOn/unlocked gate usage accrual only; a break
 * always elapses in real time. A parent override is anchored in wall time: it
 * expires at exactly overrideUntil, so the break it paused still ends on time,
 * and a backwards clock jump shrinks it instead of extending it. Returns a
 * mask of UGEvent bits. */
int ug_tick(UGState *state, long long now, int screenOn, int unlocked);

/* True when the overlay must be visible. */
int ug_is_locked(const UGState *state, long long now);
int ug_is_overridden(const UGState *state, long long now);
long long ug_override_remaining(const UGState *state, long long now);

/* Parent actions. */
void ug_reset(UGState *state, long long now);
void ug_start_break(UGState *state, long long now);
void ug_pause(UGState *state, long long now, int minutes);
void ug_set_enabled(UGState *state, int enabled, long long now);
void ug_set_usage_minutes(UGState *state, int minutes);
void ug_set_break_minutes(UGState *state, int minutes);

/* "key=value;" text form. Returns the number of bytes written (excluding the
 * NUL), or 0 when the buffer is too small. */
size_t ug_serialize(const UGState *state, char *buffer, size_t capacity);

/* Parses the output of ug_serialize. Returns 1 on success. Missing keys keep
 * the values already in *state; malformed input returns 0. */
int ug_deserialize(UGState *state, const char *text, long long now);

/* MM:SS for any non-negative second count ("00:00" .. "999:59"). */
size_t ug_format_mmss(long long seconds, char *buffer, size_t capacity);

#endif /* UG_GUARD_CORE_H */
