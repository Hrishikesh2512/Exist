// Academic calendar: terms, holidays, exams, events and day-order swaps
// ("Saturday follows Monday's timetable"). Decides, per date, which weekday's timetable
// runs and which sections have no classes.

export type CalendarKind = 'HOLIDAY' | 'EXAM' | 'EVENT' | 'DAY_ORDER';

export interface CalendarEntry {
  kind: CalendarKind;
  title: string;
  fromDate: string; // YYYY-MM-DD inclusive
  toDate: string;
  /** EXAM and EVENT may or may not suspend classes; HOLIDAY always does. */
  noClasses: boolean;
  /** DAY_ORDER: run this ISO weekday's timetable (1 = Monday). */
  followsWeekday: number | null;
  /** Empty = whole institution. */
  sectionIds: string[];
}

export interface Term {
  name: string;
  startDate: string;
  endDate: string;
}

export interface DayPlan {
  weekday: number;
  /** Reason the section has no class that day, or null. */
  blocked(sectionId: string): string | null;
}

export type DayLookup = (date: string, isoWeekday: number) => DayPlan;

export const openDay: DayLookup = (_d, weekday) => ({ weekday, blocked: () => null });

const covers = (e: { fromDate: string; toDate: string }, date: string) => date >= e.fromDate && date <= e.toDate;

export function calendarLookup(entries: CalendarEntry[], terms: Term[]): DayLookup {
  return (date, isoWeekday) => {
    const today = entries.filter((e) => covers(e, date));
    const swap = today.find((e) => e.kind === 'DAY_ORDER' && e.followsWeekday);
    const outsideTerm = terms.length > 0 && !terms.some((t) => date >= t.startDate && date <= t.endDate);
    const blocking = today.filter((e) => e.kind === 'HOLIDAY' || (e.kind !== 'DAY_ORDER' && e.noClasses));
    return {
      weekday: swap?.followsWeekday ?? isoWeekday,
      blocked(sectionId) {
        if (outsideTerm) return 'outside term';
        const e = blocking.find((b) => b.sectionIds.length === 0 || b.sectionIds.includes(sectionId));
        return e ? e.title : null;
      },
    };
  };
}
