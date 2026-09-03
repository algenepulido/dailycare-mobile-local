/**
 * Care dates.
 *
 * A care date is the day being described, which is not always today — a caregiver can
 * file an entry for a day already past. It is a local calendar date, never a timestamp,
 * so an entry does not slide into the previous day for anyone west of the caregiver.
 */

import { BACKDATE_WINDOW_DAYS } from './types';

/** Local calendar date as YYYY-MM-DD. */
export function toCareDate(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

/** Parses a care date back into a local Date at midnight. */
export function fromCareDate(careDate: string): Date {
  const [year, month, day] = careDate.split('-').map(Number);
  return new Date(year, month - 1, day);
}

export function today(): string {
  return toCareDate(new Date());
}

/** The one day back a caregiver reaches for most — catching up on last night. */
export function yesterday(): string {
  return backdateWindow(2)[1];
}

/**
 * The days a caregiver may file against, most recent first. The window matches the
 * prototype, so an entry can be caught up on but not invented weeks later.
 */
export function backdateWindow(days: number = BACKDATE_WINDOW_DAYS): string[] {
  const now = new Date();
  const dates: string[] = [];
  for (let offset = 0; offset < days; offset += 1) {
    const date = new Date(now.getFullYear(), now.getMonth(), now.getDate() - offset);
    dates.push(toCareDate(date));
  }
  return dates;
}

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'] as const;
const MONTHS = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
] as const;

export function weekdayLabel(careDate: string): string {
  return WEEKDAYS[fromCareDate(careDate).getDay()];
}

export function dayNumberLabel(careDate: string): string {
  return String(fromCareDate(careDate).getDate());
}

/** Reads as "Mon, Aug 31", matching the daily summary's own header. */
export function longLabel(careDate: string): string {
  const date = fromCareDate(careDate);
  return `${WEEKDAYS[date.getDay()]}, ${MONTHS[date.getMonth()]} ${date.getDate()}`;
}

/** "Today" and "Yesterday" read better than a date the caregiver has to decode. */
export function relativeLabel(careDate: string): string {
  const window = backdateWindow(2);
  if (careDate === window[0]) return 'Today';
  if (careDate === window[1]) return 'Yesterday';
  return longLabel(careDate);
}
