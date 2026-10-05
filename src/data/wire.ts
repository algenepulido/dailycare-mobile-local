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
  Baseline,
  CheckIn,
  Concern,
  Meal,
  MealAmount,
  Mood,
  Sleep,
} from '@/domain/types';
import { DEFAULT_BASELINE } from '@/domain/types';

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
  /**
   * The medication the caregiver ticked, as a caregiver's own record of it.
   *
   * Sent from milestone four onwards. It was held back before that on the reasoning that a
   * tick is not a dispensing record, which is true and was half the picture: the schema's own
   * comment on medication_source says a caregiver's tick and a clinical system's entry are
   * both valid and the family should be able to see which they are reading. So it travels,
   * marked as the caregiver's, and a MedTech feed will arrive beside it rather than instead
   * of it.
   */
  medication: { am: boolean; pm: boolean; supplemental: string };
}

/**
 * What the server is given.
 *
 * The photograph is the one thing this does not carry. It has a path of its own, straight to
 * storage, so it never passes through the API at all.
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
    medication: {
      am: checkIn.medication.am,
      pm: checkIn.medication.pm,
      supplemental: checkIn.supplementalMedication.trim(),
    },
  };
}

/**
 * A day as it reads back from the server.
 *
 * Everything but the identifiers is optional, because a day nobody has filed is an empty
 * day rather than a missing one - `filedAt` absent is the difference, and it is the only
 * reliable way to tell. `meals` and `concerns` are always present and may be empty.
 */
export interface FiledDay {
  residentId: string;
  on: string;
  mood?: string;
  appetite?: string;
  sleep?: string;
  note?: string;
  shower?: boolean;
  grooming?: boolean;
  meals: { slot: string; happened: boolean; amount?: string }[];
  concerns: string[];
  filedBy?: string;
  /** The caregiver's name. A family member cannot resolve filedBy - users is closed to them
   *  outside their own row - so the server resolves it for the day they are reading. */
  filedByName?: string;
  filedAt?: string;
  /** What the caregiver recorded about medication, and who recorded it. */
  medication?: { slot: string; status: string; detail?: string; recordedBy?: string }[];
  /** Present on a revision a later one replaced. Absent on the day as it now stands. */
  supersededAt?: string;
  /** True when this version replaced an earlier one. */
  corrected?: boolean;
}

/** What the app shows for a day somebody else already filed. Domain values, which are
 *  also the words on the screen. */
export interface FiledSummary {
  filedAt: string;
  /** What the caregiver recorded about medication, and whose record it is. */
  medication: { slot: string; status: string; detail: string; recordedBy: string }[];
  /** Who filed it, by name. Empty when the server did not say. */
  filedByName: string;
  /** When a correction replaced this one. Null on the version that currently stands, so
   *  a list of revisions tells you which is live without a second field saying so. */
  supersededAt: string | null;
  /** Whether what stands here replaced something. A history marks these without having to
   *  ask for the revisions of every day it shows. */
  corrected: boolean;
  mood: Mood | null;
  appetite: Appetite | null;
  sleep: Sleep | null;
  note: string;
  shower: boolean;
  grooming: boolean;
  meals: { slot: Meal; happened: boolean; amount: MealAmount | null }[];
  concerns: Concern[];
}

/**
 * Inverted from the maps above rather than written out again.
 *
 * A second hand-written table is a second place to forget, and the failure it produces is
 * silent: a day comes back from the server with a mood this app cannot name and the
 * screen shows a blank where a word should be.
 */
function invert<T extends string>(forward: Record<T, string>): Record<string, T> {
  const back: Record<string, T> = {};
  for (const key of Object.keys(forward) as T[]) back[forward[key]] = key;
  return back;
}

const MOOD_BACK = invert(MOOD_WIRE);
const APPETITE_BACK = invert(APPETITE_WIRE);
const SLEEP_BACK = invert(SLEEP_WIRE);
const CONCERN_BACK = invert(CONCERN_WIRE);
const AMOUNT_BACK = invert(AMOUNT_WIRE);
// The slot needs no translation: the domain's own Meal is already 'breakfast' | 'lunch' |
// 'dinner', which is what the column holds. This only guards against a fourth one.
const MEAL_SLOTS: readonly string[] = ['breakfast', 'lunch', 'dinner'];

/**
 * Null for a day nobody has filed, so the caller has one thing to check rather than a
 * shape whose fields are all individually absent.
 *
 * A value the app cannot name becomes null rather than the raw wire string. Showing
 * `up_a_lot` to a caregiver is worse than showing nothing: it looks like a bug in the
 * record rather than a gap in this file.
 */
export function fromWire(day: FiledDay): FiledSummary | null {
  if (!day.filedAt) return null;
  return {
    filedAt: day.filedAt,
    filedByName: day.filedByName ?? '',
    medication: (day.medication ?? []).map((m) => ({
      slot: m.slot,
      status: m.status,
      detail: m.detail ?? '',
      recordedBy: m.recordedBy ?? '',
    })),
    supersededAt: day.supersededAt ?? null,
    corrected: day.corrected ?? false,
    mood: (day.mood && MOOD_BACK[day.mood]) || null,
    appetite: (day.appetite && APPETITE_BACK[day.appetite]) || null,
    sleep: (day.sleep && SLEEP_BACK[day.sleep]) || null,
    note: day.note ?? '',
    shower: day.shower ?? false,
    grooming: day.grooming ?? false,
    meals: (day.meals ?? [])
      .filter((m) => MEAL_SLOTS.includes(m.slot))
      .map((m) => ({
        slot: m.slot as Meal,
        happened: m.happened,
        amount: (m.amount && AMOUNT_BACK[m.amount]) || null,
      })),
    concerns: (day.concerns ?? []).map((c) => CONCERN_BACK[c]).filter(Boolean),
  };
}

/**
 * A resident's baseline as the building has it.
 *
 * Only a family member needs this translated: a caregiver's phone has its own copy, typed
 * during setup and stored in domain words already. The family app has nothing to compare
 * today against until this arrives, and "what changed" is the whole of what it shows.
 *
 * Unlike fromWire this falls back rather than returning null, because a baseline nobody can
 * read would silently turn every observation into a change - a day that was entirely normal
 * would be reported to a daughter as three things to worry about. DEFAULT_BASELINE is the
 * same one the setup sheet opens with, so the failure is a wrong comparison and not an
 * alarming one.
 */
export function baselineFromWire(wire: {
  mood: string;
  appetite: string;
  sleep: string;
}): Baseline {
  return {
    mood: MOOD_BACK[wire.mood] ?? DEFAULT_BASELINE.mood,
    appetite: APPETITE_BACK[wire.appetite] ?? DEFAULT_BASELINE.appetite,
    sleep: SLEEP_BACK[wire.sleep] ?? DEFAULT_BASELINE.sleep,
  };
}
