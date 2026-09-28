import { describe, expect, it } from 'vitest';
import { classView, evaluateStudent } from '../src/domain/evaluate.js';
import { currentPhase, planChecks, withExtraChecks, type SessionTimes } from '../src/domain/plan.js';
import { calendarLookup, type CalendarEntry, type Term } from '../src/domain/calendar.js';
import { clampPlan, DEFAULT_POLICY as P, MIN } from '../src/domain/policy.js';
import { expandTimetable, lifecycleActions, startAllowed, type TimetableSlot } from '../src/domain/schedule.js';

const secret = Buffer.alloc(32, 7);
const T0 = Date.UTC(2026, 8, 28, 4, 0); // 09:30 IST
const hour = (extra: Partial<SessionTimes> = {}): SessionTimes => ({
  scheduledStart: T0,
  scheduledEnd: T0 + 60 * MIN,
  actualStart: T0,
  actualEnd: null,
  plannedEnd: T0 + 60 * MIN,
  ...extra,
});
const fullActivity = (t: SessionTimes): [number, number][] => [[t.actualStart, t.actualEnd ?? t.plannedEnd]];

describe('planChecks', () => {
  it('normal 60 min class: START, one MID in the middle band, END', () => {
    const w = planChecks(secret, hour(), P);
    expect(w.map((x) => x.kind)).toEqual(['START', 'MID', 'END']);
    expect(w[0]).toMatchObject({ from: T0, to: T0 + 10 * MIN });
    expect(w[1].from).toBeGreaterThanOrEqual(T0 + 15 * MIN);
    expect(w[1].to).toBeLessThanOrEqual(T0 + 35 * MIN);
    expect(w[2]).toMatchObject({ from: T0 + 50 * MIN, to: T0 + 60 * MIN });
  });

  it('MID time depends on the secret (unpredictable)', () => {
    const a = planChecks(Buffer.alloc(32, 1), hour(), P)[1].from;
    const b = planChecks(Buffer.alloc(32, 2), hour(), P)[1].from;
    expect(a).not.toEqual(b);
  });

  it('teacher 12 min late: START window opens on arrival, students not punished', () => {
    const w = planChecks(secret, hour({ actualStart: T0 + 12 * MIN }), P);
    expect(w[0]).toMatchObject({ from: T0 + 12 * MIN, to: T0 + 22 * MIN });
    expect(w[1].from).toBeGreaterThanOrEqual(T0 + 27 * MIN);
  });

  it('teacher very late: no room for a MID, only START and END', () => {
    const w = planChecks(secret, hour({ actualStart: T0 + 35 * MIN }), P);
    expect(w.map((x) => x.kind)).toEqual(['START', 'END']);
  });

  it('teacher starts early: START window still runs to scheduled start + 10', () => {
    const w = planChecks(secret, hour({ actualStart: T0 - 8 * MIN }), P);
    expect(w[0]).toMatchObject({ from: T0 - 8 * MIN, to: T0 + 10 * MIN });
  });

  it('teacher ends early: END opens at the tap for 3 min, later MIDs dropped', () => {
    const w = planChecks(secret, hour({ actualEnd: T0 + 16 * MIN }), P);
    expect(w.map((x) => x.kind)).toEqual(['START', 'END']);
    expect(w[1]).toMatchObject({ from: T0 + 16 * MIN, to: T0 + 19 * MIN });
  });

  it('extension moves END but not the MID', () => {
    const base = planChecks(secret, hour(), P);
    const ext = planChecks(secret, hour({ plannedEnd: T0 + 75 * MIN }), P);
    expect(ext[1]).toEqual(base[1]);
    expect(ext[2]).toMatchObject({ from: T0 + 65 * MIN, to: T0 + 75 * MIN });
  });

  it('3 hour lab gets 3 MIDs, spread out', () => {
    const t = hour({ scheduledEnd: T0 + 180 * MIN, plannedEnd: T0 + 180 * MIN });
    const mids = planChecks(secret, t, P).filter((x) => x.kind === 'MID');
    expect(mids).toHaveLength(3);
    expect(mids[1].from - mids[0].from).toBeGreaterThan(10 * MIN);
  });

  it('currentPhase reports MID only inside the window', () => {
    const w = planChecks(secret, hour(), P);
    expect(currentPhase(w, w[1].from).phase).toBe('MID');
    expect(currentPhase(w, w[1].to).phase).toBe('ARRIVE');
    expect(currentPhase(w, T0 + 55 * MIN).phase).toBe('END');
  });
});

describe('evaluateStudent', () => {
  const t = hour();
  const w = planChecks(secret, t, P);
  const [S, M, E] = w;
  const ev = (times: number[], extra = {}) =>
    evaluateStudent(w, fullActivity(t), { checkinTimes: times, excused: false, manual: false, ...extra }, P);

  it('all three -> PRESENT', () => expect(ev([S.from + 1, M.from + 1, E.from + 1]).status).toBe('PRESENT'));
  it('missed START -> LATE', () => expect(ev([M.from + 1, E.from + 1]).status).toBe('LATE'));
  it('missed END -> LEFT_EARLY', () => expect(ev([S.from + 1, M.from + 1]).status).toBe('LEFT_EARLY'));
  it('missed MID -> FLAGGED', () => expect(ev([S.from + 1, E.from + 1]).status).toBe('FLAGGED'));
  it('only one -> ABSENT', () => expect(ev([S.from + 1]).status).toBe('ABSENT'));
  it('none -> ABSENT', () => expect(ev([]).status).toBe('ABSENT'));
  it('excused wins', () => expect(ev([], { excused: true }).status).toBe('EXCUSED'));
  it('manual mark', () => expect(ev([], { manual: true }).status).toBe('MANUAL'));

  it('teacher phone died after START: MID/END not run, student not punished', () => {
    const r = evaluateStudent(w, [[T0, T0 + 12 * MIN]], { checkinTimes: [S.from + 1], excused: false, manual: false }, P);
    expect(r.status).toBe('PRESENT');
    expect(r.reasons).toContain('MID check did not run');
  });

  it('teacher phone never active -> UNVERIFIED (needs teacher/admin)', () => {
    expect(evaluateStudent(w, [], { checkinTimes: [], excused: false, manual: false }, P).status).toBe('UNVERIFIED');
  });
});

describe('schedule', () => {
  const slots: TimetableSlot[] = [
    { id: 'a', sectionId: 'CS-A', teacherId: 't1', roomId: 'r1', weekday: 1, startMin: 570, endMin: 630, validFrom: '2026-07-01', validTo: '2026-12-31' },
    { id: 'b', sectionId: 'CS-B', teacherId: 't1', roomId: 'r1', weekday: 1, startMin: 570, endMin: 630, validFrom: '2026-07-01', validTo: '2026-12-31' },
    { id: 'c', sectionId: 'CS-A', teacherId: 't2', roomId: 'r2', weekday: 1, startMin: 630, endMin: 690, validFrom: '2026-07-01', validTo: '2026-12-31' },
  ];

  it('merges combined sections and uses local time', () => {
    const occ = expandTimetable(slots, '2026-09-28', '2026-09-28', 'Asia/Kolkata', new Set());
    expect(occ).toHaveLength(2);
    expect(occ[0].sectionIds).toEqual(['CS-A', 'CS-B']);
    expect(occ[0].scheduledStart).toBe(T0);
  });

  it('skips holidays and cancelled slots', () => {
    expect(expandTimetable(slots, '2026-09-28', '2026-09-28', 'Asia/Kolkata', new Set(['2026-09-28']))).toHaveLength(0);
    const occ = expandTimetable(slots, '2026-09-28', '2026-09-28', 'Asia/Kolkata', new Set(), new Set(['c@2026-09-28']));
    expect(occ).toHaveLength(1);
  });

  it('start rules', () => {
    const o = { scheduledStart: T0, scheduledEnd: T0 + 60 * MIN };
    expect(startAllowed(o, T0 - 11 * MIN, P).ok).toBe(false);
    expect(startAllowed(o, T0 + 25 * MIN, P).ok).toBe(true);
    expect(startAllowed(o, T0 + 41 * MIN, P).ok).toBe(false);
  });

  it('teacher late: notify students at +10, remind the teacher at +20, no-show at end-20', () => {
    const o = expandTimetable(slots, '2026-09-28', '2026-09-28', 'Asia/Kolkata', new Set())[0];
    expect(lifecycleActions(o, null, T0 + 5 * MIN, new Set(), P)).toEqual([]);
    expect(lifecycleActions(o, null, T0 + 10 * MIN, new Set(), P)).toEqual([{ type: 'NOTIFY_STUDENTS_TEACHER_LATE' }]);
    expect(lifecycleActions(o, null, T0 + 21 * MIN, new Set(['NOTIFY_STUDENTS_TEACHER_LATE']), P)).toEqual([
      { type: 'REMIND_TEACHER' },
    ]);
    expect(lifecycleActions(o, null, T0 + 40 * MIN, new Set(), P)).toEqual([{ type: 'MARK_TEACHER_NO_SHOW' }]);
  });

  it('forgotten session auto-closes at last activity', () => {
    const o = expandTimetable(slots, '2026-09-28', '2026-09-28', 'Asia/Kolkata', new Set())[0];
    const s = { state: 'ACTIVE' as const, actualEnd: null, plannedEnd: T0 + 60 * MIN, lastActivityAt: T0 + 30 * MIN };
    expect(lifecycleActions(o, s, T0 + 70 * MIN, new Set(), P)).toEqual([]);
    expect(lifecycleActions(o, s, T0 + 75 * MIN, new Set(), P)).toEqual([{ type: 'AUTO_CLOSE', at: T0 + 30 * MIN }]);
  });
});

describe('classView (auto-start with a late teacher)', () => {
  const t = hour();
  const w = planChecks(secret, t, P);
  const [, M, E] = w;
  const act = fullActivity(t);

  it('START extends to 5 min after a quarter of the class arrived', () => {
    // Phone auto-started at 09:30, teacher and class gathered at 09:44.
    // (The MID fell at ~09:50, before anyone arrived, so it is also treated as not run.)
    const arrivals = Array.from({ length: 8 }, (_, i) => [T0 + 44 * MIN + i * 20_000, E.from + 1]);
    expect(M.to).toBeLessThan(T0 + 44 * MIN);
    const view = classView(w, arrivals, 8, P);
    expect(view.windows[0].to).toBe(arrivals[1][0] + 5 * MIN); // quorum = 2 of 8
    const r = evaluateStudent(view, act, { checkinTimes: arrivals[7], excused: false, manual: false }, P);
    expect(r.status).toBe('PRESENT');
  });

  it('a MID that nobody passed does not count against anyone', () => {
    const times = Array.from({ length: 6 }, () => [T0 + 60_000, E.from + 1]);
    const view = classView(w, times, 6, P);
    expect(view.emptyWindows.has('MID0')).toBe(true);
    expect(evaluateStudent(view, act, { checkinTimes: times[0], excused: false, manual: false }, P).status).toBe('PRESENT');
  });

  it('small classes do not get the empty-window rule', () => {
    const times = [[T0 + 60_000, E.from + 1]];
    expect(evaluateStudent(classView(w, times, 1, P), act, { checkinTimes: times[0], excused: false, manual: false }, P).status).toBe('FLAGGED');
  });
});

describe('teacher controls in the plan', () => {
  it('teacher can choose 0 or 3 middle checks', () => {
    expect(planChecks(secret, hour(), { ...P, midChecks: 0 }).map((w) => w.kind)).toEqual(['START', 'END']);
    const lab = hour({ scheduledEnd: T0 + 120 * MIN, plannedEnd: T0 + 120 * MIN });
    expect(planChecks(secret, lab, { ...P, midChecks: 3 }).filter((w) => w.kind === 'MID')).toHaveLength(3);
  });

  it('surprise checks count like MIDs and are named in reasons', () => {
    const t = hour();
    const w = withExtraChecks(planChecks(secret, t, P), [[T0 + 40 * MIN, T0 + 42 * MIN]]);
    expect(w.map((x) => x.kind)).toEqual(['START', 'MID', 'MID', 'END']);
    const [S, M, , E] = w;
    const r = evaluateStudent(w, fullActivity(t), { checkinTimes: [S.from + 1, M.from + 1, E.from + 1], excused: false, manual: false }, P);
    expect(r.status).toBe('FLAGGED');
    expect(r.reasons).toContain('missed surprise check');
  });

  it('clampPlan keeps teacher settings inside limits', () => {
    expect(clampPlan({ midChecks: 9, startWindowMin: 1, endWindowMin: 12, other: 5 })).toEqual({ midChecks: 3, startWindowMin: 5, endWindowMin: 12 });
  });
});

describe('academic calendar', () => {
  const slots: TimetableSlot[] = [
    { id: 'a', sectionId: 'CS-A', teacherId: 't1', roomId: null, weekday: 1, startMin: 570, endMin: 630, validFrom: '2026-01-01', validTo: '2026-12-31' },
    { id: 'b', sectionId: 'EE-A', teacherId: 't2', roomId: null, weekday: 1, startMin: 570, endMin: 630, validFrom: '2026-01-01', validTo: '2026-12-31' },
  ];
  const ev = (e: Partial<CalendarEntry>): CalendarEntry => ({ kind: 'HOLIDAY', title: 'x', fromDate: '2026-09-28', toDate: '2026-09-28', noClasses: true, followsWeekday: null, sectionIds: [], ...e });
  const run = (entries: CalendarEntry[], date = '2026-09-28', terms: Term[] = []) =>
    expandTimetable(slots, date, date, 'Asia/Kolkata', calendarLookup(entries, terms)).map((o) => o.sectionIds[0]);

  it('holiday blocks everyone', () => expect(run([ev({})])).toEqual([]));
  it('exam for one section blocks only that section', () => expect(run([ev({ kind: 'EXAM', sectionIds: ['CS-A'] })])).toEqual(['EE-A']));
  it('event that keeps classes running blocks nothing', () => expect(run([ev({ kind: 'EVENT', noClasses: false })]).length).toBe(2));
  it('Saturday follows Monday timetable', () => {
    expect(run([], '2026-10-03')).toEqual([]);
    expect(run([ev({ kind: 'DAY_ORDER', fromDate: '2026-10-03', toDate: '2026-10-03', followsWeekday: 1 })], '2026-10-03').length).toBe(2);
  });
  it('no classes outside term dates', () => {
    expect(run([], '2026-09-28', [{ name: 'Odd sem', startDate: '2026-10-01', endDate: '2026-12-15' }])).toEqual([]);
    expect(run([], '2026-10-05', [{ name: 'Odd sem', startDate: '2026-10-01', endDate: '2026-12-15' }]).length).toBe(2);
  });
});
