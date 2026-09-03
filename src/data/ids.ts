import * as Crypto from 'expo-crypto';

import type { ID } from '@/domain/types';

/**
 * Identity for every record is a generated ID, never a name someone typed.
 *
 * These are the IDs a check-in references, and the ones a production database and family
 * access will be keyed on later, so they are worth generating properly from the start.
 */
export function newId(): ID {
  return Crypto.randomUUID();
}

export function nowIso(): string {
  return new Date().toISOString();
}

/** Local calendar date as YYYY-MM-DD. Not UTC — the care date is the caregiver's day. */
export function toCareDate(date: Date): string {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}
