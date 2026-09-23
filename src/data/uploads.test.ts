/**
 * Not sending the same photograph twice.
 *
 * Found on a device: filing a day, then reopening it to add a tick that was missed, put
 * a second copy of the same 137 kB in the bucket under a second name with nothing
 * pointing at it. The day is allowed to be filed again - that is what correcting one is -
 * so the photograph has to know it has already been sent.
 */

const mockStore = new Map<string, string>();

jest.mock('@react-native-async-storage/async-storage', () => ({
  getItem: jest.fn(async (k: string) => mockStore.get(k) ?? null),
  setItem: jest.fn(async (k: string, v: string) => {
    mockStore.set(k, v);
  }),
  removeItem: jest.fn(async (k: string) => {
    mockStore.delete(k);
  }),
  multiRemove: jest.fn(async () => undefined),
}));

jest.mock('expo-secure-store', () => ({
  AFTER_FIRST_UNLOCK: 'afterFirstUnlock',
  setItemAsync: jest.fn(async () => undefined),
  getItemAsync: jest.fn(async () => null),
  deleteItemAsync: jest.fn(async () => undefined),
}));

import { uploadPhoto } from '@/data/api';
import { STORAGE_KEYS } from '@/data/repository';
import { forgetUpload, rememberUpload, uploadedAs } from '@/data/uploads';

const PHOTO = 'file:///data/user/0/ai.inktree.dailycare/files/photos/abc.jpg';

beforeEach(() => {
  mockStore.clear();
  jest.clearAllMocks();
});

test('a photograph is not known until it has been sent', async () => {
  expect(await uploadedAs(PHOTO)).toBeNull();
  await rememberUpload(PHOTO, 'object-1');
  expect(await uploadedAs(PHOTO)).toBe('object-1');
});

test('removing the photograph forgets the object it became', async () => {
  await rememberUpload(PHOTO, 'object-1');
  await forgetUpload(PHOTO);
  expect(await uploadedAs(PHOTO)).toBeNull();
});

test('a replaced photograph is a different file, so it is sent', async () => {
  await rememberUpload(PHOTO, 'object-1');
  expect(await uploadedAs(PHOTO.replace('abc', 'def'))).toBeNull();
});

test('filing the day again sends no bytes and reuses the object', async () => {
  await rememberUpload(PHOTO, 'object-1');
  const fetched = jest.fn();
  global.fetch = fetched as unknown as typeof fetch;

  const id = await uploadPhoto('resident-1', PHOTO, 'care-day-2');

  expect(id).toBe('object-1');
  // Not one call: not the file, not the offer, not the PUT, not the confirmation.
  expect(fetched).not.toHaveBeenCalled();
});

test('the key is one repository.reset() knows about', () => {
  // A key defined anywhere else is a key a cleared session leaves behind, which is how
  // the unsent day once survived signing out.
  expect(Object.values(STORAGE_KEYS)).toContain(STORAGE_KEYS.uploads);
  expect(STORAGE_KEYS.uploads).toBe('inktree_caregiver_uploads_v1');
});

test('a value that is not ours is treated as nothing, not trusted', async () => {
  mockStore.set(STORAGE_KEYS.uploads, '["not","an","object"]');
  expect(await uploadedAs(PHOTO)).toBeNull();
  mockStore.set(STORAGE_KEYS.uploads, 'not json at all');
  expect(await uploadedAs(PHOTO)).toBeNull();
});
