/**
 * The risk in a translation file is a value that falls through.
 *
 * A mood added to the app and not added here is a day the server refuses, with nothing on
 * the screen to say why — a caregiver taps Send, something goes red, and the note they
 * typed is fine. So these walk every constant the app offers and ask for its translation.
 */

import {
  AMOUNT_WIRE,
  APPETITE_WIRE,
  CONCERN_WIRE,
  MOOD_WIRE,
  SLEEP_WIRE,
  fromWire,
  toWire,
} from '@/data/wire';
import {
  APPETITES,
  CONCERNS,
  MEAL_AMOUNTS,
  MOODS,
  SLEEPS,
  type CheckIn,
} from '@/domain/types';

// The values the database will accept. Copied from schema.sql rather than imported,
// because the point is to notice when the two stop agreeing — a shared constant would
// move on both sides at once and prove nothing.
const DATABASE = {
  mood: ['calm', 'anxious', 'confused', 'withdrawn', 'agitated'],
  appetite: ['good', 'fair', 'poor', 'refused'],
  sleep: ['slept_well', 'restless', 'up_a_lot', 'didnt_sleep'],
  concern: ['wandering', 'sundowning', 'fall_or_near_fall', 'pain', 'skin_concern'],
  amount: ['a_bit', 'half', 'most', 'all'],
};

describe.each([
  ['mood', MOODS, MOOD_WIRE, DATABASE.mood],
  ['appetite', APPETITES, APPETITE_WIRE, DATABASE.appetite],
  ['sleep', SLEEPS, SLEEP_WIRE, DATABASE.sleep],
  ['concern', CONCERNS, CONCERN_WIRE, DATABASE.concern],
  ['meal amount', MEAL_AMOUNTS, AMOUNT_WIRE, DATABASE.amount],
])('%s', (_name, offered, map, accepted) => {
  test('every value the app offers has a translation', () => {
    for (const value of offered) {
      expect(map[value as keyof typeof map]).toBeDefined();
    }
  });

  test('and every translation is one the database accepts', () => {
    for (const value of offered) {
      expect(accepted).toContain(map[value as keyof typeof map]);
    }
  });

  test('and nothing translates to the same thing twice', () => {
    const out = offered.map((v) => map[v as keyof typeof map]);
    expect(new Set(out).size).toBe(out.length);
  });
});

const aDay: CheckIn = {
  id: 'c1',
  residentId: 'r1',
  caregiverId: 'g1',
  careDate: '2026-09-23',
  meals: {
    breakfast: { done: true, amount: 'most' },
    lunch: { done: true, amount: null },
    dinner: { done: false, amount: null },
  },
  medication: { am: true, pm: false },
  hygiene: { shower: true, grooming: false },
  mood: 'Calm',
  appetite: 'Fair',
  sleep: 'Slept well',
  concerns: ['Pain'],
  supplementalMedication: '',
  note: 'settled evening',
  photoUri: null,
  createdAt: '2026-09-23T18:00:00.000Z',
  updatedAt: '2026-09-23T18:00:00.000Z',
};

test('a day the caregiver filed comes out in the database vocabulary', () => {
  const wire = toWire(aDay);
  expect(wire.mood).toBe('calm');
  expect(wire.sleep).toBe('slept_well');
  expect(wire.concerns).toEqual(['pain']);
  expect(wire.shower).toBe(true);
});

test('a meal that happened without an amount sends no amount at all', () => {
  const lunch = toWire(aDay).meals.find((m) => m.slot === 'lunch');
  expect(lunch).toEqual({ slot: 'lunch', happened: true });
  expect('amount' in (lunch ?? {})).toBe(false);
});

test('and a meal that did not happen never carries one', () => {
  const dinner = toWire(aDay).meals.find((m) => m.slot === 'dinner');
  expect(dinner).toEqual({ slot: 'dinner', happened: false });
});

// The schema says an amount without the meal is nonsense and refuses it. Worth a test on
// this side too: the refusal would arrive as a 400 with nothing useful on the screen.
test('an amount is never sent for a meal that did not happen', () => {
  const odd = { ...aDay, meals: { ...aDay.meals, dinner: { done: false, amount: 'all' as const } } };
  const dinner = toWire(odd).meals.find((m) => m.slot === 'dinner');
  expect('amount' in (dinner ?? {})).toBe(false);
});

describe('reading a day back', () => {
  const empty = { residentId: 'r1', on: '2026-09-23T00:00:00Z', meals: [], concerns: [] };

  it('is null for a day nobody has filed', () => {
    // The server answers with an empty day rather than a 404, so filedAt is the question.
    expect(fromWire(empty)).toBeNull();
  });

  it('turns stored values back into the words on the screen', () => {
    const got = fromWire({
      ...empty,
      filedAt: '2026-09-23T16:30:00Z',
      mood: 'withdrawn',
      appetite: 'refused',
      sleep: 'up_a_lot',
      note: 'quiet all afternoon',
      shower: true,
      grooming: false,
      meals: [
        { slot: 'breakfast', happened: true, amount: 'most' },
        { slot: 'lunch', happened: false },
      ],
      concerns: ['fall_or_near_fall', 'skin_concern'],
    })!;

    expect(got.mood).toBe('Withdrawn');
    expect(got.appetite).toBe('Refused');
    expect(got.sleep).toBe('Up a lot');
    expect(got.note).toBe('quiet all afternoon');
    expect(got.shower).toBe(true);
    expect(got.grooming).toBe(false);
    expect(got.meals).toEqual([
      { slot: 'breakfast', happened: true, amount: 'most' },
      { slot: 'lunch', happened: false, amount: null },
    ]);
    expect(got.concerns).toEqual(['Fall / near-fall', 'Skin concern']);
  });

  /**
   * The failure this file exists to prevent, in the other direction. A value the app
   * cannot name must not reach the screen as itself: `up_a_lot` in front of a caregiver
   * reads as a corrupted record rather than as a gap in a translation table.
   */
  it('drops a value it cannot name rather than showing the stored one', () => {
    const got = fromWire({
      ...empty,
      filedAt: '2026-09-23T16:30:00Z',
      mood: 'euphoric',
      meals: [{ slot: 'elevenses', happened: true }],
      concerns: ['abducted_by_gulls'],
    })!;

    expect(got.mood).toBeNull();
    expect(got.meals).toEqual([]);
    expect(got.concerns).toEqual([]);
  });

  it('round-trips every value the app can produce', () => {
    // toWire and fromWire have to agree about every constant, not just the ones a test
    // happened to name. This walks them.
    for (const [label, stored] of Object.entries(MOOD_WIRE)) {
      expect(fromWire({ ...empty, filedAt: 'x', mood: stored })!.mood).toBe(label);
    }
    for (const [label, stored] of Object.entries(APPETITE_WIRE)) {
      expect(fromWire({ ...empty, filedAt: 'x', appetite: stored })!.appetite).toBe(label);
    }
    for (const [label, stored] of Object.entries(SLEEP_WIRE)) {
      expect(fromWire({ ...empty, filedAt: 'x', sleep: stored })!.sleep).toBe(label);
    }
    for (const [label, stored] of Object.entries(CONCERN_WIRE)) {
      expect(fromWire({ ...empty, filedAt: 'x', concerns: [stored] })!.concerns).toEqual([label]);
    }
    for (const [label, stored] of Object.entries(AMOUNT_WIRE)) {
      const meals = [{ slot: 'breakfast', happened: true, amount: stored }];
      expect(fromWire({ ...empty, filedAt: 'x', meals })!.meals[0].amount).toBe(label);
    }
  });
});
