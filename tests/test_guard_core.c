/*
 * test_guard_core.c - host-side tests for the pure C cycle engine.
 * Plain C, no framework: every check returns a failure line on violation.
 */

#include <stdio.h>
#include <string.h>

#include "UGGuardCore.h"

static int failures = 0;

#define CHECK(condition)                                                        \
    do {                                                                        \
        if (!(condition)) {                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition);\
            failures++;                                                         \
            return;                                                             \
        }                                                                       \
    } while (0)

/* Feeds one tick per simulated second so the per-tick credit cap never hides
 * a behaviour under test. Returns the OR of all events produced. */
static int advance(UGState *state, long long *now, long long seconds,
                   int screenOn, int unlocked)
{
    long long index;
    int events = UGEventNone;
    for (index = 0; index < seconds; index++) {
        *now += 1;
        events |= ug_tick(state, *now, screenOn, unlocked);
    }
    return events;
}

static void test_full_cycle_wrap(void)
{
    UGState state;
    long long now = 1000000;
    int events;

    ug_state_defaults(&state, now);
    CHECK(state.enabled == 1);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);

    events = advance(&state, &now, 1199, 1, 1);
    CHECK(events == UGEventNone);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 1);

    events = advance(&state, &now, 1, 1, 1);
    CHECK(events == UGEventBreakBegan);
    CHECK(state.phase == UGPhaseBreak);
    CHECK(state.remaining == 30 * 60);
    CHECK(ug_is_locked(&state, now));

    /* The screen being on during a break must not shorten it. */
    events = advance(&state, &now, 300, 1, 1);
    CHECK(events == UGEventNone);
    CHECK(state.remaining == 30 * 60 - 300);
    CHECK(ug_is_locked(&state, now));

    now += 30 * 60 - 300;
    events = ug_tick(&state, now, 1, 1);
    CHECK(events == UGEventBreakEnded);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);
    CHECK(!ug_is_locked(&state, now));

    /* A second full loop still works. */
    events = advance(&state, &now, 20 * 60, 1, 1) |
             advance(&state, &now, 30 * 60, 0, 0);
    CHECK((events & UGEventBreakBegan) != 0);
    CHECK((events & UGEventBreakEnded) != 0);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);
}

static void test_usage_gating(void)
{
    UGState state;
    long long now = 2000000;

    ug_state_defaults(&state, now);

    advance(&state, &now, 300, 0, 1); /* screen off */
    CHECK(state.remaining == 20 * 60);
    CHECK(state.lastWall == now);

    advance(&state, &now, 300, 1, 0); /* locked */
    CHECK(state.remaining == 20 * 60);
    CHECK(state.lastWall == now);

    advance(&state, &now, 300, 0, 0); /* screen off and locked */
    CHECK(state.remaining == 20 * 60);

    ug_set_enabled(&state, 0, now);
    advance(&state, &now, 300, 1, 1); /* tweak disabled */
    CHECK(state.remaining == 20 * 60);
    CHECK(state.lastWall == now);

    ug_set_enabled(&state, 1, now);
    advance(&state, &now, 10, 1, 1);
    CHECK(state.remaining == 20 * 60 - 10);
}

static void test_override_pause_resume(void)
{
    UGState state;
    UGState breaking;
    long long now = 3000000;
    int events;

    ug_state_defaults(&state, now);
    advance(&state, &now, 100, 1, 1);
    CHECK(state.remaining == 20 * 60 - 100);

    ug_pause(&state, now, 15);
    CHECK(ug_is_overridden(&state, now));
    CHECK(ug_override_remaining(&state, now) == 15 * 60);

    events = advance(&state, &now, 60, 1, 1);
    CHECK(events == UGEventNone);
    CHECK(state.remaining == 20 * 60 - 100); /* frozen while overridden */
    CHECK(ug_override_remaining(&state, now) == 14 * 60);

    events = advance(&state, &now, 14 * 60, 1, 1);
    CHECK(events == UGEventOverrideEnded);
    CHECK(!ug_is_overridden(&state, now));
    CHECK(state.remaining == 20 * 60 - 100); /* resumes exactly where paused */

    advance(&state, &now, 10, 1, 1);
    CHECK(state.remaining == 20 * 60 - 110);

    /* Override also hides a running break and freezes its countdown. */
    ug_state_defaults(&breaking, now);
    ug_start_break(&breaking, now);
    CHECK(ug_is_locked(&breaking, now));
    ug_pause(&breaking, now, 30);
    CHECK(!ug_is_locked(&breaking, now));
    CHECK(ug_override_remaining(&breaking, now) == 30 * 60);
    advance(&breaking, &now, 30 * 60, 0, 0);
    /* The shared clock advanced past the override; the break must still be
     * at its full duration because nothing was consumed while paused. */
    CHECK(breaking.remaining == 30 * 60);
    CHECK(ug_is_locked(&breaking, now));
}

static void test_resume_clears_pause(void)
{
    UGState state;
    long long now = 3100000;

    ug_state_defaults(&state, now);
    advance(&state, &now, 100, 1, 1);
    CHECK(state.remaining == 20 * 60 - 100);

    ug_pause(&state, now, 30);
    CHECK(state.overrideUntil == now + 30 * 60);
    CHECK(ug_is_overridden(&state, now));

    advance(&state, &now, 10 * 60, 1, 1);
    CHECK(state.remaining == 20 * 60 - 100); /* frozen by the pause */
    CHECK(ug_is_overridden(&state, now));

    ug_resume(&state, now);
    CHECK(state.overrideUntil == 0);
    CHECK(!ug_is_overridden(&state, now));
    CHECK(ug_override_remaining(&state, now) == 0);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60 - 100); /* resume credits no downtime */

    advance(&state, &now, 5, 1, 1);
    CHECK(state.remaining == 20 * 60 - 105); /* usage accrues normally again */

    /* Clearing an already cleared pause is harmless. */
    ug_resume(&state, now);
    CHECK(state.overrideUntil == 0);
    CHECK(state.remaining == 20 * 60 - 105);
}

static void test_resume_without_pause_changes_nothing(void)
{
    UGState state;
    UGState before;
    long long now = 3200000;

    ug_state_defaults(&state, now);
    advance(&state, &now, 30, 1, 1);
    before = state;

    ug_resume(&state, now);

    CHECK(state.enabled == before.enabled);
    CHECK(state.phase == before.phase);
    CHECK(state.usageMinutes == before.usageMinutes);
    CHECK(state.breakMinutes == before.breakMinutes);
    CHECK(state.remaining == before.remaining);
    CHECK(state.lastWall == before.lastWall);
    CHECK(state.overrideUntil == 0);
    CHECK(before.overrideUntil == 0);
}

static void test_reset_and_start_break(void)
{
    UGState state;
    long long now = 4000000;

    ug_state_defaults(&state, now);
    advance(&state, &now, 500, 1, 1);
    CHECK(state.remaining == 20 * 60 - 500);

    ug_reset(&state, now);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);
    CHECK(state.overrideUntil == 0);
    CHECK(!ug_is_locked(&state, now));

    ug_start_break(&state, now);
    CHECK(state.phase == UGPhaseBreak);
    CHECK(state.remaining == 30 * 60);
    CHECK(ug_is_locked(&state, now));

    ug_reset(&state, now);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);
    CHECK(!ug_is_locked(&state, now));
}

static void test_clock_jumps(void)
{
    UGState state;
    long long now = 5000000;
    long long jumped;

    /* At 1 Hz the per-tick credit must stay small enough that a resumed phone
     * cannot be handed a free minute. */
    CHECK(UG_MAX_CREDIT_SECONDS <= 2);

    ug_state_defaults(&state, now);

    jumped = now + 100000;
    ug_tick(&state, jumped, 1, 1);
    CHECK(state.remaining == 20 * 60 - UG_MAX_CREDIT_SECONDS);
    now = jumped;

    now += 1;
    ug_tick(&state, now, 1, 1);
    CHECK(state.remaining == 20 * 60 - UG_MAX_CREDIT_SECONDS - 1);

    /* Clock stepped backwards: nothing is credited and time restarts now. */
    now -= 5000;
    ug_tick(&state, now, 1, 1);
    CHECK(state.remaining == 20 * 60 - UG_MAX_CREDIT_SECONDS - 1);
    CHECK(state.lastWall == now);

    advance(&state, &now, 10, 1, 1);
    CHECK(state.remaining == 20 * 60 - UG_MAX_CREDIT_SECONDS - 11);

    /* A huge forward jump during a break ends it without overflowing. */
    ug_start_break(&state, now);
    jumped = now + 999999;
    ug_tick(&state, jumped, 1, 1);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);
    now = jumped;
    ug_tick(&state, now + 1, 1, 1);
    CHECK(state.remaining == 20 * 60 - 1);
}

/* Regression: a parent override must expire at its exact wall-clock end, so
 * the break it paused still ends on time. The old engine rewound the clock to
 * "now" on expiry and handed out a brand new break countdown. */
static void test_override_expiry_keeps_real_time(void)
{
    UGState state;
    long long now = 5500000;
    int events;

    ug_state_defaults(&state, now);
    ug_start_break(&state, now);
    ug_pause(&state, now, 15);
    CHECK(!ug_is_locked(&state, now));

    /* 15 min override + 30 min break + 90 min extra, in one tick. */
    now += 15 * 60 + 30 * 60 + 90 * 60;
    events = ug_tick(&state, now, 0, 0);
    CHECK((events & UGEventOverrideEnded) != 0);
    CHECK((events & UGEventBreakEnded) != 0);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);
    CHECK(!ug_is_locked(&state, now));

    /* Same clock after a restart: the break fell due while the tweak was down
     * and must not restart from a full countdown. */
    ug_state_defaults(&state, now);
    ug_start_break(&state, now);
    ug_pause(&state, now, 15);
    ug_state_startup(&state, now + 7200);
    events = ug_tick(&state, now + 7200, 0, 0);
    CHECK((events & UGEventOverrideEnded) != 0);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);

    /* Override expiring during a usage phase credits only the time after it,
     * still bounded by the per-tick credit cap. */
    ug_state_defaults(&state, now);
    advance(&state, &now, 100, 1, 1);
    ug_pause(&state, now, 15);
    now += 15 * 60 + 10;
    events = ug_tick(&state, now, 1, 1);
    CHECK((events & UGEventOverrideEnded) != 0);
    CHECK(state.remaining == 20 * 60 - 100 - UG_MAX_CREDIT_SECONDS);
}

/* Regression: setting the clock back must not extend an override. */
static void test_backward_clock_does_not_extend_override(void)
{
    UGState state;
    long long now = 1700000000; /* realistic wall clock, a year back stays > 0 */

    ug_state_defaults(&state, now);
    advance(&state, &now, 60, 1, 1);
    ug_pause(&state, now, 15);
    CHECK(ug_override_remaining(&state, now) == 15 * 60);

    /* The overlay is hidden during an override, so the child can reach
     * Settings and set the clock back a year. The override keeps the quarter
     * of an hour it had left; it is not re-anchored a year into the future. */
    now -= 365LL * 24 * 60 * 60;
    ug_tick(&state, now, 1, 1);
    CHECK(ug_is_overridden(&state, now));
    CHECK(ug_override_remaining(&state, now) == 15 * 60);

    /* Once those 15 minutes of the *new* clock pass, usage resumes: the year
     * the child wound back buys nothing. */
    advance(&state, &now, 15 * 60 + 600, 1, 1);
    CHECK(!ug_is_overridden(&state, now));
    CHECK(state.remaining == 20 * 60 - 60 - 600);

    /* A smaller backward jump is handled the same way: 15 minutes stay 15
     * minutes instead of growing to 20. */
    ug_pause(&state, now, 15);
    now -= 300;
    ug_tick(&state, now, 1, 1);
    CHECK(ug_override_remaining(&state, now) == 15 * 60);
    CHECK(state.lastWall == now);
}

static void test_rollback_before_restart_keeps_pause(void)
{
    UGState paused;
    UGState restored;
    char buffer[UG_STATE_BUFFER_SIZE];
    long long now = 1700000000;
    long long back;
    long long left;

    /* Parent pauses during a usage phase with 15 minutes on the clock. */
    ug_state_defaults(&paused, now);
    paused.remaining = 20 * 60 - 100;
    ug_pause(&paused, now, 15);
    CHECK(ug_override_remaining(&paused, now) == 900);

    /* The forced write lands before the child touches the clock. */
    CHECK(ug_tick(&paused, now, 1, 1) == UGEventNone);
    CHECK(ug_serialize(&paused, buffer, sizeof buffer) > 0);
    CHECK(strstr(buffer, "ovr=1700000900;") != NULL);
    CHECK(strstr(buffer, "last=1700000000;") != NULL);

    /* The clock is wound back a year and the device reboots without locking
     * first. The stale string is loaded, so the pause must keep the 900 s it
     * had left instead of stretching to the 240-minute clamp. */
    back = now - 365LL * 24 * 60 * 60;
    ug_state_defaults(&restored, back);
    CHECK(ug_deserialize(&restored, buffer, back) == 1);
    CHECK(restored.overrideUntil == now + 900);

    ug_state_startup(&restored, back);
    left = ug_override_remaining(&restored, back);
    CHECK(left == 900);
    CHECK(left <= (long long)UG_MAX_MINUTES * 60LL);
    CHECK(restored.remaining == 20 * 60 - 100);

    /* The re-anchored pause still freezes usage, and only the pause elapses. */
    CHECK(ug_is_overridden(&restored, back + 100));
    CHECK(ug_tick(&restored, back + 100, 1, 1) == UGEventNone);
    CHECK(restored.remaining == 20 * 60 - 100);
    CHECK(!ug_is_locked(&restored, back + 100));

    /* The startup re-anchor on its own: a stale in-memory lastWall must not
     * turn the leftover pause into a year either. */
    {
        UGState stale;

        ug_state_defaults(&stale, now);
        stale.remaining = 20 * 60 - 100;
        ug_pause(&stale, now, 15);
        CHECK(ug_tick(&stale, now, 1, 1) == UGEventNone);
        ug_state_startup(&stale, back);
        CHECK(ug_override_remaining(&stale, back) == 900);
        CHECK(stale.remaining == 20 * 60 - 100);
    }
}

static void test_rollback_clamp_uses_saved_clock(void)
{
    UGState state;
    long long now = 1700000000;
    long long back = now - 365LL * 24 * 60 * 60;

    /* The longest grant is capped relative to the clock the file was written
     * under, never relative to the rolled-back clock that reads it. */
    ug_state_defaults(&state, back);
    CHECK(ug_deserialize(&state,
                         "v=1;enabled=1;phase=0;usage=20;brk=30;rem=1100;"
                         "last=1700000100;ovr=999999999999;",
                         back) == 1);
    CHECK(state.overrideUntil ==
          1700000100 + (long long)UG_MAX_MINUTES * 60LL);
    /* Measured from the writer's clock, not from the rolled-back `now`. */
    CHECK(state.overrideUntil != now + (long long)UG_MAX_MINUTES * 60LL);
}

/* Regression: the 1 Hz timer stops while the phone sleeps; the first tick
 * after wake must not credit the whole sleep (or a free minute of it). */
static void test_sleep_does_not_credit_usage(void)
{
    UGState state;
    long long now = 5700000;

    ug_state_defaults(&state, now);
    advance(&state, &now, 100, 1, 1);
    CHECK(state.remaining == 20 * 60 - 100);

    now += 3600; /* asleep for an hour, one tick on wake */
    ug_tick(&state, now, 1, 1);
    CHECK(state.remaining == 20 * 60 - 100 - 2);

    now += 30; /* a late timer tick is bounded the same way */
    ug_tick(&state, now, 1, 1);
    CHECK(state.remaining == 20 * 60 - 100 - 4);
}

/* Regression: unlocking the phone must not donate the per-tick credit cap.
 * The timer does not run while the device sleeps, so the first awake tick used
 * to spend up to UG_MAX_CREDIT_SECONDS of the inactive gap as usage. */
static void test_reactivation_credits_no_free_usage(void)
{
    UGState state;
    long long now = 9400000;

    /* Locked-but-awake gap: 1 Hz inactive ticks credit nothing, then the
     * reactivation re-anchor must leave exactly the following second to count. */
    ug_state_defaults(&state, now);
    state.remaining = 1200;
    advance(&state, &now, 3600, 0, 0);
    CHECK(state.remaining == 1200);

    ug_rebase_last_wall(&state, now);
    CHECK(state.lastWall == now);

    now += 1;
    CHECK(ug_tick(&state, now, 1, 1) == UGEventNone);
    CHECK(state.remaining == 1199); /* exactly 1 s, not 2 or 3 */

    /* Sleep gap: no ticks ran at all. The re-anchor applied on reactivation
     * still leaves the first awake second to cost exactly one second. */
    ug_state_defaults(&state, 9500000);
    state.remaining = 1200;
    now = 9503600;
    ug_rebase_last_wall(&state, now);
    now += 1;
    CHECK(ug_tick(&state, now, 1, 1) == UGEventNone);
    CHECK(state.remaining == 1199);

    /* Without the re-anchor the same reactivation hands out the credit cap:
     * that donation is exactly what the helper removes. */
    ug_state_defaults(&state, 9600000);
    state.remaining = 1200;
    now = 9603600; /* woke up, no tick while asleep */
    now += 1;
    ug_tick(&state, now, 1, 1);
    CHECK(state.remaining == 1200 - UG_MAX_CREDIT_SECONDS);

    /* A break elapses in real time, so the re-anchor must not touch it. */
    ug_state_defaults(&state, 9700000);
    ug_start_break(&state, 9700000);
    ug_rebase_last_wall(&state, 9700010);
    CHECK(state.lastWall == 9700000);
    CHECK(state.remaining == 30 * 60);
}

static void test_startup_restore(void)
{
    UGState state;
    long long now = 6000000;

    /* Interrupted usage phase: downtime is not credited. */
    ug_state_defaults(&state, now);
    state.remaining = 600;
    state.lastWall = now - 3600;
    ug_state_startup(&state, now);
    ug_tick(&state, now, 1, 1);
    CHECK(state.remaining == 600);
    CHECK(state.lastWall == now);

    /* Interrupted break: real elapsed time is applied. */
    ug_state_defaults(&state, now);
    state.phase = UGPhaseBreak;
    state.remaining = 30 * 60;
    state.lastWall = now - 3600;
    ug_state_startup(&state, now);
    ug_tick(&state, now, 0, 0);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);

    /* Partially elapsed break keeps the remainder left at the last tick. */
    ug_state_defaults(&state, now);
    state.phase = UGPhaseBreak;
    state.remaining = 1800;
    state.lastWall = now - 600;
    ug_state_startup(&state, now);
    ug_tick(&state, now, 0, 0);
    CHECK(state.phase == UGPhaseBreak);
    CHECK(state.remaining == 1200);
}

static void test_serialization_round_trip(void)
{
    UGState original;
    UGState restored;
    char buffer[UG_STATE_BUFFER_SIZE];
    char small[8];
    size_t length;

    memset(&original, 0, sizeof original);
    ug_state_defaults(&original, 7000000);
    original.phase = UGPhaseBreak;
    original.usageMinutes = 25;
    original.breakMinutes = 45;
    original.remaining = 777;
    original.lastWall = 7000123;
    original.overrideUntil = 7000999;

    length = ug_serialize(&original, buffer, sizeof buffer);
    CHECK(length > 0);
    CHECK(length < UG_STATE_BUFFER_SIZE);
    CHECK(strlen(buffer) == length);
    CHECK(strstr(buffer, "v=1;") == buffer);

    memset(&restored, 0, sizeof restored);
    CHECK(ug_deserialize(&restored, buffer, 7000500) == 1);
    CHECK(restored.enabled == original.enabled);
    CHECK(restored.phase == original.phase);
    CHECK(restored.usageMinutes == original.usageMinutes);
    CHECK(restored.breakMinutes == original.breakMinutes);
    CHECK(restored.remaining == original.remaining);
    CHECK(restored.lastWall == original.lastWall);
    CHECK(restored.overrideUntil == original.overrideUntil);

    /* Same bytes again: serialization is deterministic. */
    {
        char again[UG_STATE_BUFFER_SIZE];
        CHECK(ug_serialize(&restored, again, sizeof again) == length);
        CHECK(memcmp(buffer, again, length) == 0);
    }

    /* Buffer accounting and corrupt input. */
    CHECK(ug_serialize(&original, small, sizeof small) == 0);
    CHECK(small[0] == '\0');
    CHECK(ug_serialize(&original, buffer, 0) == 0);
    CHECK(ug_serialize(NULL, buffer, sizeof buffer) == 0);

    ug_state_defaults(&restored, 8000000);
    CHECK(ug_deserialize(&restored, "", 8000000) == 0);
    CHECK(ug_deserialize(&restored, "garbage", 8000000) == 0);
    CHECK(ug_deserialize(&restored, "enabled=1;phase=0;", 8000000) == 0);
    CHECK(ug_deserialize(&restored, "v=2;enabled=1;", 8000000) == 0);
    CHECK(ug_deserialize(&restored, "v=1;phase=9;", 8000000) == 0);
    CHECK(ug_deserialize(&restored, "v=1;enabled=0;phase=1;usage=20;brk=30;", 8000000) == 1);
    CHECK(restored.enabled == 0);
    CHECK(restored.phase == UGPhaseBreak);
    CHECK(restored.remaining == 20 * 60); /* clamped to the break allowance */

    /* Unknown keys (including non-numeric ones) are skipped. */
    ug_state_defaults(&restored, 9000000);
    restored.usageMinutes = 33;
    CHECK(ug_deserialize(&restored, "v=1;future=hello;enabled=1;", 9000000) == 1);
    CHECK(restored.usageMinutes == 33);
    CHECK(restored.enabled == 1);

    /* Missing keys keep the caller's existing values. */
    ug_state_defaults(&restored, 9000000);
    restored.usageMinutes = 33;
    CHECK(ug_deserialize(&restored, "v=1;enabled=1;", 9000000) == 1);
    CHECK(restored.usageMinutes == 33);
    CHECK(restored.breakMinutes == 30);

    /* Out-of-range values are clamped, never trusted. */
    CHECK(ug_deserialize(&restored, "v=1;usage=0;brk=9999;", 9000000) == 1);
    CHECK(restored.usageMinutes == UG_MIN_MINUTES);
    CHECK(restored.breakMinutes == UG_MAX_MINUTES);

    /* A persisted override is capped at the longest pause a parent can grant. */
    CHECK(ug_deserialize(&restored, "v=1;ovr=999999999999;", 9000000) == 1);
    CHECK(restored.overrideUntil == 9000000 + (long long)UG_MAX_MINUTES * 60LL);
}

static void test_duration_changes(void)
{
    UGState state;
    long long now = 9100000;
    int events;

    ug_state_defaults(&state, now);
    CHECK(state.remaining == 1200);
    ug_set_usage_minutes(&state, 10);
    CHECK(state.remaining == 600);
    ug_set_usage_minutes(&state, 30);
    CHECK(state.remaining == 600); /* raising the limit does not re-credit */
    CHECK(state.usageMinutes == 30);

    ug_set_usage_minutes(&state, 0);
    CHECK(state.usageMinutes == UG_MIN_MINUTES);
    CHECK(state.remaining == 60); /* clamped to the new one-minute allowance */
    ug_set_usage_minutes(&state, 1000);
    CHECK(state.usageMinutes == UG_MAX_MINUTES);
    ug_set_usage_minutes(&state, 20);
    CHECK(state.usageMinutes == 20);

    ug_start_break(&state, now);
    CHECK(state.remaining == 30 * 60);
    ug_set_break_minutes(&state, 25);
    CHECK(state.remaining == 25 * 60);
    ug_set_break_minutes(&state, 60);
    CHECK(state.remaining == 25 * 60);
    CHECK(state.breakMinutes == 60);

    /* The next break uses the configured (not the previous) duration. */
    now += 25 * 60;
    events = ug_tick(&state, now, 1, 1);
    CHECK(events == UGEventBreakEnded);
    CHECK(state.phase == UGPhaseUsage);
    CHECK(state.remaining == 20 * 60);

    events = advance(&state, &now, 20 * 60, 1, 1);
    CHECK(events == UGEventBreakBegan);
    CHECK(state.remaining == 60 * 60);
}

static void test_disabled_break_freeze(void)
{
    UGState state;
    long long now = 9200000;

    ug_state_defaults(&state, now);
    ug_start_break(&state, now);
    ug_set_enabled(&state, 0, now);
    CHECK(!ug_is_locked(&state, now));

    advance(&state, &now, 100, 1, 1);
    CHECK(state.remaining == 30 * 60); /* break frozen while disabled */
    CHECK(!ug_is_locked(&state, now));

    ug_set_enabled(&state, 1, now);
    advance(&state, &now, 10, 1, 1);
    CHECK(state.remaining == 30 * 60 - 10);
    CHECK(ug_is_locked(&state, now));
}

static void test_override_helpers(void)
{
    UGState state;
    long long now = 9300000;

    ug_state_defaults(&state, now);
    CHECK(!ug_is_overridden(&state, now));
    CHECK(ug_override_remaining(&state, now) == 0);

    ug_pause(&state, now, 1);
    CHECK(ug_override_remaining(&state, now) == 60);
    CHECK(ug_is_overridden(&state, now));

    /* The helper reports zero exactly when the override is over. */
    now += 60;
    CHECK(!ug_is_overridden(&state, now));
    CHECK(ug_override_remaining(&state, now) == 0);

    advance(&state, &now, 5, 1, 1);
    CHECK(state.remaining == 20 * 60 - 5);
}

static void test_mmss_formatting(void)
{
    char buffer[16];
    char small[4];

    CHECK(ug_format_mmss(0, buffer, sizeof buffer) == 5);
    CHECK(strcmp(buffer, "00:00") == 0);
    CHECK(ug_format_mmss(59, buffer, sizeof buffer) == 5);
    CHECK(strcmp(buffer, "00:59") == 0);
    CHECK(ug_format_mmss(60, buffer, sizeof buffer) == 5);
    CHECK(strcmp(buffer, "01:00") == 0);
    CHECK(ug_format_mmss(1200, buffer, sizeof buffer) == 5);
    CHECK(strcmp(buffer, "20:00") == 0);
    CHECK(ug_format_mmss(3599, buffer, sizeof buffer) == 5);
    CHECK(strcmp(buffer, "59:59") == 0);
    CHECK(ug_format_mmss(14400, buffer, sizeof buffer) == 6);
    CHECK(strcmp(buffer, "240:00") == 0);
    CHECK(ug_format_mmss(-5, buffer, sizeof buffer) == 5);
    CHECK(strcmp(buffer, "00:00") == 0);
    CHECK(ug_format_mmss(1200, small, sizeof small) == 0);
    CHECK(small[0] == '\0');
    CHECK(ug_format_mmss(1200, buffer, 0) == 0);
}

int main(void)
{
    test_full_cycle_wrap();
    test_usage_gating();
    test_override_pause_resume();
    test_resume_clears_pause();
    test_resume_without_pause_changes_nothing();
    test_reset_and_start_break();
    test_clock_jumps();
    test_override_expiry_keeps_real_time();
    test_backward_clock_does_not_extend_override();
    test_rollback_before_restart_keeps_pause();
    test_rollback_clamp_uses_saved_clock();
    test_sleep_does_not_credit_usage();
    test_reactivation_credits_no_free_usage();
    test_startup_restore();
    test_serialization_round_trip();
    test_duration_changes();
    test_disabled_break_freeze();
    test_override_helpers();
    test_mmss_formatting();

    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("all core checks passed\n");
    return 0;
}
