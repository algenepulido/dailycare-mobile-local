/**
 * Product rules carried over from the InkTree caregiver prototype.
 *
 * These decide what the daily summary says, so they live apart from the screens that
 * collect the data and apart from the ones that display it.
 */

import type { Appetite, Baseline, CheckIn, Meal, MealEntry, Mood, Sleep } from './types';
import { MEALS, MEAL_AMOUNT_LABEL } from './types';

/* ------------------------------------------------------------------ alert values */

/** Mood values that read as something the family should notice. */
export const ALERT_MOODS: readonly Mood[] = ['Agitated', 'Confused'];

/** Appetite values that read the same way. */
export const ALERT_APPETITES: readonly Appetite[] = ['Poor', 'Refused'];

/**
 * Sleep values treated as an alert *in the chip*, and only there.
 *
 * The web app renders "Didn't sleep" red among the sleep chips, then pushes the sleep
 * change onto the summary with no alert flag at all, so a sleepless night reaches the
 * family as an ordinary change rather than an alert. product-spec § 5.1 states the same
 * split in as many words. Two documents agreeing is not an oversight, so the split is
 * reproduced rather than smoothed over: the chip warns the caregiver at the moment of
 * entry, the summary does not escalate it.
 */
export const ALERT_SLEEPS: readonly Sleep[] = ["Didn't sleep"];
export const SLEEP_CAN_ALERT = false;

/* ------------------------------------------------------------------ what changed */

export type ChangeKind = 'Mood' | 'Appetite' | 'Sleep' | 'Concern';

export interface Change {
  kind: ChangeKind;
  value: string;
  /** Present for observations, absent for concerns. Reads as "usually Calm". */
  baselineNote?: string;
  alert: boolean;
}

/**
 * Builds the "what changed today" list.
 *
 * An observation only appears when it differs from this resident's baseline. Concerns
 * always appear, and always as an alert.
 */
export function buildChanges(checkIn: CheckIn, baseline: Baseline): Change[] {
  const changes: Change[] = [];

  if (checkIn.mood !== baseline.mood) {
    changes.push({
      kind: 'Mood',
      value: checkIn.mood,
      baselineNote: `usually ${baseline.mood}`,
      alert: ALERT_MOODS.includes(checkIn.mood),
    });
  }

  if (checkIn.appetite !== baseline.appetite) {
    changes.push({
      kind: 'Appetite',
      value: checkIn.appetite,
      baselineNote: `usually ${baseline.appetite}`,
      alert: ALERT_APPETITES.includes(checkIn.appetite),
    });
  }

  if (checkIn.sleep !== baseline.sleep) {
    changes.push({
      kind: 'Sleep',
      value: checkIn.sleep,
      baselineNote: `usually ${baseline.sleep}`,
      alert: SLEEP_CAN_ALERT && ALERT_SLEEPS.includes(checkIn.sleep),
    });
  }

  for (const concern of checkIn.concerns) {
    changes.push({ kind: 'Concern', value: concern, alert: true });
  }

  return changes;
}

/* ------------------------------------------------------------------ care checklist */

export interface ChecklistGroup {
  label: string;
  done: number;
  total: number;
  /** Items that happened. Meals carry how much was eaten. */
  doneItems: string[];
  /** Items that did not. Rendered as "Not done: …" in the summary. */
  missedItems: string[];
  /** Free text appended to the medication group, when the caregiver entered any. */
  extra?: string;
}

const MEAL_LABELS: Record<Meal, string> = {
  breakfast: 'Breakfast',
  lunch: 'Lunch',
  dinner: 'Dinner',
};

/**
 * A ticked meal counts as done whether or not anyone said how much was eaten.
 *
 * The amount is optional by design, so it rides along in brackets when it is there and
 * is simply absent when it is not — "Lunch (half)" or plain "Lunch", never a guess.
 */
export function mealCounts(meals: Record<Meal, MealEntry>): {
  done: number;
  items: string[];
  missed: string[];
} {
  const items: string[] = [];
  const missed: string[] = [];
  for (const meal of MEALS) {
    const entry = meals[meal];
    if (!entry.done) {
      missed.push(MEAL_LABELS[meal]);
      continue;
    }
    items.push(
      entry.amount
        ? `${MEAL_LABELS[meal]} (${MEAL_AMOUNT_LABEL[entry.amount].toLowerCase()})`
        : MEAL_LABELS[meal],
    );
  }
  return { done: items.length, items, missed };
}

function split(pairs: [string, boolean][]): { done: string[]; missed: string[] } {
  const done: string[] = [];
  const missed: string[] = [];
  for (const [label, ok] of pairs) (ok ? done : missed).push(label);
  return { done, missed };
}

export function buildChecklist(checkIn: CheckIn): ChecklistGroup[] {
  const meals = mealCounts(checkIn.meals);
  const meds = split([
    ['A.M', checkIn.medication.am],
    ['P.M', checkIn.medication.pm],
  ]);
  const hygiene = split([
    ['Shower', checkIn.hygiene.shower],
    ['Grooming', checkIn.hygiene.grooming],
  ]);

  return [
    {
      label: 'Meals',
      done: meals.done,
      total: MEALS.length,
      doneItems: meals.items,
      missedItems: meals.missed,
    },
    {
      label: 'Medication',
      done: meds.done.length,
      total: 2,
      doneItems: meds.done,
      missedItems: meds.missed,
      extra: checkIn.supplementalMedication.trim() || undefined,
    },
    {
      label: 'Hygiene',
      done: hygiene.done.length,
      total: 2,
      doneItems: hygiene.done,
      missedItems: hygiene.missed,
    },
  ];
}
