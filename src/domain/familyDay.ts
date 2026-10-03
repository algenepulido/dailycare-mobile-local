/**
 * A filed day, as a family reads it.
 *
 * Separate from the caregiver's view of the same day on purpose, and this file is where that
 * separation lives. The caregiver's screen is an account of a form: counts, flags, what is
 * missing, in the order the form asks for it. That is right for the person filling it in and
 * wrong for a daughter opening her phone — she is not reviewing a care record, she is being
 * told how her mother is.
 *
 * The shape here follows the summary the care home already sends families today. Three
 * things carry over from it and all three are structural rather than cosmetic:
 *
 *   - prose, not counts. "Cathy had breakfast and lunch", never "Meals 2/3 done".
 *   - what went well first, and what did not after it, under its own gentler heading.
 *   - the caregiver's own words kept as words, attributed to the person who wrote them.
 *
 * Nothing here is invented. Every clause is built from something that was recorded, and a
 * day with nothing recorded against it produces nothing to say rather than a cheerful
 * sentence about a day nobody saw.
 *
 * Pure, so the whole of it is testable without a screen, and so the design pass that follows
 * can change every colour and margin without touching what is said.
 */

import type { Baseline, Concern, Meal, MealAmount, Mood, Appetite, Sleep } from './types';
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
}

export interface FamilyDay {
  /** "Maria looked in on Cathy today." — who, and that somebody did. */
  opening: string;
  /** What went well, in sentences. Empty when there is genuinely nothing. */
  wentWell: string[];
  /**
   * What is worth an eye, softened but not hidden. Empty when the day was ordinary, and the
   * heading goes with it — a family should not be shown an empty worry section.
   */
  worthAnEye: string[];
  /** The caregiver's own words, unedited. Empty when they wrote none. */
  note: string;
  /** Whose words they are, for the line above the note. */
  noteBy: string;
}

const MEAL_NAME: Record<Meal, string> = {
  breakfast: 'breakfast',
  lunch: 'lunch',
  dinner: 'dinner',
};

/**
 * Moods, appetites and sleep that are worth saying something about when they differ.
 *
 * Every difference from the baseline is reported — that is what the baseline is for — but
 * the wording is not the same for all of them. "Her appetite was better than usual" belongs
 * with the good news; "poorer than usual" belongs under the gentler heading. The caregiver's
 * screen makes this split with colour; here it is made with where the sentence goes.
 */
const BETTER_MOODS: readonly Mood[] = ['Calm'];
const BETTER_APPETITES: readonly Appetite[] = ['Good'];
const BETTER_SLEEPS: readonly Sleep[] = ['Slept well'];

export function familyDay(
  day: FiledDayFacts,
  baseline: Baseline,
  residentName: string,
  filedBy: string,
): FamilyDay {
  const who = filedBy.trim();
  const them = residentName.trim();

  // Named if the record names them. "Somebody at the care home" rather than a blank, because
  // a family being told nobody looked in would be worse than being told it plainly.
  const opening = who
    ? `${who} looked in on ${them} today.`
    : `Somebody at the care home looked in on ${them} today.`;

  const wentWell: string[] = [];
  const worthAnEye: string[] = [];

  /* ---------------------------------------------------------------- meals */

  const eaten: string[] = [];
  const missed: string[] = [];
  const amounts: string[] = [];
  for (const slot of ['breakfast', 'lunch', 'dinner'] as Meal[]) {
    const m = day.meals.find((x) => x.slot === slot);
    if (!m) continue;
    if (m.happened) {
      eaten.push(MEAL_NAME[slot]);
      // How much, in a sentence of its own. Attached to the meal it read as one phrase with
      // whatever came after it - "breakfast - most of it and lunch" - which is the kind of
      // sentence that is only obvious once somebody reads it aloud.
      if (m.amount) {
        amounts.push(`${MEAL_AMOUNT_LABEL[m.amount].toLowerCase()} of the ${MEAL_NAME[slot]}`);
      }
    } else {
      missed.push(MEAL_NAME[slot]);
    }
  }
  if (eaten.length > 0) {
    const meals = eaten.length === 3 ? 'all three meals' : list(eaten);
    // The amounts close the sentence rather than sitting inside the list. Inside it they
    // read as another item - "breakfast - most of it and lunch" - which is the sort of thing
    // only reading it aloud catches.
    wentWell.push(
      amounts.length > 0
        ? `${them} had ${meals} — ${list(amounts)}.`
        : `${them} had ${meals}.`,
    );
  }
  if (missed.length > 0) {
    // "was not recorded", not "not done". The difference matters and is true: a meal with no
    // tick is a meal nobody wrote down, which is not the same as a meal nobody gave.
    worthAnEye.push(`${capitalise(list(missed))} ${missed.length === 1 ? 'was' : 'were'} not recorded.`);
  }

  /* -------------------------------------------------------------- hygiene */

  if (day.shower && day.grooming) {
    wentWell.push('A shower, and help getting ready.');
  } else if (day.shower) {
    wentWell.push('A shower today.');
  } else if (day.grooming) {
    wentWell.push('Help getting ready today.');
  }
  if (!day.shower && !day.grooming) {
    worthAnEye.push('No shower or grooming was recorded.');
  }

  /* --------------------------------------------- how they were, vs normal */

  const observed: [string | null, string | null, readonly string[], string, string][] = [
    [day.mood, baseline.mood, BETTER_MOODS, 'seemed', 'mood'],
    [day.appetite, baseline.appetite, BETTER_APPETITES, 'had', 'appetite'],
    [day.sleep, baseline.sleep, BETTER_SLEEPS, 'slept', 'sleep'],
  ];

  let anythingDiffered = false;
  for (const [value, usual, better, , kind] of observed) {
    // A value this app cannot name comes back null, and a sentence about nothing is worse
    // than silence - the note and the photograph are still there to read.
    if (!value || !usual) continue;
    if (value === usual) continue;
    anythingDiffered = true;
    const sentence = phrase(them, kind, value, usual);
    (better.includes(value) ? wentWell : worthAnEye).push(sentence);
  }
  if (!anythingDiffered && day.mood && day.appetite && day.sleep) {
    wentWell.push(`${them} was themselves today — mood, appetite and sleep all as usual.`);
  }

  /* ------------------------------------------------------------- concerns */

  for (const concern of day.concerns) {
    worthAnEye.push(`${concernSentence(concern, them)}`);
  }

  return {
    opening,
    wentWell,
    worthAnEye,
    note: day.note.trim(),
    noteBy: who,
  };
}

/**
 * How one observation reads against what is normal for this person.
 *
 * The comparison is always carried, because "poor appetite" means something different for
 * somebody whose appetite is usually poor, and the family is the reader least able to supply
 * that context for themselves.
 */
function phrase(them: string, kind: string, value: string, usual: string): string {
  const v = value.toLowerCase();
  const u = usual.toLowerCase();
  switch (kind) {
    case 'mood':
      return `${them} seemed ${v} today. ${capitalise(u)} is the usual.`;
    case 'appetite':
      return `${them}'s appetite was ${v} today. ${capitalise(u)} is the usual.`;
    default:
      // The two halves need different grammar. What happened last night is a verb - "was up
      // a lot" - and what is usual is a thing - "a restless night". Using the verb for both
      // produced "Slept restlessly is the usual", which is the sort of sentence that only
      // shows itself on a screen.
      return `${them} ${sleepWords(v)} last night. ${usualNight(u)} is the usual.`;
  }
}

function usualNight(value: string): string {
  switch (value) {
    case 'slept well':
      return 'A good night';
    case 'restless':
      return 'A restless night';
    case 'up a lot':
      return 'A broken night';
    default:
      return 'A sleepless night';
  }
}

/**
 * Sleep in two short sentences rather than one long one.
 *
 * The four stored values are a mix of states and manners - "slept well", "up a lot" - and a
 * single sentence comparing one to another came out as "slept in and out of sleep last
 * night, where restlessly is usual". Each is given its own clause instead, which is also how
 * the mood and appetite lines read, so the three of them are one pattern.
 */
function sleepWords(value: string): string {
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

/**
 * A concern as a family should hear it.
 *
 * The stored values are a clinical shorthand - fall_or_near_fall, sundowning - and handing
 * those to a daughter is handing her a category to look up. Each one is said instead.
 */
function concernSentence(concern: Concern, them: string): string {
  switch (concern) {
    case 'Wandering':
      return `${them} wandered at some point today, and the caregiver noted it.`;
    case 'Sundowning':
      return `${them} became more unsettled as the day went on.`;
    case 'Fall / near-fall':
      return `There was a fall or a near-fall today, and the caregiver noted it.`;
    case 'Pain':
      return `${them} was in some pain today.`;
    case 'Skin concern':
      return `Something about ${them}'s skin was worth noting.`;
    default:
      return `${concern} was noted today.`;
  }
}

function list(items: string[]): string {
  if (items.length <= 1) return items[0] ?? '';
  if (items.length === 2) return `${items[0]} and ${items[1]}`;
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`;
}

function capitalise(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}
