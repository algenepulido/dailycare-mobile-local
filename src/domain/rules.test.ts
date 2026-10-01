import {
  ALERT_SLEEPS,
  buildChanges,
  buildChecklist,
  buildFamilyChecklist,
  mealCounts,
} from './rules';
import type { CheckIn } from './types';
import { DEFAULT_BASELINE } from './types';

const baseline = DEFAULT_BASELINE; // Calm / Fair / Restless

function entry(overrides: Partial<CheckIn> = {}): CheckIn {
  return {
    id: 'check-in',
    residentId: 'resident',
    caregiverId: 'caregiver',
    careDate: '2026-09-03',
    meals: {
      breakfast: { done: true, amount: 'all' },
      lunch: { done: true, amount: 'half' },
      dinner: { done: false, amount: null },
    },
    medication: { am: true, pm: false },
    hygiene: { shower: true, grooming: false },
    mood: baseline.mood,
    appetite: baseline.appetite,
    sleep: baseline.sleep,
    concerns: [],
    supplementalMedication: '',
    note: '',
    photoUri: null,
    createdAt: '2026-09-03T09:00:00.000Z',
    updatedAt: '2026-09-03T09:00:00.000Z',
    ...overrides,
  };
}

describe('what the family is told', () => {
  it('says nothing when the day matched the resident’s usual', () => {
    expect(buildChanges(entry(), baseline)).toHaveLength(0);
  });

  it('reports a difference and names the baseline beside it', () => {
    expect(buildChanges(entry({ mood: 'Withdrawn' }), baseline)).toEqual([
      { kind: 'Mood', value: 'Withdrawn', baselineNote: 'usually Calm', alert: false },
    ]);
  });

  it('raises an alert for an agitated or confused day', () => {
    expect(buildChanges(entry({ mood: 'Agitated' }), baseline)[0].alert).toBe(true);
    expect(buildChanges(entry({ mood: 'Confused' }), baseline)[0].alert).toBe(true);
  });

  it('raises an alert when food is refused', () => {
    expect(buildChanges(entry({ appetite: 'Refused' }), baseline)[0].alert).toBe(true);
  });

  it('reports a sleepless night without escalating it to an alert', () => {
    // The web app renders the chip red, then pushes the change with no alert flag, and
    // product-spec § 5.1 says the same. The split is deliberate on both surfaces.
    const [change] = buildChanges(entry({ sleep: "Didn't sleep" }), baseline);
    expect(change).toEqual({
      kind: 'Sleep',
      value: "Didn't sleep",
      baselineNote: 'usually Restless',
      alert: false,
    });
  });

  it('still marks a sleepless night as an alert value for the chip', () => {
    expect(ALERT_SLEEPS).toContain("Didn't sleep");
  });

  it('stays quiet about a restless night for a resident who is usually restless', () => {
    expect(buildChanges(entry({ sleep: 'Restless' }), baseline)).toHaveLength(0);
  });

  it('always alerts on a flagged concern', () => {
    const changes = buildChanges(entry({ concerns: ['Sundowning', 'Pain'] }), baseline);
    expect(changes.map((change) => [change.kind, change.value, change.alert])).toEqual([
      ['Concern', 'Sundowning', true],
      ['Concern', 'Pain', true],
    ]);
  });
});

describe('the care checklist', () => {
  it('says how much was eaten when the caregiver answered', () => {
    expect(
      mealCounts({
        breakfast: { done: true, amount: 'all' },
        lunch: { done: true, amount: 'half' },
        dinner: { done: false, amount: null },
      }),
    ).toEqual({
      done: 2,
      items: ['Breakfast (all)', 'Lunch (half)'],
      missed: ['Dinner'],
    });
  });

  it('still counts a meal that was ticked without an amount, and does not guess one', () => {
    expect(
      mealCounts({
        breakfast: { done: true, amount: null },
        lunch: { done: true, amount: 'a-bit' },
        dinner: { done: false, amount: null },
      }),
    ).toEqual({
      done: 2,
      items: ['Breakfast', 'Lunch (a bit)'],
      missed: ['Dinner'],
    });
  });

  it('totals each group', () => {
    expect(buildChecklist(entry()).map((group) => [group.label, group.done, group.total])).toEqual([
      ['Meals', 2, 3],
      ['Medication', 1, 2],
      ['Hygiene', 1, 2],
    ]);
  });

  it('lists what was not done alongside what was', () => {
    const groups = buildChecklist(entry());
    expect(groups.map((group) => [group.label, group.doneItems, group.missedItems])).toEqual([
      ['Meals', ['Breakfast (all)', 'Lunch (half)'], ['Dinner']],
      ['Medication', ['A.M'], ['P.M']],
      ['Hygiene', ['Shower'], ['Grooming']],
    ]);
  });

  it('carries supplemental medication with the medication group', () => {
    const checklist = buildChecklist(entry({ supplementalMedication: 'Paracetamol' }));
    expect(checklist[1].extra).toBe('Paracetamol');
  });

  it('leaves the extra unset when nothing was entered', () => {
    expect(buildChecklist(entry()).map((group) => group.extra)).toEqual([
      undefined,
      undefined,
      undefined,
    ]);
  });
});

describe('the checklist a family member is shown', () => {
  const filed = {
    meals: [
      { slot: 'breakfast' as const, happened: true, amount: 'most' as const },
      { slot: 'lunch' as const, happened: true, amount: null },
      { slot: 'dinner' as const, happened: false, amount: null },
    ],
    shower: true,
    grooming: false,
  };

  // The reason this function exists. Medication is recorded on the phone and never sent, so
  // a group built from what the server has would say "Medication 0/2" - and a daughter
  // reading that concludes nobody gave her mother her tablets.
  it('has no medication group, because the server has no medication', () => {
    expect(buildFamilyChecklist(filed).map((g) => g.label)).toEqual(['Meals', 'Hygiene']);
  });

  it('counts the meals that happened and names the ones that did not', () => {
    const [meals] = buildFamilyChecklist(filed);
    expect([meals.done, meals.total]).toEqual([2, 3]);
    expect(meals.doneItems).toEqual(['Breakfast (most)', 'Lunch']);
    expect(meals.missedItems).toEqual(['Dinner']);
  });

  it('reads hygiene the same way the caregiver’s own checklist does', () => {
    const [, hygiene] = buildFamilyChecklist(filed);
    expect([hygiene.done, hygiene.total]).toEqual([1, 2]);
    expect(hygiene.doneItems).toEqual(['Shower']);
    expect(hygiene.missedItems).toEqual(['Grooming']);
  });

  // A day the server returned without every slot. It does return all three for a filed day,
  // so this is about the shape being safe rather than about a case that happens.
  it('treats a meal the record does not mention as not done', () => {
    const [meals] = buildFamilyChecklist({ meals: [], shower: false, grooming: false });
    expect([meals.done, meals.missedItems.length]).toEqual([0, 3]);
  });
});
