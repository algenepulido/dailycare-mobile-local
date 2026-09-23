/**
 * Which photographs on this phone have already reached the bucket.
 *
 * A day can be filed more than once - correcting a note, adding a tick that was missed -
 * and without this the photograph attached to it was sent again every time. Watching it
 * happen: the same 137 kB arrived in the bucket twice under two names, and the second
 * copy had nothing pointing at it. On a ward's cellular connection that is a caregiver's
 * data paying for a file the server already has.
 *
 * Keyed by the stored file's URI, which persist() makes unique per photograph and keeps
 * for the life of the file, so a replaced photograph is a different key and is uploaded.
 * Persisted rather than held in memory: a correction often happens hours later, after the
 * app has been closed, and an in-memory note would be gone by then.
 */

import AsyncStorage from '@react-native-async-storage/async-storage';

import { STORAGE_KEYS } from './repository';

type Uploaded = Record<string, string>;

async function read(): Promise<Uploaded> {
  const raw = await AsyncStorage.getItem(STORAGE_KEYS.uploads);
  if (!raw) return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    // Anything else on this key is not ours. Treating it as empty costs one re-upload;
    // trusting it would hand an object id straight to the server.
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Uploaded)
      : {};
  } catch {
    return {};
  }
}

/** The object this photograph became, if it has already been sent. */
export async function uploadedAs(uri: string): Promise<string | null> {
  const known = await read();
  return typeof known[uri] === 'string' ? known[uri] : null;
}

export async function rememberUpload(uri: string, objectId: string): Promise<void> {
  const known = await read();
  known[uri] = objectId;
  await AsyncStorage.setItem(STORAGE_KEYS.uploads, JSON.stringify(known));
}

/**
 * Forgotten when the photograph itself is removed from the phone.
 *
 * The object stays in the bucket - removing it is retention's, through the handshake -
 * but this phone has nothing left to attach it to, and a later file:// URI reusing the
 * name would otherwise inherit somebody else's object id.
 */
export async function forgetUpload(uri: string): Promise<void> {
  const known = await read();
  if (!(uri in known)) return;
  delete known[uri];
  await AsyncStorage.setItem(STORAGE_KEYS.uploads, JSON.stringify(known));
}

// There is no clear-everything here on purpose: the key is in STORAGE_KEYS, so
// repository.reset() already removes it when a session ends. A second way to do it is a
// second thing to forget to call.
