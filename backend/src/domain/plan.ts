// Check windows for a session. Deterministic from (secret, times), so the teacher phone
// (offline) and the server always compute the same plan. Mirrored in app/lib/domain/plan.dart.
import { createHmac } from 'node:crypto';
import { MIN, type Policy } from './policy.js';

export type CheckKind = 'START' | 'MID' | 'END';

export interface CheckWindow {
  kind: CheckKind;
  index: number; // 0 for START/END, 0..n-1 for MIDs
  from: number; // epoch ms, inclusive
  to: number; // epoch ms, exclusive
}

export interface SessionTimes {
  scheduledStart: number;
  scheduledEnd: number;
  actualStart: number;
  /** When the teacher tapped End (null while running / if never tapped). */
  actualEnd: number | null;
  /** scheduledEnd plus any extensions. */
  plannedEnd: number;
}

export type Interval = [number, number];

function midFraction(secret: Buffer, i: number): number {
  const d = createHmac('sha256', secret).update(Buffer.concat([Buffer.from('EXST-MID', 'ascii'), Buffer.from([i])])).digest();
  return d.readUInt32BE(0) / 2 ** 32;
}

export function endWindow(t: SessionTimes, p: Policy): CheckWindow {
  const endedEarly = t.actualEnd !== null && t.actualEnd < t.plannedEnd - p.endWindowMin * MIN;
  if (endedEarly) return { kind: 'END', index: 0, from: t.actualEnd!, to: t.actualEnd! + p.earlyEndWindowMin * MIN };
  return { kind: 'END', index: 0, from: t.plannedEnd - p.endWindowMin * MIN, to: t.plannedEnd };
}

export function planChecks(secret: Buffer, t: SessionTimes, p: Policy): CheckWindow[] {
  const start: CheckWindow = {
    kind: 'START',
    index: 0,
    from: t.actualStart,
    to: Math.max(t.actualStart, t.scheduledStart) + p.startWindowMin * MIN,
  };
  const end = endWindow(t, p);

  // MIDs are placed against the *scheduled* end so the plan never shifts when the
  // teacher extends the class. If the class ends early, later MIDs simply drop out.
  const rangeFrom = Math.max(start.to, t.actualStart + p.midMarginMin * MIN);
  const rangeTo = t.scheduledEnd - p.endWindowMin * MIN - p.midMarginMin * MIN;
  const midLen = p.midWindowMin * MIN;
  const wanted = p.midChecks ?? Math.max(1, Math.floor((t.scheduledEnd - t.scheduledStart) / (p.midEveryMin * MIN)));
  // Each MID needs a segment of at least 3 windows so it stays unpredictable.
  const n = rangeTo > rangeFrom ? Math.min(wanted, Math.floor((rangeTo - rangeFrom) / (3 * midLen))) : 0;

  const mids: CheckWindow[] = [];
  const seg = n > 0 ? (rangeTo - rangeFrom) / n : 0;
  for (let i = 0; i < n; i++) {
    const from = Math.floor(rangeFrom + i * seg + midFraction(secret, i) * (seg - midLen));
    if (from + midLen > end.from) continue; // teacher ended before this MID
    mids.push({ kind: 'MID', index: i, from, to: from + midLen });
  }

  // An extremely short session: START and END may overlap; keep END after START.
  if (end.from < start.to) end.from = Math.min(start.to, end.to);
  return [start, ...mids, end];
}

/** Index offset for surprise checks the teacher triggers by hand. */
export const SURPRISE_INDEX = 100;

/** Add teacher-triggered surprise checks (MID windows) to the plan, in time order. */
export function withExtraChecks(windows: CheckWindow[], extra: Interval[]): CheckWindow[] {
  if (!extra.length) return windows;
  const surprise = extra.map(([from, to], i): CheckWindow => ({ kind: 'MID', index: SURPRISE_INDEX + i, from, to }));
  const end = windows[windows.length - 1];
  return [windows[0], ...[...windows.slice(1, -1), ...surprise].sort((a, b) => a.from - b.from), end];
}

/** Share of [from,to) covered by the teacher phone's active intervals. */
export function coverage(w: { from: number; to: number }, activity: Interval[]): number {
  const len = w.to - w.from;
  if (len <= 0) return 0;
  const merged = [...activity].sort((a, b) => a[0] - b[0]).reduce<Interval[]>((acc, [a, b]) => {
    const last = acc[acc.length - 1];
    if (last && a <= last[1]) last[1] = Math.max(last[1], b);
    else acc.push([a, b]);
    return acc;
  }, []);
  let covered = 0;
  for (const [a, b] of merged) covered += Math.max(0, Math.min(b, w.to) - Math.max(a, w.from));
  return covered / len;
}

/** Which timed window (if any) is open at `now`, as the teacher phone advertises it. */
export function currentPhase(windows: CheckWindow[], now: number): { phase: 'ARRIVE' | 'MID' | 'END'; index: number } {
  for (const w of windows) {
    if (w.kind !== 'START' && now >= w.from && now < w.to) return { phase: w.kind, index: w.index };
  }
  return { phase: 'ARRIVE', index: 0 };
}
