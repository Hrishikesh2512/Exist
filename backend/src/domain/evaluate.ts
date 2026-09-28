// Turns the checks a student passed into a final status.
import { coverage, type CheckWindow, type Interval } from './plan.js';
import { MIN, type Policy } from './policy.js';

export type Status =
  | 'PRESENT'
  | 'LATE'
  | 'LEFT_EARLY'
  | 'FLAGGED'
  | 'ABSENT'
  | 'EXCUSED'
  | 'MANUAL'
  | 'UNVERIFIED';

export interface CheckResult {
  window: CheckWindow;
  ran: boolean;
  passed: boolean;
}

export interface Evaluation {
  status: Status;
  reasons: string[];
  checks: CheckResult[];
}

export interface StudentEvidence {
  /** receivedAt of every *valid* check-in by this student in this session. */
  checkinTimes: number[];
  excused: boolean;
  manual: boolean;
}

export interface ClassView {
  windows: CheckWindow[];
  /** Windows (by `${kind}${index}`) that count as not run because nobody passed them. */
  emptyWindows: Set<string>;
}

export const windowId = (w: CheckWindow) => `${w.kind}${w.index}`;

/**
 * Adjust the plan using the whole class's check-ins:
 *  - START closes no earlier than `startAfterQuorumMin` after a quorum arrived
 *    (teacher phone auto-started on time but the teacher/class gathered later);
 *  - a non-START check nobody passed did not really run (teacher out of the room,
 *    Bluetooth glitch), so it counts against no one.
 */
export function classView(windows: CheckWindow[], timesByStudent: number[][], rosterSize: number, p: Policy): ClassView {
  if (!windows.length) return { windows, emptyWindows: new Set() };
  const firsts = timesByStudent.filter((t) => t.length).map((t) => Math.min(...t)).sort((a, b) => a - b);
  const quorumN = Math.max(1, Math.ceil(rosterSize * p.quorumShare));
  const adjusted = windows.map((w) => ({ ...w }));
  const start = adjusted[0];
  const end = adjusted[adjusted.length - 1];
  if (firsts.length >= quorumN) {
    const close = firsts[quorumN - 1] + p.startAfterQuorumMin * MIN;
    start.to = Math.min(Math.max(start.to, close), end.from);
  }
  const emptyWindows = new Set<string>();
  if (rosterSize >= p.zeroPassMinRoster) {
    for (const w of adjusted.slice(1)) {
      if (!timesByStudent.some((ts) => ts.some((t) => t >= w.from && t < w.to))) emptyWindows.add(windowId(w));
    }
  }
  return { windows: adjusted, emptyWindows };
}

export function checkResults(view: ClassView, activity: Interval[], times: number[], p: Policy): CheckResult[] {
  return view.windows.map((w) => {
    const passed = times.some((t) => t >= w.from && t < w.to);
    // A passed check always counts as ran, even if the teacher's activity log is patchy.
    const ran = passed || (coverage(w, activity) >= p.minWindowCoverage && !view.emptyWindows.has(windowId(w)));
    return { window: w, ran, passed };
  });
}

export function evaluateStudent(
  view: ClassView | CheckWindow[],
  activity: Interval[],
  ev: StudentEvidence,
  p: Policy,
): Evaluation {
  const v = Array.isArray(view) ? { windows: view, emptyWindows: new Set<string>() } : view;
  const checks = checkResults(v, activity, ev.checkinTimes, p);
  if (ev.excused) return { status: 'EXCUSED', reasons: ['excused'], checks };
  if (ev.manual) return { status: 'MANUAL', reasons: ['marked present by teacher'], checks };

  const ran = checks.filter((c) => c.ran);
  const missed = ran.filter((c) => !c.passed);
  const passed = ran.length - missed.length;

  if (ran.length === 0) return { status: 'UNVERIFIED', reasons: ['no check ran (teacher device offline)'], checks };
  const notRun = checks.filter((c) => !c.ran).map((c) => `${c.window.kind} check did not run`);

  if (missed.length === 0) return { status: 'PRESENT', reasons: notRun, checks };
  if (passed * 2 <= ran.length) return { status: 'ABSENT', reasons: [`passed ${passed}/${ran.length} checks`, ...notRun], checks };

  const missedKinds = new Set(missed.map((c) => c.window.kind));
  const label = (c: CheckResult) =>
    c.window.kind !== 'MID' ? c.window.kind : c.window.index >= 100 ? 'surprise check' : `MID #${c.window.index + 1}`;
  const reasons = [...missed.map((c) => `missed ${label(c)}`), ...notRun];
  if (missedKinds.size === 1 && missedKinds.has('START')) return { status: 'LATE', reasons, checks };
  if (missedKinds.size === 1 && missedKinds.has('END')) return { status: 'LEFT_EARLY', reasons, checks };
  return { status: 'FLAGGED', reasons, checks };
}
