/**
 * The DailyCare domain model.
 *
 * Option sets below are taken verbatim from the InkTree caregiver prototype so the data
 * carries forward unchanged. Entities use generated IDs rather than typed names, so that
 * residents, caregivers and check-ins keep their identity when this moves to a real
 * database and family members are granted access against a resident.
 */

export type ID = string;

/* ------------------------------------------------------------------ option sets */

export const MEALS = ['breakfast', 'lunch', 'dinner'] as const;
export type Meal = (typeof MEALS)[number];

/**
 * How much of a meal was eaten.
 *
 * The web prototype recorded only whether a meal happened. The amount is Trevor's
 * addition, revealed after the meal is ticked rather than asked up front — and it stays
 * optional, so a caregiver who ticks and moves on has still recorded a complete answer.
 */
export const MEAL_AMOUNTS = ['a-bit', 'half', 'most', 'all'] as const;
export type MealAmount = (typeof MEAL_AMOUNTS)[number];

/** What the caregiver reads, and what the summary prints in brackets. */
export const MEAL_AMOUNT_LABEL: Record<MealAmount, string> = {
  'a-bit': 'A bit',
  half: 'Half',
  most: 'Most',
  all: 'All',
};

export interface MealEntry {
  done: boolean;
  /** Null when the meal happened but nobody said how much. */
  amount: MealAmount | null;
}

export const MEDICATION_SLOTS = ['am', 'pm'] as const;
export type MedicationSlot = (typeof MEDICATION_SLOTS)[number];

export const HYGIENE_TASKS = ['shower', 'grooming'] as const;
export type HygieneTask = (typeof HYGIENE_TASKS)[number];

export const MOODS = ['Calm', 'Anxious', 'Confused', 'Withdrawn', 'Agitated'] as const;
export type Mood = (typeof MOODS)[number];

export const APPETITES = ['Good', 'Fair', 'Poor', 'Refused'] as const;
export type Appetite = (typeof APPETITES)[number];

export const SLEEPS = ['Slept well', 'Restless', 'Up a lot', "Didn't sleep"] as const;
export type Sleep = (typeof SLEEPS)[number];

export const CONCERNS = [
  'Wandering',
  'Sundowning',
  'Fall / near-fall',
  'Pain',
  'Skin concern',
] as const;
export type Concern = (typeof CONCERNS)[number];

/* ------------------------------------------------------------------ entities */

/**
 * What this resident is usually like. The daily summary only reports mood, appetite and
 * sleep when they differ from these, and shows the baseline alongside as "usually Calm".
 *
 * The prototype held one baseline for everybody. Per resident is what makes that line
 * true once more than one person is being logged.
 */
export interface Baseline {
  mood: Mood;
  appetite: Appetite;
  sleep: Sleep;
}

export const DEFAULT_BASELINE: Baseline = {
  mood: 'Calm',
  appetite: 'Fair',
  sleep: 'Restless',
};

export interface Resident {
  id: ID;
  displayName: string;
  baseline: Baseline;
  createdAt: string;
}

export interface Caregiver {
  id: ID;
  displayName: string;
  createdAt: string;
}

export interface CheckIn {
  id: ID;
  residentId: ID;
  caregiverId: ID;

  /** ISO date, no time. The day being described, which is not always today. */
  careDate: string;

  meals: Record<Meal, MealEntry>;
  medication: Record<MedicationSlot, boolean>;
  hygiene: Record<HygieneTask, boolean>;

  mood: Mood;
  appetite: Appetite;
  sleep: Sleep;
  concerns: Concern[];

  supplementalMedication: string;
  note: string;

  /** File URI on this device. The original is kept, never a display-sized copy, so the
   *  family can be given a real download later without going back for something that
   *  no longer exists. */
  photoUri: string | null;

  createdAt: string;
  updatedAt: string;
}

/* ------------------------------------------------------------------ defaults */

export const EMPTY_MEALS: Record<Meal, MealEntry> = {
  breakfast: { done: false, amount: null },
  lunch: { done: false, amount: null },
  dinner: { done: false, amount: null },
};

export const EMPTY_MEDICATION: Record<MedicationSlot, boolean> = { am: false, pm: false };

export const EMPTY_HYGIENE: Record<HygieneTask, boolean> = { shower: false, grooming: false };

/** How far back a caregiver may file an entry. Matches the prototype. */
export const BACKDATE_WINDOW_DAYS = 14;
