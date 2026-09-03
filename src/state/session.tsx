/**
 * Who is logging, and for whom.
 *
 * Screens read the active caregiver and resident from here rather than each fetching
 * their own copy, so there is one answer at any moment. When production authentication
 * arrives, the caregiver stops coming from device storage and starts coming from a
 * session — and only this file changes.
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import type { ReactNode } from 'react';

import { newId, nowIso } from '@/data/ids';
import { repository } from '@/data/repository';
import type { Baseline, Caregiver, Resident } from '@/domain/types';

interface SessionValue {
  caregiver: Caregiver | null;
  resident: Resident | null;
  /** False until storage has been read once, so screens do not flash an empty state. */
  ready: boolean;
  startSession(input: {
    caregiverName: string;
    residentName: string;
    baseline: Baseline;
  }): Promise<void>;
  updateResident(resident: Resident): Promise<void>;
  clear(): Promise<void>;
}

const SessionContext = createContext<SessionValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [caregiver, setCaregiver] = useState<Caregiver | null>(null);
  const [resident, setResident] = useState<Resident | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    let cancelled = false;

    async function restore() {
      const { caregiverId, residentId } = await repository.getActiveIds();
      const [caregivers, activeResident] = await Promise.all([
        repository.listCaregivers(),
        residentId ? repository.getResident(residentId) : Promise.resolve(null),
      ]);
      if (cancelled) return;
      setCaregiver(caregivers.find((entry) => entry.id === caregiverId) ?? null);
      setResident(activeResident);
      setReady(true);
    }

    void restore();
    return () => {
      cancelled = true;
    };
  }, []);

  const startSession = useCallback<SessionValue['startSession']>(
    async ({ caregiverName, residentName, baseline }) => {
      const timestamp = nowIso();
      const nextCaregiver: Caregiver = {
        id: newId(),
        displayName: caregiverName.trim(),
        createdAt: timestamp,
      };
      const nextResident: Resident = {
        id: newId(),
        displayName: residentName.trim(),
        baseline,
        createdAt: timestamp,
      };

      await Promise.all([
        repository.saveCaregiver(nextCaregiver),
        repository.saveResident(nextResident),
      ]);
      await repository.setActiveIds({
        caregiverId: nextCaregiver.id,
        residentId: nextResident.id,
      });

      setCaregiver(nextCaregiver);
      setResident(nextResident);
    },
    [],
  );

  const updateResident = useCallback<SessionValue['updateResident']>(async (next) => {
    await repository.saveResident(next);
    setResident(next);
  }, []);

  const clear = useCallback<SessionValue['clear']>(async () => {
    await repository.reset();
    setCaregiver(null);
    setResident(null);
  }, []);

  const value = useMemo<SessionValue>(
    () => ({ caregiver, resident, ready, startSession, updateResident, clear }),
    [caregiver, resident, ready, startSession, updateResident, clear],
  );

  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionValue {
  const value = useContext(SessionContext);
  if (!value) {
    throw new Error('useSession must be used inside a SessionProvider');
  }
  return value;
}
