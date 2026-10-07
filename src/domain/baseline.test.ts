import { governingBaseline } from './baseline';
import { familyDay } from './familyDay';
import type { FiledDayFacts } from './familyDay';
import type { Baseline } from './types';

// What a care manager typed when she admitted her.
const theirRecord: Baseline = { mood: 'Calm', appetite: 'Good', sleep: 'Slept well' };
// What a phone starts at, having never heard of the admission.
const onThisPhone: Baseline = { mood: 'Calm', appetite: 'Fair', sleep: 'Restless' };

function day(over: Partial<FiledDayFacts> = {}): FiledDayFacts {
  return {
    mood: 'Calm',
    appetite: 'Fair',
    sleep: 'Restless',
    note: '',
    shower: true,
    grooming: true,
    meals: [
      { slot: 'breakfast', happened: true, amount: null },
      { slot: 'lunch', happened: true, amount: null },
      { slot: 'dinner', happened: true, amount: null },
    ],
    concerns: [],
    medication: [],
    ...over,
  };
}

describe('which usual a day is compared against', () => {
  it("takes the building's record over the phone's copy", () => {
    expect(governingBaseline(theirRecord, onThisPhone)).toBe(theirRecord);
  });

  it("keeps the phone's for somebody no building holds", () => {
    expect(governingBaseline(null, onThisPhone)).toBe(onThisPhone);
  });

  // Why the rule is worth having a name. The same filed day, read against the two, is two
  // different things to tell a family - so a caregiver's review sheet and her family's
  // screen comparing against different ones is not a detail, it is the sheet's promise
  // that it is showing what the family sees being false.
  it("changes what the family is told, which is why it cannot be left to chance", () => {
    const against = (baseline: Baseline) =>
      familyDay(day(), baseline, 'Lidia Ferrer', 'Benita Cruz');

    // Against the phone's copy the day is unremarkable and the family is told nothing.
    expect(against(onThisPhone).changed).toEqual([]);
    // Against the record the care manager typed, the same day ate less and slept worse
    // than is usual for her, and the family hears about both.
    const told = against(theirRecord).changed;
    expect(told).not.toEqual([]);
    expect(told.join(' ')).toContain('Lidia');
  });
});
