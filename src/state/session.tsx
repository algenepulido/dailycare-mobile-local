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
import type { AccountKind } from '@/data/api';
import { baselineFromWire } from '@/data/wire';
import { governingBaseline } from '@/domain/baseline';
import {
  forgetKind,
  forgetTokens,
  rememberKind,
  storedKind,
  storedRefreshToken,
} from '@/data/credentials';
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
  /** The name the account is held under. Empty until the server has answered once. */
  displayName: string;
  /**
   * The buildings this account runs, as the server last said. Empty for almost everybody,
   * and empty on a cold start until it has answered - which is why the facility screen is
   * reached from a row that appears when this fills rather than one that is always there
   * and refuses.
   */
  manages: api.Building[];
}

interface SessionValue {
  caregiver: Caregiver | null;
  resident: Resident | null;
  account: Account | null;
  /**
   * Which face of the app this device is, as the server last said.
   *
   * A property of the device and not of the session, which is why it outlives a sign-out: a
   * family member's phone is still a family member's phone while nobody is signed in to it,
   * and sending them to a caregiver's first-run setup would ask a daughter to describe her
   * mother's normal day. Cleared by clear(), which is the button that says this is not that
   * phone any more.
   *
   * Remembered between launches because the app renders before any request can come back,
   * and the wrong guess in that gap is a filing form in front of somebody who must never
   * have one. Re-asked on every launch and corrected - a grant withdrawn while the app was
   * closed is the ordinary way it changes.
   *
   * 'staff' when nothing has been remembered, which is right for a device signed in before
   * this existed: it was a caregiver's phone and still is.
   */
  kind: AccountKind;
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
  /** Ask the server again what this account is. Called on launch; safe to call any time. */
  refreshAccount(): Promise<void>;
  /** Accepting an invitation or a reset link. Ends signed in, like signIn. */
  redeem(link: string, password: string): Promise<void>;
  signOut(): Promise<void>;
  clear(): Promise<void>;
}

const SessionContext = createContext<SessionValue | null>(null);

export function SessionProvider({ children }: { children: ReactNode }) {
  const [caregiver, setCaregiver] = useState<Caregiver | null>(null);
  const [resident, setResident] = useState<Resident | null>(null);
  const [account, setAccount] = useState<Account | null>(null);
  const [kind, setKind] = useState<AccountKind>('staff');
  const [signingIn, setSigningIn] = useState(false);
  const [ready, setReady] = useState(false);

  /**
   * What the server says this account is, remembered for the next cold start.
   *
   * Swallows its failure on purpose. Offline is the ordinary case for this app and a
   * session that has ended is handled by the request that needs it, not here - neither is
   * a reason to change what the screen is showing, and changing it would mean a caregiver
   * in a basement corridor losing the form because a status call did not come back.
   */
  const askWhatThisAccountIs = useCallback(async () => {
    try {
      const me = await api.fetchAccount();
      await rememberKind(me.kind);
      setAccount({ userId: me.userId, displayName: me.displayName, manages: me.manages ?? [] });
      setKind(me.kind);
    } catch {
      // Keep what we had.
    }
  }, []);

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
      const [refreshToken, lastKind] = await Promise.all([storedRefreshToken(), storedKind()]);
      if (cancelled) return;
      // The remembered face first, whether or not anybody is signed in: a family phone that
      // was signed out still opens on the family side, asking for a sign-in.
      setKind(asKind(lastKind));
      if (refreshToken) {
        setAccount({ userId: '', displayName: '', manages: [] });
      }
      setReady(true);

      // Then ask, without holding the screen on it. The remembered answer is what gets
      // rendered meanwhile, and a phone with no signal keeps the one it had rather than
      // falling back to a guess.
      if (!cancelled && refreshToken) void askWhatThisAccountIs();
    }

    void restore();
    return () => {
      cancelled = true;
    };
  }, []);

  /**
   * Find this resident on the server and remember which one they are.
   *
   * The local id was made on the phone and the server has never seen it, so a day filed
   * against it is refused - correctly, and confusingly, because everything on the screen
   * looks right. Matching is by name for now, which is enough while a caregiver has one
   * resident and is the wrong answer the moment two of them are called Margaret. A real
   * one is picking from the server's list, and that is a screen rather than a line.
   */
  const linkResident = useCallback(async () => {
    const local = await repository.getActiveIds();
    if (!local.residentId) return;
    const here = await repository.getResident(local.residentId);
    if (!here) return;

    const theirs = await api.listResidents();
    const match = theirs.find(
      (r) => r.displayName.trim().toLowerCase() === here.displayName.trim().toLowerCase(),
    );
    if (!match) return;

    // And take the building's baseline with the link.
    //
    // This copied only the id, and the two halves of the product then compared the same
    // day against two different normals. A family member never sets a baseline up, so
    // their screen reads the one the building holds - the one a care manager typed when
    // she admitted the resident. The caregiver's review sheet read the one on the phone,
    // which starts at the app's default and had never heard of the admission. So the
    // sheet said "this is what the family sees" above a sentence the family would not be
    // shown, and the better the care manager filled the admission in, the further apart
    // they drifted.
    //
    // The building's record wins because it is the one the family is told against, and
    // because it is the one somebody is accountable for having typed.
    const linked = {
      ...here,
      remoteId: match.id,
      baseline: governingBaseline(baselineFromWire(match.baseline), here.baseline),
    };
    await repository.saveResident(linked);
    setResident(linked);
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

      // And point it at the server's resident, if there is an account to ask.
      //
      // This did not, and the gap is the path milestone five created: a caregiver invited by
      // a manager signs in first and sets the phone up afterwards, so linkResident ran at
      // sign-in with nothing to link and never ran again. Her phone then held a resident the
      // server had never heard of, the review sheet correctly offered no send, and the day
      // stayed on the device - while the sheet said nothing is sent until somebody signs in,
      // to somebody who had.
      //
      // Caught by walking the milestone's own test rather than by a test: every unit test
      // that files a day starts from a device that was already linked.
      await linkResident();
    },
    [linkResident],
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
        // A linked phone does not keep its own copy of what is usual for somebody: the
        // building's record is what the family is told against, so editing it here would
        // only move this phone out of step until the next sign-in put it back. The sheet
        // shows it as the building's and does not offer to change it, so nothing is typed
        // here to be dropped.
        const usual = governingBaseline(resident.remoteId ? resident.baseline : null, baseline);
        const next = { ...resident, displayName: residentName.trim(), baseline: usual };
        await repository.saveResident(next);
        setResident(next);
        // And match it to the server's again, because the name is what the match is made
        // on. Changing who this phone is for without re-matching leaves it pointing at the
        // person it used to be for, or at nobody - which is the state a caregiver sees as a
        // day that will not send and no way to find out why.
        //
        // Found walking the milestone's test twice: once when the phone was set up after
        // signing in, and once when the name was corrected afterwards. Both are the same
        // gap, which is that the link was only ever made at sign-in.
        if (next.displayName !== resident.displayName) await linkResident();
      }
    },
    [caregiver, resident, linkResident],
  );


  const signIn = useCallback<SessionValue['signIn']>(
    async (email, password) => {
      setSigningIn(true);
      try {
        const tokens = await api.signIn(email.trim(), password, deviceLabel());
        setAccount({ userId: (tokens as { userId?: string }).userId ?? '', displayName: '', manages: [] });
        // Before linkResident, and awaited: the screen this lands on depends on the answer,
        // and signing in is the one moment the app is certainly online. linkResident is a
        // caregiver's step and does nothing for a family member, who has no resident typed
        // into this phone to match.
        await askWhatThisAccountIs();
        await linkResident();
      } finally {
        setSigningIn(false);
      }
    },
    [askWhatThisAccountIs, linkResident],
  );

  const redeem = useCallback<SessionValue['redeem']>(
    async (link, password) => {
      setSigningIn(true);
      try {
        const tokens = await api.redeem(link, password, deviceLabel());
        setAccount({ userId: (tokens as { userId?: string }).userId ?? '', displayName: '', manages: [] });
        // A family member's grant goes from invited to active inside redeem_token, so this
        // is the first moment the server can answer "family" for them at all - and the
        // moment it has to, because accepting an invitation is how they arrive.
        await askWhatThisAccountIs();
        await linkResident();
      } finally {
        setSigningIn(false);
      }
    },
    [askWhatThisAccountIs, linkResident],
  );

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
    // And the remembered face. This is the one place that forgets it: clearing the device is
    // the act that says it is not a family phone or a caregiver's phone any more.
    await forgetKind();
    setCaregiver(null);
    setResident(null);
    setAccount(null);
    setKind('staff');
  }, []);

  const value = useMemo<SessionValue>(
    () => ({
      caregiver,
      resident,
      account,
      kind,
      signingIn,
      ready,
      startSession,
      updateResident,
      updateSetup,
      signIn,
      redeem,
      signOut,
      clear,
      refreshAccount: askWhatThisAccountIs,
    }),
    [
      caregiver,
      resident,
      account,
      kind,
      signingIn,
      ready,
      startSession,
      updateResident,
      updateSetup,
      signIn,
      redeem,
      signOut,
      clear,
      askWhatThisAccountIs,
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
 * A remembered kind, or the one to assume when nothing has been remembered.
 *
 * Unrecognised values become 'staff' rather than throwing. The only way one gets here is an
 * app older than the server it is talking to, and a caregiver's phone refusing to open
 * because the server named a fourth kind of account would be a worse failure than showing
 * them the form they expect.
 */
function asKind(stored: string | null): AccountKind {
  return stored === 'family' || stored === 'none' || stored === 'staff' ? stored : 'staff';
}

/**
 * What the session row will say when somebody reviews their own devices. Not a device
 * identifier: it is shown to a person deciding which session to end, so it wants to read
 * like "the ward tablet" rather than like a serial number.
 */
function deviceLabel(): string {
  return Platform.select({ ios: 'iPhone', android: 'Android phone', default: 'this device' });
}
