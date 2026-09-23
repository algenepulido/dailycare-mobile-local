/**
 * Between what a caregiver reads and what the database stores.
 *
 * The screen says "Slept well" because that is what a person says at the end of a shift.
 * The column is an enum and says `slept_well`, because a label that is also a stored value
 * cannot be reworded without a migration — and somebody will want to reword it.
 *
 * So there are two vocabularies and something has to sit between them. The risk in a file
 * like this is a value that falls through: a new mood added to the app, not added here,
 * and every day filed with it is refused by the server with nothing on the screen to say
 * why. The maps are exhaustive by type — TypeScript refuses an incomplete Record — and
 * there is a test that walks every constant and asks for its translation.
 */

import type {
  Appetite,
  CheckIn,
  Concern,
  Meal,
  MealAmount,
  Mood,
  Sleep,
} from '@/domain/types';

export const MOOD_WIRE: Record<Mood, string> = {
  Calm: 'calm',
  Anxious: 'anxious',
  Confused: 'confused',
  Withdrawn: 'withdrawn',
  Agitated: 'agitated',
};

export const APPETITE_WIRE: Record<Appetite, string> = {
  Good: 'good',
  Fair: 'fair',
  Poor: 'poor',
  Refused: 'refused',
};

export const SLEEP_WIRE: Record<Sleep, string> = {
  'Slept well': 'slept_well',
  Restless: 'restless',
  'Up a lot': 'up_a_lot',
  "Didn't sleep": 'didnt_sleep',
};

export const CONCERN_WIRE: Record<Concern, string> = {
  Wandering: 'wandering',
  Sundowning: 'sundowning',
  'Fall / near-fall': 'fall_or_near_fall',
  Pain: 'pain',
  'Skin concern': 'skin_concern',
};

export const AMOUNT_WIRE: Record<MealAmount, string> = {
  'a-bit': 'a_bit',
  half: 'half',
  most: 'most',
  all: 'all',
};

export interface WireDay {
  mood: string;
  appetite: string;
  sleep: string;
  note: string;
  shower: boolean;
  grooming: boolean;
  meals: { slot: string; happened: boolean; amount?: string }[];
  concerns: string[];
}

/**
 * What the server is given.
 *
 * Two things the app keeps and does not send. Medication is recorded on the device and
 * medication_events is a different table with a different provenance - a tick in this app
 * is a caregiver saying they gave it, and a row from a clinical system is a record that it
 * was dispensed, and the schema is careful about the difference. And the photograph, which
 * has a path of its own that does not exist yet.
 */
export function toWire(checkIn: CheckIn): WireDay {
  return {
    mood: MOOD_WIRE[checkIn.mood],
    appetite: APPETITE_WIRE[checkIn.appetite],
    sleep: SLEEP_WIRE[checkIn.sleep],
    note: checkIn.note,
    shower: checkIn.hygiene.shower,
    grooming: checkIn.hygiene.grooming,
    meals: (Object.keys(checkIn.meals) as Meal[]).map((slot) => {
      const entry = checkIn.meals[slot];
      return {
        slot,
        happened: entry.done,
        // Left off entirely rather than sent as null. The column is "not observed", which
        // is a real answer, and the absence says it more plainly than a null does.
        ...(entry.done && entry.amount ? { amount: AMOUNT_WIRE[entry.amount] } : {}),
      };
    }),
    concerns: checkIn.concerns.map((c) => CONCERN_WIRE[c]),
  };
}
