import type { FiledDayFacts } from './familyDay';
import { familyWeek } from './familyWeek';
import type { Baseline } from './types';

const usual: Baseline = { mood: 'Calm', appetite: 'Good', sleep: 'Slept well' };

function day(over: Partial<FiledDayFacts> = {}): FiledDayFacts {
  return {
    mood: 'Calm',
    appetite: 'Good',
    sleep: 'Slept well',
    note: '',
    shower: true,
    grooming: true,
    meals: [
      { slot: 'breakfast', happened: true, amount: 'most' },
      { slot: 'lunch', happened: true, amount: 'most' },
      { slot: 'dinner', happened: true, amount: 'most' },
    ],
    concerns: [],
    medication: [],
    ...over,
  };
}

/** The seven days ending Wed Oct 7, every one of them filed and ordinary. */
const steady = ['01', '02', '03', '04', '05', '06', '07'].map((d) => ({
  on: `2026-10-${d}`,
  day: day(),
}));

const LAST = '2026-10-07';

/**
 * The week as it is read on a day that is already over, which is the plain case. The tests
 * that are about today pass a todayIs inside the window on purpose.
 */
function week(days: { on: string; day: FiledDayFacts }[], upTo: string = LAST) {
  return familyWeek({
    filed: days,
    baseline: usual,
    residentName: 'Alma Reyes',
    upTo,
    todayIs: '2026-10-31',
  });
}

/** Replaces one of the seven steady days, leaving the rest alone. */
function except(index: number, over: Partial<FiledDayFacts>) {
  return steady.map((entry, i) => (i === index ? { on: entry.on, day: day(over) } : entry));
}

describe('familyWeek', () => {
  it('still shows the calendar when nobody filed anything, and says nothing about it', () => {
    const out = week([]);
    expect(out.lines).toEqual([]);
    expect(out.days).toHaveLength(7);
    expect(out.days.every((d) => !d.recorded)).toBe(true);
  });

  it('answers the question a family actually asks', () => {
    expect(week(steady).lines[0]).toBe('Alma ate every meal, every day this week.');
  });

  it('uses the name she is called by, not her full name', () => {
    expect(week(steady).lines[0]).toContain('Alma ');
    expect(week(steady).lines[0]).not.toContain('Reyes');
  });

  it('counts the days a meal went unwritten, not the meals', () => {
    const days = except(1, {
      meals: [
        { slot: 'breakfast', happened: false, amount: null },
        { slot: 'lunch', happened: false, amount: null },
        { slot: 'dinner', happened: true, amount: 'most' },
      ],
    });
    expect(week(days).lines.slice(0, 2)).toEqual([
      'Alma ate every day this week.',
      'On one of them not every meal was written down.',
    ]);
  });

  it('does not claim she ate on a day with nothing ticked at all', () => {
    const days = steady.map((entry, i) =>
      i < 3
        ? { on: entry.on, day: day({ meals: [{ slot: 'lunch', happened: false, amount: null }] }) }
        : entry,
    );
    expect(week(days).lines[0]).toBe('Alma ate on 4 of the 7 days written down.');
  });

  /**
   * Nobody wrote the meals down is not nobody fed her. The sentence stops claiming the whole
   * week the moment one day of it is missing, which is the only honest thing it can do.
   */
  it('does not count a day nobody wrote the meals down on against her', () => {
    const days = except(1, { meals: [] });
    expect(week(days).lines[0]).toBe('Alma ate every meal, every day there is a record for.');
  });

  it('says so when the meals were never written down at all', () => {
    const days = steady.map((entry) => ({ on: entry.on, day: day({ meals: [] }) }));
    expect(week(days).lines[0]).toBe('No meals have been written down this week.');
  });

  it('says how much of the week there is an answer for, when it is not all of it', () => {
    expect(week(steady.slice(0, 3), LAST).lines[0]).toBe(
      '3 of the last 7 days have been written down.',
    );
  });

  it('counts one day as one day', () => {
    expect(week([steady[6]], LAST).lines[0]).toBe('1 of the last 7 days has been written down.');
  });

  it('does not say how much of the week there is an answer for when it is all of it', () => {
    expect(week(steady).lines.join(' ')).not.toContain('written down');
  });

  it('counts nights against what is usual for her, not against sleeping well', () => {
    const hers: Baseline = { ...usual, sleep: 'Restless' };
    const days = steady.map((entry) => ({ on: entry.on, day: day({ sleep: 'Restless' }) }));
    expect(
      familyWeek({
        filed: days,
        baseline: hers,
        residentName: 'Alma Reyes',
        upTo: LAST,
        todayIs: '2026-10-31',
      }).lines.join(' '),
    ).not.toContain('unsettled');
  });

  it('counts an unsettled night when it is not what is usual for her', () => {
    expect(week(except(6, { sleep: 'Restless' })).lines).toContain('One unsettled night.');
  });

  it('counts several nights', () => {
    const days = steady.map((entry, i) =>
      i < 3 ? { on: entry.on, day: day({ sleep: 'Up a lot' }) } : entry,
    );
    expect(week(days).lines).toContain('3 unsettled nights.');
  });

  it('mentions the days something was flagged on', () => {
    expect(week(except(6, { concerns: ['Sundowning'] })).lines).toContain(
      'Something was worth mentioning on one day.',
    );
  });

  it('closes a week with nothing in it by saying so', () => {
    expect(week(steady).lines).toContain('Nothing else changed.');
  });

  it('does not claim nothing changed when something did', () => {
    expect(week(except(6, { sleep: 'Restless' })).lines).not.toContain('Nothing else changed.');
  });

  it('is the seven days ending on the day being read, not the last seven filed', () => {
    const days = Array.from({ length: 21 }, (_, i) => ({
      on: `2026-10-${String(i + 1).padStart(2, '0')}`,
      day: day(),
    }));
    const out = week(days, '2026-10-21');
    expect(out.days).toHaveLength(7);
    expect(out.days[0].on).toBe('2026-10-21');
    expect(out.days[6].on).toBe('2026-10-15');
  });

  /**
   * The point of holding the calendar rather than the records: a quiet weekend must not
   * stretch "this week" backwards over the days either side of it.
   */
  it('does not reach past the week to fill it', () => {
    const days = [
      { on: '2026-10-07', day: day() },
      { on: '2026-09-20', day: day() },
      { on: '2026-09-19', day: day() },
    ];
    const out = week(days);
    expect(out.days.filter((d) => d.recorded).map((d) => d.on)).toEqual(['2026-10-07']);
    expect(out.lines[0]).toBe('1 of the last 7 days has been written down.');
  });

  it('follows the day being read backwards', () => {
    const out = week(steady, '2026-10-03');
    expect(out.days[0].on).toBe('2026-10-03');
    expect(out.days.filter((d) => d.recorded)).toHaveLength(3);
  });

  it('hands the strip the meals it needs to draw a day', () => {
    const days = [
      {
        on: LAST,
        day: day({
          meals: [
            { slot: 'breakfast', happened: true, amount: 'most' },
            { slot: 'lunch', happened: false, amount: null },
          ],
        }),
      },
    ];
    expect(week(days).days[0]).toEqual({
      on: LAST,
      recorded: true,
      inProgress: false,
      meals: 1,
      of: 2,
      steady: true,
    });
  });

  /**
   * A missed meal does not make the day unsteady, here or on the day screen: the day's own
   * summary reads "a steady day" and reports the meals as a count beside it. The strip holds
   * both numbers for the same reason, so a missed lunch shows without the glance contradicting
   * the day a family then opens.
   */
  it('means by steady exactly what the day screen means by it', () => {
    const days = [
      { on: LAST, day: day({ meals: [{ slot: 'lunch', happened: false, amount: null }] }) },
    ];
    expect(week(days).days[0].steady).toBe(true);
    expect(week(days).days[0].meals).toBe(0);
  });

  /** A day nobody filed is not a bad day, and the strip must not draw it as one. */
  it('does not mark an unfiled day unsteady', () => {
    expect(week([steady[6]]).days.every((d) => d.steady)).toBe(true);
  });

  /**
   * The case a family would have met every evening.
   *
   * At two in the afternoon breakfast is ticked and lunch and dinner are not, because they
   * have not happened. The day screen says "not recorded" about exactly those two. The week
   * must not turn the same two into a missed meal.
   */
  describe('a day that is not over yet', () => {
    const partDay = day({
      meals: [
        { slot: 'breakfast', happened: true, amount: 'most' },
        { slot: 'lunch', happened: false, amount: null },
        { slot: 'dinner', happened: false, amount: null },
      ],
    });

    function readToday(days: { on: string; day: FiledDayFacts }[]) {
      return familyWeek({
        filed: days,
        baseline: usual,
        residentName: 'Alma Reyes',
        upTo: LAST,
        todayIs: LAST,
      });
    }

    it('does not count the meals today has not reached yet', () => {
      const days = [...steady.slice(0, 6), { on: LAST, day: partDay }];
      expect(readToday(days).lines[0]).toBe('Alma ate every meal, every day this week so far.');
    });

    it('says so far rather than this week, because today is not in yet', () => {
      const days = [...steady.slice(0, 6), { on: LAST, day: partDay }];
      expect(readToday(days).lines[0]).not.toBe('Alma ate every meal, every day this week.');
    });

    it('still shows today in the strip, with the meals it actually has', () => {
      const days = [...steady.slice(0, 6), { on: LAST, day: partDay }];
      const out = readToday(days);
      expect(out.days[0]).toMatchObject({ on: LAST, inProgress: true, meals: 1, of: 3 });
    });

    it('marks only today as in progress', () => {
      const out = readToday(steady);
      expect(out.days.filter((d) => d.inProgress).map((d) => d.on)).toEqual([LAST]);
    });

    it('says nothing about the week when today is all there is', () => {
      expect(readToday([{ on: LAST, day: partDay }]).lines).toContain(
        'Today is the only day written down so far this week.',
      );
    });

    it('does not describe a week it has only one unfinished day of', () => {
      const lines = readToday([{ on: LAST, day: partDay }]).lines.join(' ');
      expect(lines).not.toContain('ate every meal');
      expect(lines).not.toContain('not every meal was written down');
    });

    /**
     * The other half of the rule, and the half the first version got wrong.
     *
     * Holding today back whatever it said was too blunt. At the end of a shift with all
     * three meals ticked there is nothing still to come, and "so far" understates a day
     * that is fully in. What is kept out is an answer that has not happened yet.
     */
    it('counts today once its meals are all in', () => {
      const days = [...steady.slice(0, 6), steady[6]];
      expect(readToday(days).lines[0]).toBe('Alma ate every meal, every day this week.');
    });

    it('still holds today back while one of its meals is outstanding', () => {
      const days = [...steady.slice(0, 6), { on: LAST, day: partDay }];
      expect(readToday(days).lines[0]).toBe('Alma ate every meal, every day this week so far.');
    });

    it('marks a complete today as today all the same', () => {
      const out = readToday(steady);
      expect(out.days[0]).toMatchObject({ on: LAST, inProgress: true, meals: 3, of: 3 });
    });

    it('counts a complete today alongside a short day behind it', () => {
      const days = [
        ...steady.slice(0, 5),
        { on: '2026-10-06', day: day({ meals: [
          { slot: 'breakfast', happened: true, amount: 'most' },
          { slot: 'lunch', happened: false, amount: null },
          { slot: 'dinner', happened: true, amount: 'most' },
        ] }) },
        steady[6],
      ];
      expect(readToday(days).lines.slice(0, 2)).toEqual([
        'Alma ate every day this week.',
        'On one of them not every meal was written down.',
      ]);
    });

    /** A finished day that really is short still counts, with today left out of it. */
    it('still reports a day behind today that went unwritten', () => {
      const days = [...steady.slice(0, 5), { on: '2026-10-06', day: partDay }, { on: LAST, day: partDay }];
      expect(readToday(days).lines.slice(0, 2)).toEqual([
        'Alma ate every day this week so far.',
        'On one of them not every meal was written down.',
      ]);
    });
  });
});
