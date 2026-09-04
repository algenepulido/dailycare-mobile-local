/**
 * The check-in form.
 *
 * A day's entry has around a dozen moving parts, so the state lives here as a reducer
 * rather than a pile of hooks inside the screen. The screen stays a description of what
 * the caregiver sees; this file owns what a change means.
 */

import { useCallback, useEffect, useReducer, useRef, useState } from 'react';
import { AppState } from 'react-native';

import { newId, nowIso } from '@/data/ids';
import { repository } from '@/data/repository';
import { today } from '@/domain/dates';
import { clearDraft, loadDraft, saveDraft } from './draft';
import type {
  Appetite,
  Baseline,
  CheckIn,
  Concern,
  HygieneTask,
  ID,
  Meal,
  MealEntry,
  MealAmount,
  MedicationSlot,
  Mood,
  Sleep,
} from '@/domain/types';
import { EMPTY_HYGIENE, EMPTY_MEALS, EMPTY_MEDICATION } from '@/domain/types';

export interface CheckInDraft {
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
  photoUri: string | null;
}

/**
 * A fresh day starts at the resident's baseline, so the caregiver only moves what was
 * actually different. Leaving it untouched is a real answer, not a skipped field.
 */
export function emptyDraft(baseline: Baseline, careDate: string = today()): CheckInDraft {
  return {
    careDate,
    meals: { ...EMPTY_MEALS },
    medication: { ...EMPTY_MEDICATION },
    hygiene: { ...EMPTY_HYGIENE },
    mood: baseline.mood,
    appetite: baseline.appetite,
    sleep: baseline.sleep,
    concerns: [],
    supplementalMedication: '',
    note: '',
    photoUri: null,
  };
}

function draftFrom(checkIn: CheckIn): CheckInDraft {
  return {
    careDate: checkIn.careDate,
    meals: { ...checkIn.meals },
    medication: { ...checkIn.medication },
    hygiene: { ...checkIn.hygiene },
    mood: checkIn.mood,
    appetite: checkIn.appetite,
    sleep: checkIn.sleep,
    concerns: [...checkIn.concerns],
    supplementalMedication: checkIn.supplementalMedication,
    note: checkIn.note,
    photoUri: checkIn.photoUri,
  };
}

/* ------------------------------------------------------------------ reducer */

type Action =
  | { type: 'replace'; draft: CheckInDraft }
  | { type: 'toggleMeal'; meal: Meal; done: boolean }
  | { type: 'setMealAmount'; meal: Meal; amount: MealAmount }
  | { type: 'toggleMedication'; slot: MedicationSlot }
  | { type: 'toggleHygiene'; task: HygieneTask }
  | { type: 'setMood'; value: Mood }
  | { type: 'setAppetite'; value: Appetite }
  | { type: 'setSleep'; value: Sleep }
  | { type: 'toggleConcern'; concern: Concern }
  | { type: 'setSupplementalMedication'; value: string }
  | { type: 'setNote'; value: string }
  | { type: 'setPhoto'; uri: string | null };

function reducer(state: CheckInDraft, action: Action): CheckInDraft {
  switch (action.type) {
    case 'replace':
      return action.draft;
    case 'toggleMeal':
      return {
        ...state,
        meals: {
          ...state.meals,
          // Unticking clears the amount: a meal that did not happen cannot have one.
          [action.meal]: action.done
            ? { done: true, amount: state.meals[action.meal].amount }
            : { done: false, amount: null },
        },
      };
    case 'setMealAmount':
      return {
        ...state,
        meals: { ...state.meals, [action.meal]: { done: true, amount: action.amount } },
      };
    case 'toggleMedication':
      return {
        ...state,
        medication: { ...state.medication, [action.slot]: !state.medication[action.slot] },
      };
    case 'toggleHygiene':
      return {
        ...state,
        hygiene: { ...state.hygiene, [action.task]: !state.hygiene[action.task] },
      };
    case 'setMood':
      return { ...state, mood: action.value };
    case 'setAppetite':
      return { ...state, appetite: action.value };
    case 'setSleep':
      return { ...state, sleep: action.value };
    case 'toggleConcern':
      return {
        ...state,
        concerns: state.concerns.includes(action.concern)
          ? state.concerns.filter((concern) => concern !== action.concern)
          : [...state.concerns, action.concern],
      };
    case 'setSupplementalMedication':
      return { ...state, supplementalMedication: action.value };
    case 'setNote':
      return { ...state, note: action.value };
    case 'setPhoto':
      return { ...state, photoUri: action.uri };
    default:
      return state;
  }
}

/* ------------------------------------------------------------------ hook */

interface UseCheckInFormOptions {
  residentId: ID;
  caregiverId: ID;
  baseline: Baseline;
}

export interface CheckInForm {
  draft: CheckInDraft;
  dispatch: React.Dispatch<Action>;
  /** Care dates that already have an entry, so the strip can mark the gaps. */
  filedDates: string[];
  /** True while an entry for the selected day is being read. */
  loading: boolean;
  saving: boolean;
  /** True when this day already has an entry and saving will supersede it. */
  editingExisting: boolean;
  selectDate(careDate: string): void;
  save(): Promise<CheckIn | null>;
}

export function useCheckInForm({
  residentId,
  caregiverId,
  baseline,
}: UseCheckInFormOptions): CheckInForm {
  const [draft, dispatch] = useReducer(reducer, undefined, () => emptyDraft(baseline));
  const [filedDates, setFiledDates] = useState<string[]>([]);
  const [existingId, setExistingId] = useState<ID | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const draftDayRef = useRef<string>(today());

  const loadDay = useCallback(
    async (careDate: string) => {
      setLoading(true);
      const existing = await repository.getCheckInForDate(residentId, careDate);
      if (existing) {
        setExistingId(existing.id);
        dispatch({ type: 'replace', draft: draftFrom(existing) });
      } else {
        setExistingId(null);
        dispatch({ type: 'replace', draft: emptyDraft(baseline, careDate) });
      }
      setLoading(false);
    },
    [residentId, baseline],
  );

  const refreshFiledDates = useCallback(async () => {
    const entries = await repository.listCheckIns(residentId);
    setFiledDates([...new Set(entries.map((entry) => entry.careDate))]);
  }, [residentId]);

  /**
   * Restore the in-progress draft before anything else, so a caregiver who reopens the
   * app mid-shift finds their ticks where they left them. A stored day that is not today
   * is discarded inside loadDraft.
   */
  useEffect(() => {
    let cancelled = false;
    async function restore() {
      const stored = await loadDraft();
      if (cancelled) return;
      if (stored) {
        setExistingId(null);
        dispatch({ type: 'replace', draft: stored });
        setLoading(false);
      } else {
        await loadDay(today());
      }
      await refreshFiledDates();
    }
    void restore();
    return () => {
      cancelled = true;
    };
  }, [loadDay, refreshFiledDates]);

  // Native apps stay resident, so a form left open overnight has to be caught on return.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (next) => {
      if (next !== 'active') return;
      if (draftDayRef.current !== today()) void loadDay(today());
    });
    return () => sub.remove();
  }, [loadDay]);

  useEffect(() => {
    draftDayRef.current = draft.careDate;
    if (!loading) saveDraft(draft);
  }, [draft, loading]);

  const selectDate = useCallback(
    (careDate: string) => {
      void loadDay(careDate);
    },
    [loadDay],
  );

  const save = useCallback(async (): Promise<CheckIn | null> => {
    if (saving) return null;
    setSaving(true);
    try {
      const timestamp = nowIso();
      const checkIn: CheckIn = {
        id: existingId ?? newId(),
        residentId,
        caregiverId,
        careDate: draft.careDate,
        meals: draft.meals,
        medication: draft.medication,
        hygiene: draft.hygiene,
        mood: draft.mood,
        appetite: draft.appetite,
        sleep: draft.sleep,
        concerns: draft.concerns,
        supplementalMedication: draft.supplementalMedication.trim(),
        note: draft.note.trim(),
        photoUri: draft.photoUri,
        createdAt: timestamp,
        updatedAt: timestamp,
      };
      await repository.saveCheckIn(checkIn);
      await clearDraft();
      setExistingId(checkIn.id);
      await refreshFiledDates();
      return checkIn;
    } finally {
      setSaving(false);
    }
  }, [saving, existingId, residentId, caregiverId, draft, refreshFiledDates]);

  return {
    draft,
    dispatch,
    filedDates,
    loading,
    saving,
    editingExisting: existingId !== null,
    selectDate,
    save,
  };
}
