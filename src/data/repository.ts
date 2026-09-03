/**
 * Storage for DailyCare.
 *
 * Everything the app reads or writes goes through this interface. For milestone one it is
 * backed by on-device storage holding synthetic records only — no server, no account, and
 * no path for real resident data to enter or leave.
 *
 * The interface is the point. When this moves to a production backend, the implementation
 * below is replaced and the screens above it do not change.
 */

import AsyncStorage from '@react-native-async-storage/async-storage';

import type { Caregiver, CheckIn, ID, Resident } from '@/domain/types';

const KEY = {
  residents: 'dailycare.residents.v1',
  caregivers: 'dailycare.caregivers.v1',
  checkIns: 'dailycare.checkins.v1',
  activeCaregiver: 'dailycare.active.caregiver.v1',
  activeResident: 'dailycare.active.resident.v1',
} as const;

export interface Repository {
  listResidents(): Promise<Resident[]>;
  saveResident(resident: Resident): Promise<void>;
  getResident(id: ID): Promise<Resident | null>;

  listCaregivers(): Promise<Caregiver[]>;
  saveCaregiver(caregiver: Caregiver): Promise<void>;

  listCheckIns(residentId: ID): Promise<CheckIn[]>;
  saveCheckIn(checkIn: CheckIn): Promise<void>;
  /** The most recent entry filed for that day, matching how the weekly report resolves
   *  more than one update for the same date. */
  getCheckInForDate(residentId: ID, careDate: string): Promise<CheckIn | null>;

  getActiveIds(): Promise<{ caregiverId: ID | null; residentId: ID | null }>;
  setActiveIds(ids: { caregiverId: ID | null; residentId: ID | null }): Promise<void>;

  /** Wipes local state. Useful while the data is synthetic. */
  reset(): Promise<void>;
}

async function readList<T>(key: string): Promise<T[]> {
  const raw = await AsyncStorage.getItem(key);
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as T[]) : [];
  } catch {
    // Corrupt entry. Better an empty list than a screen that will not open.
    return [];
  }
}

async function writeList<T>(key: string, items: T[]): Promise<void> {
  await AsyncStorage.setItem(key, JSON.stringify(items));
}

function upsert<T extends { id: ID }>(items: T[], item: T): T[] {
  const index = items.findIndex((existing) => existing.id === item.id);
  if (index === -1) return [...items, item];
  const next = items.slice();
  next[index] = item;
  return next;
}

export const repository: Repository = {
  async listResidents() {
    return readList<Resident>(KEY.residents);
  },

  async saveResident(resident) {
    const residents = await readList<Resident>(KEY.residents);
    await writeList(KEY.residents, upsert(residents, resident));
  },

  async getResident(id) {
    const residents = await readList<Resident>(KEY.residents);
    return residents.find((resident) => resident.id === id) ?? null;
  },

  async listCaregivers() {
    return readList<Caregiver>(KEY.caregivers);
  },

  async saveCaregiver(caregiver) {
    const caregivers = await readList<Caregiver>(KEY.caregivers);
    await writeList(KEY.caregivers, upsert(caregivers, caregiver));
  },

  async listCheckIns(residentId) {
    const checkIns = await readList<CheckIn>(KEY.checkIns);
    return checkIns
      .filter((checkIn) => checkIn.residentId === residentId)
      .sort((a, b) => b.careDate.localeCompare(a.careDate));
  },

  async saveCheckIn(checkIn) {
    const checkIns = await readList<CheckIn>(KEY.checkIns);
    await writeList(KEY.checkIns, upsert(checkIns, checkIn));
  },

  async getCheckInForDate(residentId, careDate) {
    const checkIns = await readList<CheckIn>(KEY.checkIns);
    const forDay = checkIns.filter(
      (checkIn) => checkIn.residentId === residentId && checkIn.careDate === careDate,
    );
    if (forDay.length === 0) return null;
    return forDay.reduce((latest, candidate) =>
      candidate.updatedAt > latest.updatedAt ? candidate : latest,
    );
  },

  async getActiveIds() {
    const [caregiverId, residentId] = await Promise.all([
      AsyncStorage.getItem(KEY.activeCaregiver),
      AsyncStorage.getItem(KEY.activeResident),
    ]);
    return { caregiverId, residentId };
  },

  async setActiveIds({ caregiverId, residentId }) {
    const writes: Promise<void>[] = [];
    writes.push(
      caregiverId
        ? AsyncStorage.setItem(KEY.activeCaregiver, caregiverId)
        : AsyncStorage.removeItem(KEY.activeCaregiver),
    );
    writes.push(
      residentId
        ? AsyncStorage.setItem(KEY.activeResident, residentId)
        : AsyncStorage.removeItem(KEY.activeResident),
    );
    await Promise.all(writes);
  },

  async reset() {
    await AsyncStorage.multiRemove(Object.values(KEY));
  },
};

export default repository;
