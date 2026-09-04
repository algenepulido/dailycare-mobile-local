import { buildChanges, buildChecklist, mealCounts } from './rules';
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

  it('raises an alert for a sleepless night', () => {
    // The prototype flagged this in the input but never carried it into the summary.
    expect(buildChanges(entry({ sleep: "Didn't sleep" }), baseline)[0].alert).toBe(true);
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
