import type { SectionSettings } from '@prisma/client';
import { clampPlan, type PlanOverrides, type Policy } from '../domain/policy.js';
import { prisma } from '../lib/db.js';

export interface EffectiveSettings {
  autoStart: boolean;
  plan: PlanOverrides;
  weights: Policy['weights'];
  manualQuota: number;
}

/** Settings for a class. Combined sections use the first section (sorted) that has settings. */
export async function settingsFor(sectionIds: string[], p: Policy): Promise<EffectiveSettings> {
  const rows = await prisma.sectionSettings.findMany({ where: { sectionId: { in: sectionIds } } });
  const s: SectionSettings | undefined = [...rows].sort((a, b) => a.sectionId.localeCompare(b.sectionId))[0];
  return {
    autoStart: s?.autoStart ?? true,
    plan: clampPlan(s as unknown as Record<string, unknown>),
    weights: {
      ...p.weights,
      ...(s?.lateWeight != null ? { LATE: s.lateWeight } : {}),
      ...(s?.leftEarlyWeight != null ? { LEFT_EARLY: s.leftEarlyWeight } : {}),
    },
    manualQuota: s?.manualQuota ?? p.manualQuotaPerTerm,
  };
}

export async function settingsBySection(sectionIds: string[], p: Policy): Promise<Map<string, EffectiveSettings>> {
  return new Map(await Promise.all(sectionIds.map(async (id) => [id, await settingsFor([id], p)] as const)));
}
