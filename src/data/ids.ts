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
