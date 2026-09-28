// All attendance rules are tunable here. Mirrored in app/lib/domain/policy.dart.
export interface Policy {
  /** START window stays open this long after max(actualStart, scheduledStart). */
  startWindowMin: number;
  /** Length of each random MID check window. */
  midWindowMin: number;
  /** END window: the last N minutes before the planned end. */
  endWindowMin: number;
  /** If the teacher ends early, END stays open this long after they tap End. */
  earlyEndWindowMin: number;
  /** MID checks never fall within this margin of START or END. */
  midMarginMin: number;
  /** One MID check per this many scheduled minutes (at least one). */
  midEveryMin: number;
  /** Fixed number of random MID checks (0–3) chosen by the teacher; null = by class length. */
  midChecks: number | null;
  /** Teacher may start this many minutes before the scheduled start. */
  teacherEarlyStartMin: number;
  /** A timetabled session cannot start once fewer than this many minutes remain. */
  minSessionMin: number;
  /** Tell students the teacher hasn't started after this many minutes. */
  studentLateNoticeMin: number;
  /** Remind the teacher (their class started but attendance didn't) after this many minutes. */
  teacherReminderMin: number;
  /** Close a session nobody ended this long after its planned end. */
  autoCloseAfterMin: number;
  /**
   * START stays open until this long after `quorumShare` of the class has checked in, so an
   * auto-started session with a late teacher does not mark the whole class late.
   */
  startAfterQuorumMin: number;
  quorumShare: number;
  /** In a class at least this big, a check that *nobody* passed is treated as not run. */
  zeroPassMinRoster: number;
  /** A check "ran" if the teacher phone was active for at least this share of its window. */
  minWindowCoverage: number;
  /** Manual "present without phone" marks allowed per student per section per term. */
  manualQuotaPerTerm: number;
  /** Cooldown before a device change is auto-approved. */
  deviceChangeCooldownHours: number;
  /** Students may dispute a record for this long after the session ends. */
  disputeWindowHours: number;
  /** Below this share, students get a low-attendance warning. */
  lowAttendanceThreshold: number;
  /** How each status counts towards the attendance percentage. EXCUSED is left out of the total. */
  weights: Record<'PRESENT' | 'LATE' | 'LEFT_EARLY' | 'FLAGGED' | 'ABSENT' | 'MANUAL' | 'UNVERIFIED', number>;
}

export const DEFAULT_POLICY: Policy = {
  startWindowMin: 10,
  midWindowMin: 2,
  endWindowMin: 10,
  earlyEndWindowMin: 3,
  midMarginMin: 15,
  midEveryMin: 50,
  midChecks: null,
  teacherEarlyStartMin: 10,
  minSessionMin: 20,
  studentLateNoticeMin: 10,
  teacherReminderMin: 20,
  autoCloseAfterMin: 15,
  startAfterQuorumMin: 5,
  quorumShare: 0.25,
  zeroPassMinRoster: 5,
  minWindowCoverage: 0.5,
  manualQuotaPerTerm: 3,
  deviceChangeCooldownHours: 48,
  disputeWindowHours: 72,
  lowAttendanceThreshold: 0.75,
  weights: { PRESENT: 1, LATE: 1, LEFT_EARLY: 0.5, FLAGGED: 0, ABSENT: 0, MANUAL: 1, UNVERIFIED: 0 },
};

export const MIN = 60_000;

/** Settings a teacher may change per section, with the allowed range for each. */
export const TEACHER_PLAN_LIMITS = {
  midChecks: [0, 3],
  startWindowMin: [5, 30],
  endWindowMin: [3, 20],
} as const;
export type PlanOverrides = Partial<Record<keyof typeof TEACHER_PLAN_LIMITS, number>>;

export function clampPlan(o: Record<string, unknown> | null | undefined): PlanOverrides {
  const out: PlanOverrides = {};
  for (const [k, [lo, hi]] of Object.entries(TEACHER_PLAN_LIMITS) as [keyof typeof TEACHER_PLAN_LIMITS, readonly [number, number]][]) {
    const v = o?.[k];
    if (typeof v === 'number' && Number.isInteger(v)) out[k] = Math.min(hi, Math.max(lo, v));
  }
  return out;
}

export const withPlan = (p: Policy, o: PlanOverrides): Policy => ({ ...p, ...o });
