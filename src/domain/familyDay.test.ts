import { familyDay } from './familyDay';
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
      { slot: 'breakfast', happened: true, amount: null },
      { slot: 'lunch', happened: true, amount: null },
      { slot: 'dinner', happened: true, amount: null },
    ],
    concerns: [],
    ...over,
  };
}

describe('a day as a family reads it', () => {
  it('names the person who looked in', () => {
    expect(familyDay(day(), usual, 'Cathy', 'Maria').opening).toBe(
      'Maria looked in on Cathy today.',
    );
  });

  it('says somebody did, even when the record cannot say who', () => {
    expect(familyDay(day(), usual, 'Cathy', '').opening).toBe(
      'Somebody at the care home looked in on Cathy today.',
    );
  });

  it('has nothing worth an eye on an ordinary day', () => {
    const d = familyDay(day(), usual, 'Cathy', 'Maria');
    expect(d.worthAnEye).toEqual([]);
    expect(d.wentWell).toContain('Cathy had all three meals.');
    expect(d.wentWell).toContain('Cathy was themselves today — mood, appetite and sleep all as usual.');
  });

  it('carries how much was eaten when somebody said', () => {
    const d = familyDay(
      day({
        meals: [
          { slot: 'breakfast', happened: true, amount: 'most' },
          { slot: 'lunch', happened: true, amount: null },
          { slot: 'dinner', happened: false, amount: null },
        ],
      }),
      usual,
      'Cathy',
      'Maria',
    );
    expect(d.wentWell).toContain('Cathy had breakfast and lunch — most of the breakfast.');
    expect(d.worthAnEye).toContain('Dinner was not recorded.');
  });

  // The distinction the wording is carrying: a meal with no tick is a meal nobody wrote
  // down. Saying "not done" would be a claim about the care rather than about the record.
  it('says a meal was not recorded rather than not done', () => {
    const d = familyDay(
      day({ meals: [{ slot: 'breakfast', happened: false, amount: null }] }),
      usual,
      'Cathy',
      'Maria',
    );
    expect(d.worthAnEye.join(' ')).toContain('not recorded');
    expect(d.worthAnEye.join(' ')).not.toContain('not done');
  });

  it('puts a difference that is an improvement with the good news', () => {
    const d = familyDay(day({ appetite: 'Good' }), usual, 'Cathy', 'Maria');
    expect(d.wentWell).toContain("Cathy's appetite was good today. Fair is the usual.");
    expect(d.worthAnEye).toEqual([]);
  });

  it('puts a difference that is not with the gentler half, and keeps the comparison', () => {
    const d = familyDay(day({ appetite: 'Poor' }), usual, 'Cathy', 'Maria');
    expect(d.worthAnEye).toContain("Cathy's appetite was poor today. Fair is the usual.");
  });

  it('says a concern in words rather than in the stored shorthand', () => {
    const d = familyDay(day({ concerns: ['Sundowning'] }), usual, 'Cathy', 'Maria');
    expect(d.worthAnEye).toContain('Cathy became more unsettled as the day went on.');
    expect(d.worthAnEye.join(' ')).not.toContain('Sundowning');
  });

  it('says nothing at all about an observation it cannot name', () => {
    const d = familyDay(day({ mood: null }), usual, 'Cathy', 'Maria');
    expect(d.wentWell.join(' ')).not.toContain('seemed');
    expect(d.worthAnEye).toEqual([]);
  });

  it('keeps the caregiver’s words as they were written, and whose they are', () => {
    const d = familyDay(day({ note: '  Settled once she was outside.  ' }), usual, 'Cathy', 'Maria');
    expect(d.note).toBe('Settled once she was outside.');
    expect(d.noteBy).toBe('Maria');
  });

  /**
   * The boundary this file exists to hold.
   *
   * A family is reading a summary, not reviewing the form the day was entered on. If any of
   * these words reach them, the caregiver's perspective has crossed over - which is the thing
   * that was wrong before this existed, and the thing a later change could put back without
   * noticing. Counts are the giveaway: "2/3 done" is an account of a form being filled in.
   */
  it('never uses the vocabulary of the form it came from', () => {
    const d = familyDay(
      day({
        mood: 'Agitated',
        appetite: 'Refused',
        sleep: "Didn't sleep",
        shower: false,
        grooming: false,
        concerns: ['Wandering', 'Fall / near-fall', 'Pain', 'Skin concern'],
        meals: [
          { slot: 'breakfast', happened: true, amount: 'a-bit' },
          { slot: 'lunch', happened: false, amount: null },
          { slot: 'dinner', happened: false, amount: null },
        ],
        note: 'A hard day.',
      }),
      usual,
      'Cathy',
      'Maria',
    );
    const everything = [d.opening, ...d.wentWell, ...d.worthAnEye].join(' ');
    for (const word of ['done', 'checklist', 'Not done', '/3', '/2', 'filed', 'flag', 'concern:']) {
      expect(everything.toLowerCase()).not.toContain(word.toLowerCase());
    }
  });

  it('still says the hard things on a hard day', () => {
    const d = familyDay(
      day({
        mood: 'Agitated',
        shower: false,
        grooming: false,
        concerns: ['Pain'],
        meals: [{ slot: 'breakfast', happened: false, amount: null }],
      }),
      usual,
      'Cathy',
      'Maria',
    );
    const eye = d.worthAnEye.join(' ');
    expect(eye).toContain('agitated');
    expect(eye).toContain('No shower or grooming was recorded.');
    expect(eye).toContain('Cathy was in some pain today.');
  });
});

// Sleep needs two grammars in one sentence: what happened is a verb, what is usual is a
// thing. One form for both gave "Slept restlessly is the usual".
describe('how a night reads', () => {
  const usualNight: Baseline = { mood: 'Calm', appetite: 'Fair', sleep: 'Restless' };
  const base: FiledDayFacts = {
    mood: 'Calm', appetite: 'Fair', sleep: 'Restless', note: '', shower: true, grooming: true,
    meals: [], concerns: [],
  };

  it('says the night and then what is usual, in sentences that parse', () => {
    const d = familyDay({ ...base, sleep: 'Up a lot' }, usualNight, 'Cathy', 'Maria');
    expect(d.worthAnEye).toContain('Cathy was up a lot last night. A restless night is the usual.');
  });

  it('puts a better night with the good news', () => {
    const d = familyDay({ ...base, sleep: 'Slept well' }, usualNight, 'Cathy', 'Maria');
    expect(d.wentWell).toContain('Cathy slept well last night. A restless night is the usual.');
  });
});
