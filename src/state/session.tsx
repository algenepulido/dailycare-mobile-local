/**
 * Who is logging, and for whom.
 *
 * Screens read the active caregiver and resident from here rather than each fetching
 * their own copy, so there is one answer at any moment. When production authentication
 * arrives, the caregiver stops coming from device storage and starts coming from a
 * session — and only this file changes.
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';
import { Platform } from 'react-native';
import type { ReactNode } from 'react';

import * as api from '@/data/api';
import { forgetTokens, storedRefreshToken } from '@/data/credentials';
import { newId, nowIso } from '@/data/ids';
import { clearAll as clearAllPhotos } from '@/data/photos';
import { repository } from '@/data/repository';
import type { Baseline, Caregiver, Resident } from '@/domain/types';

/**
 * The account this device is signed in to, if it is.
 *
 * Separate from `caregiver`, which is a name typed on the device and has been since
 * milestone one. Signing in does not replace that and does not have to happen for the app
 * to work: a caregiver in a basement corridor files the day either way. What an account
 * adds is somewhere for the day to go afterwards.
 */
interface Account {
  userId: string;
}

interface SessionValue {
  caregiver: Caregiver | null;
  resident: Resident | null;
  account: Account | null;
  /** True while a sign-in is in flight, so a screen can refuse a second tap. */
  signingIn: boolean;
  /** False until storage has been read once, so screens do not flash an empty state. */
  ready: boolean;
  startSession(input: {
    caregiverName: string;
    residentName: string;
    baseline: Baseline;
  }): Promise<void>;
  updateResident(resident: Resident): Promise<void>;
  /**
   * Correct who is logging, for whom, and what counts as their normal — without losing
   * what has already been filed.
   */
  updateSetup(caregiverName: string, residentName: string, baseline: Baseline): Promise<void>;
  /** Throws ApiError with a message fit to show. */
  signIn(email: string, password: string): Promise<void>;
  signOut(): Promise<void>;
  clear(): Promise<void>;
}

const SessionContext = createContext<SessionValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [caregiver, setCaregiver] = useState<Caregiver | null>(null);
  const [resident, setResident] = useState<Resident | null>(null);
  const [account, setAccount] = useState<Account | null>(null);
  const [signingIn, setSigningIn] = useState(false);
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

      // A refresh token in the keystore means this device was signed in. Whether the
      // session is still good is the server's answer and not worth a round trip here -
      // the first request that needs it will refresh or fail, and neither should hold up
      // a screen the caregiver can already use.
      const refreshToken = await storedRefreshToken();
      if (!cancelled && refreshToken) {
        setAccount({ userId: '' });
      }
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

  const updateSetup = useCallback<SessionValue['updateSetup']>(
    async (caregiverName, residentName, baseline) => {
      if (caregiver) {
        const next = { ...caregiver, displayName: caregiverName.trim() };
        await repository.saveCaregiver(next);
        setCaregiver(next);
      }
      if (resident) {
        const next = { ...resident, displayName: residentName.trim(), baseline };
        await repository.saveResident(next);
        setResident(next);
      }
    },
    [caregiver, resident],
  );

  const signIn = useCallback<SessionValue['signIn']>(async (email, password) => {
    setSigningIn(true);
    try {
      const tokens = await api.signIn(email.trim(), password, deviceLabel());
      setAccount({ userId: (tokens as { userId?: string }).userId ?? '' });
    } finally {
      setSigningIn(false);
    }
  }, []);

  const signOut = useCallback<SessionValue['signOut']>(async () => {
    // The account, not the records. Somebody signing out of a shared ward tablet is
    // finishing a shift, not asking for the day they just filed to be deleted - and
    // clear() is the other thing, with its own button and its own consequences.
    await api.signOut();
    setAccount(null);
  }, []);

  const clear = useCallback<SessionValue['clear']>(async () => {
    // Storage and files both. Clearing one without the other leaves photographs of a
    // resident on the device with no record saying whose they are.
    await repository.reset();
    clearAllPhotos();
    await forgetTokens();
    setCaregiver(null);
    setResident(null);
    setAccount(null);
  }, []);

  const value = useMemo<SessionValue>(
    () => ({
      caregiver,
      resident,
      account,
      signingIn,
      ready,
      startSession,
      updateResident,
      updateSetup,
      signIn,
      signOut,
      clear,
    }),
    [
      caregiver,
      resident,
      account,
      signingIn,
      ready,
      startSession,
      updateResident,
      updateSetup,
      signIn,
      signOut,
      clear,
    ],
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

/**
 * What the session row will say when somebody reviews their own devices. Not a device
 * identifier: it is shown to a person deciding which session to end, so it wants to read
 * like "the ward tablet" rather than like a serial number.
 */
function deviceLabel(): string {
  return Platform.select({ ios: 'iPhone', android: 'Android phone', default: 'this device' });
}
