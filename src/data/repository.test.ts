/**
 * What clearing a session removes.
 *
 * Written after a device check found a sixth storage key the reset did not know about.
 * It held the unsent day and was defined in the theme tokens, which is the last place
 * anybody would look for a storage key — so a cleared session left a half-written care
 * day on the phone, and nothing said so.
 */

import AsyncStorage from '@react-native-async-storage/async-storage';

import repository, { STORAGE_KEYS } from './repository';
import { app } from '@/theme/tokens';

jest.mock('@react-native-async-storage/async-storage', () => ({
  multiRemove: jest.fn(async () => undefined),
  getItem: jest.fn(async () => null),
  setItem: jest.fn(async () => undefined),
  removeItem: jest.fn(async () => undefined),
}));

describe('clearing a session', () => {
  beforeEach(() => jest.clearAllMocks());

  it('removes the unsent day as well as the records', async () => {
    await repository.reset();
    const removed = (AsyncStorage.multiRemove as jest.Mock).mock.calls[0][0] as string[];
    expect(removed).toContain(app.draftKey);
  });

  it('removes every key this app writes, so a new one has to be added here to be missed',
    async () => {
      await repository.reset();
      const removed = (AsyncStorage.multiRemove as jest.Mock).mock.calls[0][0] as string[];
      expect(new Set(removed)).toEqual(new Set(Object.values(STORAGE_KEYS)));
    });

  it('and the draft key is the one the code that writes it uses', () => {
    expect(STORAGE_KEYS.draft).toBe(app.draftKey);
  });
});
