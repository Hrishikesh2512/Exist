import { calendarLookup, type CalendarEntry, type DayLookup } from '../domain/calendar.js';
import { prisma } from '../lib/db.js';

export async function loadCalendar(from: string, to: string): Promise<{ lookup: DayLookup; entries: (CalendarEntry & { id: string })[] }> {
  const [events, terms, sections] = await Promise.all([
    prisma.calendarEvent.findMany({ where: { fromDate: { lte: to }, toDate: { gte: from } }, orderBy: { fromDate: 'asc' } }),
    prisma.term.findMany(),
    prisma.section.findMany({ select: { id: true, startDate: true, endDate: true, archivedAt: true } }),
  ]);
  const base = calendarLookup(events, terms);
  const bounds = new Map(sections.map((s) => [s.id, s]));
  // Each class only runs between its own start and end dates, and not once archived.
  const lookup: DayLookup = (date, weekday) => {
    const day = base(date, weekday);
    return {
      weekday: day.weekday,
      blocked(sectionId) {
        const s = bounds.get(sectionId);
        if (s?.archivedAt) return 'class archived';
        if (s?.startDate && date < s.startDate) return 'before the class starts';
        if (s?.endDate && date > s.endDate) return 'after the class ends';
        return day.blocked(sectionId);
      },
    };
  };
  return { lookup, entries: events };
}
