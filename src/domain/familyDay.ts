/**
 * A filed day, as a family reads it.
 *
 * The shape follows the daily summary the care home already sends families — the one they
 * get every evening, not the weekly report. Its hierarchy, in its order: what changed today,
 * the care information, the caregiver's note, the photograph, and who the update came from.
 * Holding that order is the whole of this file's job.
 *
 * Two earlier attempts each missed by working from something next to the target. The first
 * shared the caregiver's review block, which is an account of the form the day was entered
 * on: alert colours, the order the form asks in, and nothing saying who wrote it. The second
 * replaced it with prose modelled on the weekly report, which reads well and takes longer to
 * take in than a family evening allows — a daily update is scanned, not read.
 *
 * So the care information is scannable, and the wording is still the family's:
 *
 *   - a meal with no tick is "not recorded", never "not done". Those are different claims
 *     and only one is true: nobody wrote it down is not nobody gave it.
 *   - a concern is said rather than named. A family gets "became more unsettled as the day
 *     went on", not the enum's sundowning.
 *   - every observation carries what is normal for this person, because "poor appetite"
 *     means something different for somebody whose appetite is usually poor, and a family is
 *     the reader least able to supply that for themselves.
 *   - nothing is coloured as an alert. The care home's own daily summary has no flags in it;
 *     flags belong to the caregiver confirming what they filed.
 *
 * Nothing here is invented: every line is built from something that was recorded.
 *
 * Pure, so all of it is testable without a screen, and so the design pass can change every
 * colour, margin and typeface without touching what is said.
 */

import type { Appetite, Baseline, Concern, Meal, MealAmount, Mood, Sleep } from './types';
import { MEAL_AMOUNT_LABEL } from './types';

/** The day as it arrives from the server, narrowed to what a family is told. */
export interface FiledDayFacts {
  mood: Mood | null;
  appetite: Appetite | null;
  sleep: Sleep | null;
  note: string;
  shower: boolean;
  grooming: boolean;
  meals: { slot: Meal; happened: boolean; amount: MealAmount | null }[];
  concerns: Concern[];
  /** What the caregiver recorded about medication, as it came back from the server. */
  medication: { slot: string; status: string; detail: string; recordedBy: string }[];
}

/** One part of the care information, grouped as the daily summary groups it. */
export interface CareGroup {
  label: string;
  /** How much of the group happened, out of how much. Read at a glance. */
  done: number;
  total: number;
  /** What happened, named. "Breakfast (most)", "Shower". */
  did: string[];
  /** What the record does not have. Never "not done" — see the note at the top. */
  didNot: string[];
  /**
   * Where the group's information came from, when that is not obvious and matters.
   *
   * Medication is the one that needs it. The same two letters will mean something different
   * once a clinical feed writes this table — a caregiver's tick is somebody saying they gave
   * a dose, a MedTech's row is a record that one was administered — so the line says whose
   * statement a family is reading. Quiet rather than a disclaimer: it is a provenance note,
   * not a warning.
   */
  source?: string;
}

export interface FamilyDay {
  /** Who the update came from. Said at the top and again at the end, as the summary does. */
  from: string;
  /**
   * What changed today — one list, as the care home's own summary has it, carrying what
   * improved alongside what is worth noticing. A family scanning at the end of a day should
   * not have to join two sections to see what kind of day it was.
   *
   * Empty means the day was ordinary, and the screen says so in a line of its own.
   */
  changed: string[];
  care: CareGroup[];
  /** The caregiver's own words, unedited. Empty when they wrote none. */
  note: string;
}

/**
 * Whose statement the medication line is.
 *
 * Named when the record names them, because "Maria recorded this" is a different sentence
 * from "the system says this" and a family should be able to tell them apart. Nothing at all
 * when there is nothing recorded: a provenance note on an empty group would be a sentence
 * about who did not say something.
 */
function medicationSource(recorder: string, recorded: number): string | undefined {
  if (recorded === 0) return undefined;
  return recorder
    ? `${recorder} recorded this.`
    : 'Recorded by the caregiver.';
}

/** Shown in place of the list when nothing differed from what is normal. */
export const STEADY_DAY = 'A steady day — everything as usual.';

const MEAL_NAME: Record<Meal, string> = {
  breakfast: 'Breakfast',
  lunch: 'Lunch',
  dinner: 'Dinner',
};

export function familyDay(
  day: FiledDayFacts,
  baseline: Baseline,
  residentName: string,
  filedBy: string,
): FamilyDay {
  const them = residentName.trim();
  const changed: string[] = [];

  /* ------------------------------------------- how they were, against normal */

  const observed: [string | null, string | null, string][] = [
    [day.mood, baseline.mood, 'mood'],
    [day.appetite, baseline.appetite, 'appetite'],
    [day.sleep, baseline.sleep, 'sleep'],
  ];
  for (const [value, usual, kind] of observed) {
    // A value this app cannot name comes back null, and a sentence about nothing is worse
    // than silence — the note and the photograph are still there to read.
    if (!value || !usual || value === usual) continue;
    changed.push(phrase(them, kind, value, usual));
  }
  for (const concern of day.concerns) {
    changed.push(concernSentence(concern, them));
  }

  /* --------------------------------------------------- the care information */

  const ate: string[] = [];
  const notEaten: string[] = [];
  for (const slot of ['breakfast', 'lunch', 'dinner'] as Meal[]) {
    const m = day.meals.find((x) => x.slot === slot);
    if (!m) continue;
    if (m.happened) {
      // How much rides along when somebody said, and is absent when they did not. It is
      // optional by design in the form this came from.
      ate.push(
        m.amount
          ? `${MEAL_NAME[slot]} (${MEAL_AMOUNT_LABEL[m.amount].toLowerCase()})`
          : MEAL_NAME[slot],
      );
    } else {
      notEaten.push(MEAL_NAME[slot]);
    }
  }

  const washed = [day.shower ? 'Shower' : null, day.grooming ? 'Grooming' : null].filter(
    (x): x is string => x !== null,
  );
  const notWashed = [day.shower ? null : 'Shower', day.grooming ? null : 'Grooming'].filter(
    (x): x is string => x !== null,
  );

  /* ------------------------------------------------------------- medication */

  const SLOT_NAME: Record<string, string> = { am: 'A.M', pm: 'P.M' };
  const givenSlots: string[] = [];
  const notRecorded: string[] = [];
  const supplemental: string[] = [];
  let recorder = '';
  for (const slot of ['am', 'pm'] as const) {
    const e = day.medication.find((m) => m.slot === slot);
    // 'given' is the only status this app can produce. The others belong to a clinical feed
    // and are read rather than written here, so they are named rather than counted.
    if (e && e.status === 'given') {
      givenSlots.push(SLOT_NAME[slot]);
      if (!recorder && e.recordedBy) recorder = e.recordedBy;
    } else {
      notRecorded.push(SLOT_NAME[slot]);
    }
  }
  for (const e of day.medication) {
    if (e.slot !== 'supplemental' || !e.detail) continue;
    supplemental.push(e.detail);
    if (!recorder && e.recordedBy) recorder = e.recordedBy;
  }

  const care: CareGroup[] = [
    { label: 'Meals', done: ate.length, total: 3, did: ate, didNot: notEaten },
    {
      label: 'Medication',
      done: givenSlots.length,
      total: 2,
      did: supplemental.length > 0 ? [...givenSlots, ...supplemental] : givenSlots,
      didNot: notRecorded,
      // Trevor's own distinction, in his words: today this is a caregiver saying they gave
      // it; once PointClickCare feeds the table it becomes a record that a dose was
      // administered. The line changes with the source rather than being decided here.
      source: medicationSource(recorder, givenSlots.length + supplemental.length),
    },
    { label: 'Hygiene', done: washed.length, total: 2, did: washed, didNot: notWashed },
  ];

  return { from: filedBy.trim(), changed, care, note: day.note.trim() };
}

/**
 * How one observation reads against what is normal.
 *
 * One sentence rather than two: under a heading that already says what it is, a family
 * scanning wants the comparison in the same breath as the observation.
 */
function phrase(them: string, kind: string, value: string, usual: string): string {
  const v = value.toLowerCase();
  const u = usual.toLowerCase();
  switch (kind) {
    case 'mood':
      return `${them} seemed ${v} today, where ${u} is usual.`;
    case 'appetite':
      return `${them}'s appetite was ${v} today, where ${u} is usual.`;
    default:
      // Sleep needs two different forms in the one sentence: what happened last night is
      // something a person did, and what is usual is a kind of night. One form for both
      // produced "slept restlessly, where restlessly is usual".
      return `${them} ${sleptLike(v)} last night, where ${usualNight(u)} is usual.`;
  }
}

function sleptLike(value: string): string {
  switch (value) {
    case 'slept well':
      return 'slept well';
    case 'restless':
      return 'slept restlessly';
    case 'up a lot':
      return 'was up a lot';
    default:
      return 'barely slept';
  }
}

function usualNight(value: string): string {
  switch (value) {
    case 'slept well':
      return 'a good night';
    case 'restless':
      return 'a restless night';
    case 'up a lot':
      return 'a broken night';
    default:
      return 'a sleepless night';
  }
}

/**
 * A concern as a family should hear it.
 *
 * The stored values are a clinical shorthand — fall_or_near_fall, sundowning — and handing
 * those to a daughter is handing her a category to go and look up.
 */
function concernSentence(concern: Concern, them: string): string {
  switch (concern) {
    case 'Wandering':
      return `${them} wandered at some point today, and the caregiver noted it.`;
    case 'Sundowning':
      return `${them} became more unsettled as the day went on.`;
    case 'Fall / near-fall':
      return 'There was a fall or a near-fall today, and the caregiver noted it.';
    case 'Pain':
      return `${them} was in some pain today.`;
    case 'Skin concern':
      return `Something about ${them}'s skin was worth noting.`;
    default:
      return `${concern} was noted today.`;
  }
}
