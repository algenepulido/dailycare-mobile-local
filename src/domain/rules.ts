/**
 * Product rules carried over from the InkTree caregiver prototype.
 *
 * These decide what the daily summary says, so they live apart from the screens that
 * collect the data and apart from the ones that display it.
 */

import type { Appetite, Baseline, CheckIn, Meal, MealState, Mood, Sleep } from './types';
import { MEALS } from './types';

/* ------------------------------------------------------------------ alert values */

/** Mood values that read as something the family should notice. */
export const ALERT_MOODS: readonly Mood[] = ['Agitated', 'Confused'];

/** Appetite values that read the same way. */
export const ALERT_APPETITES: readonly Appetite[] = ['Poor', 'Refused'];

/**
 * Sleep values treated as an alert.
 *
 * Worth knowing: the prototype marks "Didn't sleep" as an alert value in the input, but
 * the code that assembles the summary never carries an alert flag for sleep the way it
 * does for mood and appetite. A sleepless night therefore never surfaces as an alert in
 * the daily email. That looks unintentional, so it is treated consistently here.
 * Flip SLEEP_CAN_ALERT to false to reproduce the prototype's behaviour exactly.
 */
export const ALERT_SLEEPS: readonly Sleep[] = ["Didn't sleep"];
export const SLEEP_CAN_ALERT = true;

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
  items: string[];
  /** Free text appended to the medication group, when the caregiver entered any. */
  extra?: string;
}

const MEAL_LABELS: Record<Meal, string> = {
  breakfast: 'Breakfast',
  lunch: 'Lunch',
  dinner: 'Dinner',
};

/** Anything other than 'none' counts as done. Partial is still a meal that happened. */
export function mealCounts(meals: Record<Meal, MealState>): { done: number; items: string[] } {
  const items: string[] = [];
  for (const meal of MEALS) {
    const state = meals[meal];
    if (state === 'none') continue;
    items.push(state === 'partial' ? `${MEAL_LABELS[meal]} (partial)` : MEAL_LABELS[meal]);
  }
  return { done: items.length, items };
}

export function buildChecklist(checkIn: CheckIn): ChecklistGroup[] {
  const meals = mealCounts(checkIn.meals);

  const medicationItems: string[] = [];
  if (checkIn.medication.am) medicationItems.push('A.M');
  if (checkIn.medication.pm) medicationItems.push('P.M');

  const hygieneItems: string[] = [];
  if (checkIn.hygiene.shower) hygieneItems.push('Shower');
  if (checkIn.hygiene.grooming) hygieneItems.push('Grooming');

  return [
    { label: 'Meals', done: meals.done, total: MEALS.length, items: meals.items },
    {
      label: 'Medication',
      done: medicationItems.length,
      total: 2,
      items: medicationItems,
      extra: checkIn.supplementalMedication.trim() || undefined,
    },
    { label: 'Hygiene', done: hygieneItems.length, total: 2, items: hygieneItems },
  ];
}
