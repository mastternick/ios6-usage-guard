/*
 * UGGuardCore.c - pure C cycle engine shared by the tweak and host tests.
 */

#include "UGGuardCore.h"

#include <stdio.h>
#include <string.h>

static int ug_clamp_int(int value, int minimum, int maximum)
{
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

static long long ug_phase_seconds(const UGState *state)
{
    long long minutes = (state->phase == UGPhaseBreak)
        ? (long long)state->breakMinutes
        : (long long)state->usageMinutes;
    return minutes * 60LL;
}

void ug_state_defaults(UGState *state, long long now)
{
    if (!state) return;
    state->enabled = 1;
    state->phase = UGPhaseUsage;
    state->usageMinutes = UG_DEFAULT_USAGE_MINUTES;
    state->breakMinutes = UG_DEFAULT_BREAK_MINUTES;
    state->remaining = (long long)UG_DEFAULT_USAGE_MINUTES * 60LL;
    state->lastWall = now;
    state->overrideUntil = 0;
}

void ug_state_startup(UGState *state, long long now)
{
    if (!state) return;
    /* A usage phase must not be credited for the time the tweak was down.
     * A break keeps its last tick so it elapses with real time. */
    if (state->phase == UGPhaseUsage) state->lastWall = now;
}

int ug_tick(UGState *state, long long now, int screenOn, int unlocked)
{
    long long delta;

    if (!state) return UGEventNone;

    if (now < state->lastWall) {
        /* Clock stepped backwards: forget the gap instead of crediting it. */
        state->lastWall = now;
        return UGEventNone;
    }

    if (state->overrideUntil > 0) {
        if (now < state->overrideUntil) {
            state->lastWall = now; /* whole cycle frozen */
            return UGEventNone;
        }
        state->overrideUntil = 0;
        state->lastWall = now; /* do not credit the paused interval */
        return UGEventOverrideEnded;
    }

    if (!state->enabled) {
        state->lastWall = now;
        return UGEventNone;
    }

    delta = now - state->lastWall;
    state->lastWall = now;

    if (state->phase == UGPhaseBreak) {
        if (delta > state->remaining) delta = state->remaining;
        state->remaining -= delta;
        if (state->remaining <= 0) {
            state->phase = UGPhaseUsage;
            state->remaining = (long long)state->usageMinutes * 60LL;
            return UGEventBreakEnded;
        }
        return UGEventNone;
    }

    if (!screenOn || !unlocked) return UGEventNone;

    if (delta > UG_MAX_CREDIT_SECONDS) delta = UG_MAX_CREDIT_SECONDS;
    if (delta > state->remaining) delta = state->remaining;
    state->remaining -= delta;
    if (state->remaining <= 0) {
        state->phase = UGPhaseBreak;
        state->remaining = (long long)state->breakMinutes * 60LL;
        return UGEventBreakBegan;
    }
    return UGEventNone;
}

int ug_is_locked(const UGState *state, long long now)
{
    if (!state) return 0;
    if (!state->enabled) return 0;
    if (state->phase != UGPhaseBreak) return 0;
    if (state->remaining <= 0) return 0;
    return !ug_is_overridden(state, now);
}

int ug_is_overridden(const UGState *state, long long now)
{
    if (!state) return 0;
    return state->overrideUntil > now;
}

long long ug_override_remaining(const UGState *state, long long now)
{
    long long remaining;
    if (!state || state->overrideUntil <= 0) return 0;
    remaining = state->overrideUntil - now;
    return remaining > 0 ? remaining : 0;
}

void ug_reset(UGState *state, long long now)
{
    if (!state) return;
    state->phase = UGPhaseUsage;
    state->remaining = (long long)state->usageMinutes * 60LL;
    state->lastWall = now;
    state->overrideUntil = 0;
}

void ug_start_break(UGState *state, long long now)
{
    if (!state) return;
    state->phase = UGPhaseBreak;
    state->remaining = (long long)state->breakMinutes * 60LL;
    state->lastWall = now;
    state->overrideUntil = 0;
}

void ug_pause(UGState *state, long long now, int minutes)
{
    if (!state) return;
    minutes = ug_clamp_int(minutes, UG_MIN_MINUTES, UG_MAX_MINUTES);
    state->overrideUntil = now + (long long)minutes * 60LL;
    state->lastWall = now;
}

void ug_resume(UGState *state, long long now)
{
    if (!state) return;
    state->overrideUntil = 0;
    state->lastWall = now;
}

void ug_set_enabled(UGState *state, int enabled, long long now)
{
    if (!state) return;
    state->enabled = enabled ? 1 : 0;
    state->lastWall = now;
}

void ug_set_usage_minutes(UGState *state, int minutes)
{
    if (!state) return;
    state->usageMinutes = ug_clamp_int(minutes, UG_MIN_MINUTES, UG_MAX_MINUTES);
    if (state->phase == UGPhaseUsage &&
        state->remaining > (long long)state->usageMinutes * 60LL) {
        state->remaining = (long long)state->usageMinutes * 60LL;
    }
}

void ug_set_break_minutes(UGState *state, int minutes)
{
    if (!state) return;
    state->breakMinutes = ug_clamp_int(minutes, UG_MIN_MINUTES, UG_MAX_MINUTES);
    if (state->phase == UGPhaseBreak &&
        state->remaining > (long long)state->breakMinutes * 60LL) {
        state->remaining = (long long)state->breakMinutes * 60LL;
    }
}

size_t ug_serialize(const UGState *state, char *buffer, size_t capacity)
{
    int written;

    if (!state || !buffer || capacity == 0) return 0;

    written = snprintf(buffer, capacity,
                       "v=1;enabled=%d;phase=%d;usage=%d;brk=%d;"
                       "rem=%lld;last=%lld;ovr=%lld;",
                       state->enabled ? 1 : 0,
                       state->phase == UGPhaseBreak ? 1 : 0,
                       state->usageMinutes,
                       state->breakMinutes,
                       state->remaining,
                       state->lastWall,
                       state->overrideUntil);
    if (written < 0 || (size_t)written >= capacity) {
        buffer[0] = '\0';
        return 0;
    }
    return (size_t)written;
}

static int ug_key_equals(const char *key, size_t keyLength, const char *literal)
{
    size_t literalLength = strlen(literal);
    return keyLength == literalLength && memcmp(key, literal, keyLength) == 0;
}

static int ug_key_is_known(const char *key, size_t length)
{
    static const char *const keys[] = {
        "v", "enabled", "phase", "usage", "brk", "rem", "last", "ovr"
    };
    size_t index;

    for (index = 0; index < sizeof(keys) / sizeof(keys[0]); index++) {
        if (ug_key_equals(key, length, keys[index])) return 1;
    }
    return 0;
}

static int ug_parse_long_long(const char *text, size_t length, long long *out)
{
    size_t index = 0;
    int negative = 0;
    long long value = 0;
    int digits = 0;

    if (length == 0) return 0;
    if (text[0] == '-') {
        negative = 1;
        index = 1;
    }
    for (; index < length; index++) {
        int digit;
        if (text[index] < '0' || text[index] > '9') return 0;
        digit = text[index] - '0';
        if (value > 1000000000000LL) return 0;
        value = value * 10 + digit;
        digits++;
    }
    if (digits == 0) return 0;
    *out = negative ? -value : value;
    return 1;
}

int ug_deserialize(UGState *state, const char *text, long long now)
{
    UGState parsed;
    const char *cursor;
    int sawVersion = 0;

    if (!state || !text) return 0;
    if (strlen(text) == 0 || strlen(text) >= UG_STATE_BUFFER_SIZE) return 0;

    parsed = *state;
    cursor = text;

    while (*cursor) {
        const char *fieldEnd = cursor;
        const char *equals;
        long long value;

        while (*fieldEnd && *fieldEnd != ';') fieldEnd++;
        if (fieldEnd == cursor) {
            cursor = (*fieldEnd == ';') ? fieldEnd + 1 : fieldEnd;
            continue;
        }

        equals = cursor;
        while (equals < fieldEnd && *equals != '=') equals++;
        if (equals == fieldEnd) return 0;

        /* Unknown keys are skipped without touching their value, so a newer
         * version can add fields without making older readers discard state. */
        if (!ug_key_is_known(cursor, (size_t)(equals - cursor))) {
            cursor = (*fieldEnd == ';') ? fieldEnd + 1 : fieldEnd;
            continue;
        }

        if (!ug_parse_long_long(equals + 1, (size_t)(fieldEnd - equals - 1), &value)) {
            return 0;
        }

        if (ug_key_equals(cursor, (size_t)(equals - cursor), "v")) {
            if (value != 1) return 0;
            sawVersion = 1;
        } else if (ug_key_equals(cursor, (size_t)(equals - cursor), "enabled")) {
            parsed.enabled = value ? 1 : 0;
        } else if (ug_key_equals(cursor, (size_t)(equals - cursor), "phase")) {
            if (value != UGPhaseUsage && value != UGPhaseBreak) return 0;
            parsed.phase = (int)value;
        } else if (ug_key_equals(cursor, (size_t)(equals - cursor), "usage")) {
            parsed.usageMinutes = ug_clamp_int((int)value, UG_MIN_MINUTES, UG_MAX_MINUTES);
        } else if (ug_key_equals(cursor, (size_t)(equals - cursor), "brk")) {
            parsed.breakMinutes = ug_clamp_int((int)value, UG_MIN_MINUTES, UG_MAX_MINUTES);
        } else if (ug_key_equals(cursor, (size_t)(equals - cursor), "rem")) {
            parsed.remaining = value;
        } else if (ug_key_equals(cursor, (size_t)(equals - cursor), "last")) {
            parsed.lastWall = value;
        } else if (ug_key_equals(cursor, (size_t)(equals - cursor), "ovr")) {
            parsed.overrideUntil = value > 0 ? value : 0;
        }

        cursor = (*fieldEnd == ';') ? fieldEnd + 1 : fieldEnd;
    }

    if (!sawVersion) return 0;
    if (parsed.phase != UGPhaseUsage && parsed.phase != UGPhaseBreak) return 0;
    if (parsed.remaining < 0) parsed.remaining = 0;
    if (parsed.remaining > ug_phase_seconds(&parsed)) {
        parsed.remaining = ug_phase_seconds(&parsed);
    }
    if (parsed.lastWall <= 0) parsed.lastWall = now;
    if (parsed.overrideUntil < 0) parsed.overrideUntil = 0;

    *state = parsed;
    return 1;
}

size_t ug_format_mmss(long long seconds, char *buffer, size_t capacity)
{
    int written;
    long long minutes;

    if (!buffer || capacity == 0) return 0;
    if (seconds < 0) seconds = 0;
    minutes = seconds / 60LL;
    written = snprintf(buffer, capacity, "%02lld:%02lld", minutes, seconds % 60LL);
    if (written < 0 || (size_t)written >= capacity) {
        buffer[0] = '\0';
        return 0;
    }
    return (size_t)written;
}
