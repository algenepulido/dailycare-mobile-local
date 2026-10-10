import { daysEnding } from './dates';
import type { FiledDayFacts } from './familyDay';
import type { Baseline } from './types';

/**
 * A week, in the words a family reads it in.
 *
 * The day's own summary answers "how was today". This answers the question somebody asks on
 * a Sunday evening, which is a different one: is she eating, is she sleeping, is this a good
 * stretch or a bad one. A run of ordinary days is most of that answer, and a run is not
 * something a single day can show.
 *
 * Here rather than on the screen for the same reason familyDay is: this is what a family is
 * told, not how it looks, so it has to be testable without a phone and has to survive the
 * design pass untouched.
 *
 * Three things it refuses to do, each of which makes a week read better and says something
 * untrue:
 *
 *   - it will not treat the last seven filed days as a week. A quiet weekend would stretch
 *     "this week" over ten days.
 *   - it will not count a meal nobody ticked as a meal she did not eat. That is the same
 *     distinction familyDay holds for a single day - not recorded is not not done - and it
 *     is easier to lose across seven days than on one.
 *   - it will not judge today. Today is unfinished: at two in the afternoon lunch and dinner
 *     are not written down because they have not happened, and a sentence that reads that as
 *     a missed meal would alarm a family every single evening. Found by reading a part-filed
 *     day on a phone, where the week said she had left something and the day right above it
 *     said the meals were not recorded yet.
 */

/** Monday to Sunday is somebody's calendar. This is the seven days ending on the day being read. */
export const WEEK_DAYS = 7;

export interface WeekDay {
  /** ISO date, no time. Always present, whether or not anybody filed it. */
  on: string;
  /** Whether anybody filed this day at all. A blank column is not a bad day. */
  recorded: boolean;
  /** Today, whose meals are not all in yet. Shown as a fact, never counted as a shortfall. */
  inProgress: boolean;
  /** How many of the day's meals were ticked, and out of how many are on the record. */
  meals: number;
  of: number;
  /**
   * Nothing differed from what is usual for them.
   *
   * The same question the day screen asks, and deliberately the same answer: mood, appetite,
   * sleep and anything flagged. Meals are not in it, there or here - a day with a missed lunch
   * still reads "a steady day" with the meal count beside it, and a strip that disagreed with
   * the day it leads to would be worse than no strip.
   */
  steady: boolean;
}

export interface FamilyWeek {
  /** Seven days, most recent first. The calendar, not the records. */
  days: WeekDay[];
  /** How the week went. Empty only when nothing in the week was filed at all. */
  lines: string[];
}

export interface WeekRequest {
  /** Every day the server returned, in any order. Days outside the week are ignored. */
  filed: { on: string; day: FiledDayFacts }[];
  /** What is usual for this resident, as the building holds it. */
  baseline: Baseline;
  residentName: string;
  /** The day being read. The week is the seven days ending here. */
  upTo: string;
  /** Today's date, so an unfinished day can be told from an incomplete one. */
  todayIs: string;
}

export function familyWeek({
  filed,
  baseline,
  residentName,
  upTo,
  todayIs,
}: WeekRequest): FamilyWeek {
  const byDate = new Map(filed.map((entry) => [entry.on, entry.day]));
  const them = givenName(residentName);

  const days: WeekDay[] = daysEnding(upTo, WEEK_DAYS).map((on) => {
    const day = byDate.get(on);
    const inProgress = on === todayIs;
    if (!day) return { on, recorded: false, inProgress, meals: 0, of: 0, steady: true };
    return {
      on,
      recorded: true,
      inProgress,
      meals: day.meals.filter((m) => m.happened).length,
      of: day.meals.length,
      steady:
        sameAs(day.mood, baseline.mood) &&
        sameAs(day.appetite, baseline.appetite) &&
        sameAs(day.sleep, baseline.sleep) &&
        day.concerns.length === 0,
    };
  });

  const written = days.filter((d) => d.recorded);
  if (written.length === 0) return { days, lines: [] };

  const lines: string[] = [];

  // How much of the week there is an answer for, said first and only when it is not all of
  // it. A family reading "she ate every day" needs to know whether that was seven days or
  // three before it means anything.
  if (written.length < WEEK_DAYS) {
    lines.push(
      written.length === 1
        ? '1 of the last 7 days has been written down.'
        : `${written.length} of the last 7 days have been written down.`,
    );
  }

  // Eating next, because it is the thing a family actually worries about and the thing a week
  // can answer that a day cannot. Only over days that are finished: today is on the screen
  // above this and speaks for itself.
  const withMeals = written.filter((d) => d.of > 0);
  const done = withMeals.filter((d) => !d.inProgress);

  if (withMeals.length === 0) {
    lines.push('No meals have been written down this week.');
  } else if (done.length === 0) {
    // Only today, and it is not over. Nothing about the week can be said yet.
    lines.push('Today is the only day written down so far this week.');
  } else {
    const span = spanOf(done.length, withMeals.length > done.length);
    const ateEveryDay = done.every((d) => d.meals > 0);
    const everyMeal = done.every((d) => d.meals === d.of);
    const partial = done.filter((d) => d.meals > 0 && d.meals < d.of).length;

    if (everyMeal) {
      lines.push(`${them} ate every meal, ${span}.`);
    } else if (ateEveryDay) {
      lines.push(`${them} ate ${span}.`);
      lines.push(
        partial === 1
          ? 'On one of them not every meal was written down.'
          : `On ${partial} of them not every meal was written down.`,
      );
    } else {
      const ate = done.filter((d) => d.meals > 0).length;
      lines.push(`${them} ate on ${ate} of the ${done.length} days written down.`);
    }
  }

  const unsettledNights = withBoth(written, byDate, (day) => !sameAs(day.sleep, baseline.sleep));
  if (unsettledNights === 1) lines.push('One unsettled night.');
  else if (unsettledNights > 1) lines.push(`${unsettledNights} unsettled nights.`);

  const flagged = withBoth(written, byDate, (day) => day.concerns.length > 0);
  if (flagged === 1) lines.push('Something was worth mentioning on one day.');
  else if (flagged > 1) lines.push(`Something was worth mentioning on ${flagged} days.`);

  if (written.every((d) => d.steady)) lines.push('Nothing else changed.');

  return { days, lines };
}

/**
 * How much of the week a claim about it covers.
 *
 * "This week" only when all seven days are in and finished. "So far" when the only thing
 * missing is today, which is the ordinary case every evening and reads like a person
 * speaking. Otherwise it names what it is about, because a week with gaps in it cannot be
 * described as a week.
 */
function spanOf(finished: number, todayPending: boolean): string {
  if (finished === WEEK_DAYS) return 'every day this week';
  if (todayPending && finished === WEEK_DAYS - 1) return 'every day this week so far';
  return 'every day there is a record for';
}

function withBoth(
  days: WeekDay[],
  byDate: Map<string, FiledDayFacts>,
  holds: (day: FiledDayFacts) => boolean,
): number {
  return days.filter((d) => {
    const day = byDate.get(d.on);
    return day ? holds(day) : false;
  }).length;
}

/** Case and spacing are the screen's; what matters is whether it is the same answer. */
function sameAs(value: string | null, usual: string): boolean {
  if (value === null) return true;
  return value.trim().toLowerCase() === usual.trim().toLowerCase();
}

/** The first word of a name, or all of it. The same rule the day's sentences follow. */
function givenName(name: string): string {
  const first = name.trim().split(/\s+/)[0];
  return first && first.length > 0 ? first : name.trim();
}
