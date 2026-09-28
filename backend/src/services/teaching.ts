// Who teaches which section (subject group), and which sections belong to the current semester.
import { prisma } from '../lib/db.js';
import { localDate } from './occurrences.js';

/** Sections a teacher is assigned to (directly, or through the timetable). */
export async function taughtSections(teacherId: string): Promise<string[]> {
  const [assigned, slots] = await Promise.all([
    prisma.sectionTeacher.findMany({ where: { teacherId }, select: { sectionId: true } }),
    prisma.timetableSlot.findMany({ where: { teacherId }, select: { sectionId: true } }),
  ]);
  return [...new Set([...assigned, ...slots].map((s) => s.sectionId))].sort();
}

export async function teaches(teacherId: string, sectionIds: string[]): Promise<boolean> {
  if (!sectionIds.length) return false;
  const mine = new Set(await taughtSections(teacherId));
  return sectionIds.every((s) => mine.has(s));
}

export async function teachersOf(sectionId: string): Promise<string[]> {
  const [a, b] = await Promise.all([
    prisma.sectionTeacher.findMany({ where: { sectionId } }),
    prisma.timetableSlot.findMany({ where: { sectionId } }),
  ]);
  return [...new Set([...a, ...b].map((x) => x.teacherId))];
}

/** Semesters running today. Empty when none cover today; null when none are defined at all. */
export async function currentTermIds(now = Date.now()): Promise<string[] | null> {
  const terms = await prisma.term.findMany();
  if (!terms.length) return null;
  const d = localDate(now);
  return terms.filter((t) => t.startDate <= d && t.endDate >= d).map((t) => t.id);
}

/** Keep only classes running now: not archived and within their dates (and semester, if any). */
export async function currentSections(sectionIds: string[]): Promise<string[]> {
  const d = localDate(Date.now());
  const rows = await prisma.section.findMany({ where: { id: { in: sectionIds } }, include: { term: true } });
  const ok = new Set(
    rows
      .filter((r) => !r.archivedAt)
      .filter((r) => (!r.startDate || r.startDate <= d) && (!r.endDate || r.endDate >= d))
      .filter((r) => !r.term || (r.term.startDate <= d && r.term.endDate >= d))
      .map((r) => r.id),
  );
  return sectionIds.filter((s) => ok.has(s));
}

export interface SectionInfo {
  id: string;
  subject: { code: string; name: string } | null;
  groupName: string | null;
  term: string | null;
  /** "Data Structures · CSE-A" */
  label: string;
}

export async function sectionInfo(sectionIds: string[]): Promise<Map<string, SectionInfo>> {
  const rows = await prisma.section.findMany({ where: { id: { in: sectionIds } }, include: { course: true, term: true } });
  const m = new Map<string, SectionInfo>();
  for (const id of sectionIds) {
    const r = rows.find((x) => x.id === id);
    const subject = r?.course ? { code: r.course.code, name: r.course.name } : null;
    m.set(id, {
      id,
      subject,
      groupName: r?.groupName ?? null,
      term: r?.term?.name ?? null,
      label: subject ? `${subject.name}${r?.groupName ? ` · ${r.groupName}` : ''}` : id,
    });
  }
  return m;
}

/** Label for a class that may combine several groups of the same subject. */
export function classLabel(info: Map<string, SectionInfo>, sectionIds: string[]): string {
  const parts = sectionIds.map((s) => info.get(s));
  const names = [...new Set(parts.map((p) => p?.subject?.name ?? null))];
  if (names.length === 1 && names[0]) {
    const groups = parts.map((p) => p?.groupName).filter(Boolean);
    return groups.length ? `${names[0]} · ${groups.join(' + ')}` : names[0];
  }
  return parts.map((p, i) => p?.label ?? sectionIds[i]).join(' + ');
}

/** Make sure every member of a class is enrolled in every subject that class studies. */
export async function syncClassEnrollment(classId: string) {
  const [members, sections] = await Promise.all([
    prisma.classMember.findMany({ where: { classId } }),
    prisma.section.findMany({ where: { classId }, select: { id: true } }),
  ]);
  const data = members.flatMap((m) => sections.map((s) => ({ sectionId: s.id, studentId: m.studentId })));
  if (data.length) await prisma.enrollment.createMany({ data, skipDuplicates: true });
}

export async function classByName(name: string) {
  return prisma.classGroup.upsert({ where: { name }, create: { name }, update: {} });
}
