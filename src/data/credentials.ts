/**
 * Where the tokens live.
 *
 * The refresh token is a credential: anyone holding it can mint access tokens until it
 * expires or is revoked. AsyncStorage is a plain SQLite file in the app's sandbox, which
 * is fine for a draft care note and wrong for this — so it goes to the Keychain on iOS and
 * the Keystore on Android through expo-secure-store.
 *
 * The access token is short-lived and is deliberately not persisted at all. Keeping it
 * would save one round trip after a cold start and leave a bearer token on disk for
 * fifteen minutes; refreshing is cheap and the refresh token is already the thing that
 * survives a restart.
 */

import * as SecureStore from 'expo-secure-store';

const REFRESH_KEY = 'dailycare.refresh.v1';

export interface Tokens {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

/** Held in memory only, and gone when the process is. */
let access: { token: string; expiresAt: number } | null = null;

export async function saveTokens(tokens: Tokens): Promise<void> {
  access = { token: tokens.accessToken, expiresAt: tokens.expiresAt };
  await SecureStore.setItemAsync(REFRESH_KEY, tokens.refreshToken, {
    // Available after first unlock rather than whenever, because the retention job and a
    // background sync both run without anybody holding the phone.
    keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK,
  });
}

export function currentAccessToken(): string | null {
  if (!access) return null;
  // A minute of slack. A token that expires while the request is in flight comes back as
  // a 401 and costs a round trip; refreshing slightly early costs nothing.
  if (Date.now() > access.expiresAt - 60_000) return null;
  return access.token;
}

export async function storedRefreshToken(): Promise<string | null> {
  return SecureStore.getItemAsync(REFRESH_KEY);
}

export async function forgetTokens(): Promise<void> {
  access = null;
  await SecureStore.deleteItemAsync(REFRESH_KEY);
}
