import { STEADY_DAY, familyDay, whatTheVersionChanged } from './familyDay';
import type { FiledDayFacts } from './familyDay';
import type { Baseline } from './types';

const usual: Baseline = { mood: 'Calm', appetite: 'Fair', sleep: 'Restless' };

function day(over: Partial<FiledDayFacts> = {}): FiledDayFacts {
  return {
    mood: 'Calm',
    appetite: 'Fair',
    sleep: 'Restless',
    note: '',
    shower: true,
    grooming: true,
    meals: [
      { slot: 'breakfast', happened: true, refused: false, amount: null },
      { slot: 'lunch', happened: true, refused: false, amount: null },
      { slot: 'dinner', happened: true, refused: false, amount: null },
    ],
    concerns: [],
    medication: [],
    ...over,
  };
}

const group = (d: ReturnType<typeof familyDay>, label: string) =>
  d.care.find((g) => g.label === label)!;

describe('a day as a family reads it', () => {
  it('says who the update came from', () => {
    expect(familyDay(day(), usual, 'Cathy', 'Maria Santos').from).toBe('Maria Santos');
  });

  it('has nothing to report on an ordinary day', () => {
    expect(familyDay(day(), usual, 'Cathy', 'Maria').changed).toEqual([]);
  });

  /* ------------------------------------------------------ what changed today */

  it('carries what is normal for this person alongside what happened', () => {
    const d = familyDay(day({ appetite: 'Poor' }), usual, 'Cathy', 'Maria');
    expect(d.changed).toContain("Cathy's appetite was poor today, where fair is usual.");
  });

  // Sleep needs two grammars in the one sentence: what happened is something a person did,
  // what is usual is a kind of night.
  it('reads a night without tripping over itself', () => {
    const d = familyDay(day({ sleep: 'Up a lot' }), usual, 'Cathy', 'Maria');
    expect(d.changed).toContain('Cathy was up a lot last night, where a restless night is usual.');
  });

  // One list, as the care home's own summary has it. A family at the end of a day should not
  // have to join two sections to see what kind of day it was.
  it('puts an improvement in the same list as anything else that changed', () => {
    const d = familyDay(day({ appetite: 'Good', mood: 'Anxious' }), usual, 'Cathy', 'Maria');
    expect(d.changed).toContain("Cathy's appetite was good today, where fair is usual.");
    expect(d.changed).toContain('Cathy seemed anxious today, where calm is usual.');
  });

  it('says a concern rather than naming it', () => {
    const d = familyDay(day({ concerns: ['Sundowning'] }), usual, 'Cathy', 'Maria');
    expect(d.changed).toContain('Cathy became more unsettled as the day went on.');
    expect(d.changed.join(' ')).not.toContain('Sundowning');
  });

  it('says nothing at all about an observation it cannot name', () => {
    const d = familyDay(day({ mood: null }), usual, 'Cathy', 'Maria');
    expect(d.changed).toEqual([]);
  });

  /* ---------------------------------------------------- the care information */

  // The thing the prose attempt lost. A daily update is scanned, and a family should see the
  // shape of the day without reading paragraphs.
  it('groups the care information so it can be taken in at a glance', () => {
    const d = familyDay(
      day({
        meals: [
          { slot: 'breakfast', happened: true, refused: false, amount: 'most' },
          { slot: 'lunch', happened: true, refused: false, amount: null },
          { slot: 'dinner', happened: false, refused: false, amount: null },
        ],
        grooming: false,
      }),
      usual,
      'Cathy',
      'Maria',
    );
    expect(d.care.map((g) => g.label)).toEqual(['Meals', 'Medication', 'Hygiene']);

    const meals = group(d, 'Meals');
    expect([meals.done, meals.total]).toEqual([2, 3]);
    expect(meals.did).toEqual(['Breakfast (most)', 'Lunch']);
    expect(meals.didNot).toEqual(['Dinner']);

    const hygiene = group(d, 'Hygiene');
    expect([hygiene.done, hygiene.total]).toEqual([1, 2]);
    expect(hygiene.did).toEqual(['Shower']);
    expect(hygiene.didNot).toEqual(['Grooming']);
  });

  /**
   * Medication, and whose statement it is.
   *
   * The same two letters mean something different depending on where they came from: a
   * caregiver's tick is somebody saying they gave a dose, and a clinical system's row is a
   * record that one was administered. medication_source has carried both values since the
   * schema was written. So the family is shown the ticks and told whose they are.
   */
  it('shows what the caregiver recorded, and says it was theirs', () => {
    const d = familyDay(
      day({
        medication: [
          { slot: 'am', status: 'given', detail: '', recordedBy: 'Maria Santos' },
          { slot: 'pm', status: 'given', detail: '', recordedBy: 'Maria Santos' },
        ],
      }),
      usual,
      'Cathy',
      'Maria Santos',
    );
    const meds = group(d, 'Medication');
    expect([meds.done, meds.total]).toEqual([2, 2]);
    expect(meds.did).toEqual(['A.M', 'P.M']);
    expect(meds.didNot).toEqual([]);
    expect(meds.source).toBe('Maria Santos recorded this.');
  });

  it('carries a supplemental dose as the caregiver described it', () => {
    const d = familyDay(
      day({
        medication: [
          { slot: 'am', status: 'given', detail: '', recordedBy: 'Maria Santos' },
          {
            slot: 'supplemental',
            status: 'given',
            detail: 'Tylenol 500mg twice today',
            recordedBy: 'Maria Santos',
          },
        ],
      }),
      usual,
      'Cathy',
      'Maria Santos',
    );
    const meds = group(d, 'Medication');
    expect(meds.did).toEqual(['A.M', 'Tylenol 500mg twice today']);
    expect(meds.didNot).toEqual(['P.M']);
  });

  // A slot nobody ticked is a slot nobody wrote down, which is the same distinction the
  // meals carry. It is never a claim that a dose was missed.
  it('says a slot was not recorded rather than not given', () => {
    const meds = group(familyDay(day(), usual, 'Cathy', 'Maria'), 'Medication');
    expect(meds.did).toEqual([]);
    expect(meds.didNot).toEqual(['A.M', 'P.M']);
  });

  // Nothing recorded means nothing to attribute. A provenance line on an empty group would
  // be a sentence about who did not say something.
  it('says nothing about the source when nothing was recorded', () => {
    expect(group(familyDay(day(), usual, 'Cathy', 'Maria'), 'Medication').source).toBeUndefined();
  });

  /* ---------------------------------------------------------------- the note */

  it('keeps the caregiver’s words as they were written', () => {
    const d = familyDay(day({ note: '  Settled once she was outside.  ' }), usual, 'Cathy', 'Maria');
    expect(d.note).toBe('Settled once she was outside.');
  });

  /* ------------------------------------------------------------ the boundary */

  /**
   * What makes this the family's summary and not the caregiver's form.
   *
   * The care home's own daily email has counts and a checklist, so neither is the problem and
   * this does not forbid them. What it forbids is the vocabulary of entering a day: a meal
   * nobody ticked is not a meal nobody gave, and nothing here is a flag.
   */
  it('never claims care did not happen, only that it was not recorded', () => {
    const d = familyDay(
      day({
        shower: false,
        grooming: false,
        meals: [
          { slot: 'breakfast', happened: false, refused: false, amount: null },
          { slot: 'lunch', happened: false, refused: false, amount: null },
          { slot: 'dinner', happened: false, refused: false, amount: null },
        ],
      }),
      usual,
      'Cathy',
      'Maria',
    );
    const words = [
      ...d.changed,
      ...d.care.flatMap((g) => [g.label, g.source ?? '', ...g.did, ...g.didNot]),
    ]
      .join(' ')
      .toLowerCase();
    for (const forbidden of ['not done', 'flag', 'filed', 'checklist']) {
      expect(words).not.toContain(forbidden);
    }
  });

  it('still says the hard things on a hard day', () => {
    const d = familyDay(
      day({ mood: 'Agitated', concerns: ['Pain'], shower: false, grooming: false }),
      usual,
      'Cathy',
      'Maria',
    );
    expect(d.changed.join(' ')).toContain('agitated');
    expect(d.changed).toContain('Cathy was in some pain today.');
    expect(group(d, 'Hygiene').didNot).toEqual(['Shower', 'Grooming']);
  });

  it('offers one line for a day where nothing differed', () => {
    expect(STEADY_DAY).toBe('A steady day — everything as usual.');
    expect(familyDay(day(), usual, 'Cathy', 'Maria').changed).toHaveLength(0);
  });
});

describe('the name a family reads', () => {
  const usual: Baseline = { mood: 'Calm', appetite: 'Fair', sleep: 'Restless' };
  const base: FiledDayFacts = {
    mood: 'Calm', appetite: 'Fair', sleep: 'Restless', note: '', shower: true, grooming: true,
    meals: [], concerns: [], medication: [],
  };

  it('says the given name rather than the whole one, three sentences running', () => {
    const d = familyDay({ ...base, appetite: 'Poor' }, usual, 'Cathy Alvarez', 'Maria');
    expect(d.changed.join(' ')).toContain("Cathy's appetite");
    expect(d.changed.join(' ')).not.toContain('Cathy Alvarez');
  });

  it('and a single-word name is left alone', () => {
    const d = familyDay({ ...base, appetite: 'Poor' }, usual, 'Cathy', 'Maria');
    expect(d.changed.join(' ')).toContain("Cathy's appetite");
  });
});

/**
 * A photograph joining a day is not the home changing its account of it.
 *
 * The record cannot hold a picture without a version to hold it, so a caregiver who comes
 * back in the evening files the day again. Reading that as "updated after it was first
 * written" tells a family something untrue in the one direction a care record must never
 * be wrong in, and gives them no way to check it.
 */
describe('whatTheVersionChanged', () => {
  const at = '2026-10-13T16:12:00.000Z';

  it('says nothing about a day that was filed once', () => {
    expect(whatTheVersionChanged(undefined, at)).toBeNull();
  });

  it('says the day was updated when the care changed', () => {
    expect(whatTheVersionChanged('care', at)).toBe(
      'This was updated after it was first written.',
    );
  });

  it('says a photo was added, with the time, when only a picture joined it', () => {
    const line = whatTheVersionChanged('photograph', at);
    expect(line).toMatch(/^A photo was added at .+\.$/);
    expect(line).not.toContain('updated');
  });

  it('still says a photo was added when the time is unreadable', () => {
    expect(whatTheVersionChanged('photograph', 'not a time')).toBe('A photo was added.');
  });

  /** A word nobody has defined yet is not a reason to tell a family anything. */
  it('says nothing about a kind of change it does not know', () => {
    expect(whatTheVersionChanged('something-else', at)).toBeNull();
    expect(whatTheVersionChanged('', at)).toBeNull();
  });
});

/**
 * A meal she turned down is a thing that happened, not a gap in the paperwork.
 *
 * The record held one boolean until now and the product was careful that false meant
 * "nobody wrote it down". A refusal is the third answer, and it belongs on its own line:
 * folded into the same list as the unrecorded ones it would read as the home having
 * forgotten rather than as her having said no.
 */
describe('a meal she would not eat', () => {
  function withLunch(happened: boolean, refused: boolean) {
    return familyDay(
      {
        mood: 'Calm',
        appetite: 'Good',
        sleep: 'Slept well',
        note: '',
        shower: false,
        grooming: false,
        meals: [
          { slot: 'breakfast', happened: true, refused: false, amount: 'most' },
          { slot: 'lunch', happened, refused, amount: null },
          { slot: 'dinner', happened: true, refused: false, amount: 'most' },
        ],
        concerns: [],
        medication: [],
      },
      { mood: 'Calm', appetite: 'Good', sleep: 'Slept well' },
      'Alma Reyes',
      'Nadia',
    );
  }

  const meals = (d: ReturnType<typeof withLunch>) =>
    d.care.find((g) => g.label === 'Meals')!;

  it('is named as refused rather than as missing', () => {
    expect(meals(withLunch(false, true)).refused).toEqual(['Lunch']);
  });

  it('and is not in the list of what the record does not have', () => {
    expect(meals(withLunch(false, true)).didNot).toEqual([]);
  });

  it('while a meal nobody wrote down still is', () => {
    expect(meals(withLunch(false, false)).didNot).toEqual(['Lunch']);
    expect(meals(withLunch(false, false)).refused).toEqual([]);
  });

  it('does not count towards what she ate', () => {
    expect(meals(withLunch(false, true)).done).toBe(2);
    expect(meals(withLunch(false, true)).total).toBe(3);
  });

  it('leaves the meals she did eat where they were', () => {
    expect(meals(withLunch(false, true)).did).toEqual([
      'Breakfast (most)',
      'Dinner (most)',
    ]);
  });
});
