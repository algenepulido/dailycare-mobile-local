/**
 * The in-progress day, kept on the device between launches.
 *
 * A caregiver fills this in across a shift, not in one sitting, so the form has to
 * survive the app being closed. It must not survive midnight: a draft carrying
 * yesterday's ticks into today would put the wrong day in front of the family.
 */

import AsyncStorage from '@react-native-async-storage/async-storage';

import { longLabel, today } from '@/domain/dates';
import { app } from '@/theme/tokens';

import type { CheckInDraft } from './checkInForm';

interface StoredDraft {
  /** Today's label at save time. A draft is only restored when this still matches. */
  savedOn: string;
  draft: CheckInDraft;
}

/** Debounced so a note being typed does not write on every keystroke. */
const WRITE_DELAY_MS = 300;
let timer: ReturnType<typeof setTimeout> | null = null;

export async function loadDraft(): Promise<CheckInDraft | null> {
  const raw = await AsyncStorage.getItem(app.draftKey);
  if (!raw) return null;
  try {
    const stored = JSON.parse(raw) as StoredDraft;
    if (stored.savedOn !== longLabel(today())) {
      // Yesterday's work. Discard rather than carry it into a new day.
      await AsyncStorage.removeItem(app.draftKey);
      return null;
    }
    return stored.draft;
  } catch {
    await AsyncStorage.removeItem(app.draftKey);
    return null;
  }
}

export function saveDraft(draft: CheckInDraft): void {
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => {
    const stored: StoredDraft = { savedOn: longLabel(today()), draft };
    void AsyncStorage.setItem(app.draftKey, JSON.stringify(stored));
  }, WRITE_DELAY_MS);
}

export async function clearDraft(): Promise<void> {
  if (timer) clearTimeout(timer);
  await AsyncStorage.removeItem(app.draftKey);
}
