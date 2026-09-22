/**
 * The API client.
 *
 * The app is local-first and stays that way. A caregiver in a basement corridor with no
 * signal still files the day; this is how it reaches the server afterwards, not a
 * replacement for the storage underneath. Every call here can fail and none of them
 * should stop somebody working.
 */

import {
  currentAccessToken,
  forgetTokens,
  saveTokens,
  storedRefreshToken,
  type Tokens,
} from '@/data/credentials';

const BASE_URL = process.env.EXPO_PUBLIC_API_URL ?? 'http://10.0.2.2:8080';

export class ApiError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly requestId?: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

/** Thrown when the refresh token is gone or refused: the answer is a sign-in screen. */
export class SignedOut extends Error {
  constructor() {
    super('signed out');
    this.name = 'SignedOut';
  }
}

async function parse(response: Response): Promise<unknown> {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text) as unknown;
  } catch {
    // The server answers JSON. Anything else is a proxy, a captive portal on the ward
    // wifi, or a load balancer's error page, and none of them should surface as a parse
    // error to somebody trying to file a care note.
    throw new ApiError(response.status, 'the server did not answer');
  }
}

function messageOf(body: unknown, fallback: string): { message: string; requestId?: string } {
  if (body && typeof body === 'object') {
    const b = body as { error?: unknown; requestId?: unknown };
    return {
      message: typeof b.error === 'string' ? b.error : fallback,
      requestId: typeof b.requestId === 'string' ? b.requestId : undefined,
    };
  }
  return { message: fallback };
}

export async function signIn(email: string, password: string, device: string): Promise<Tokens> {
  const response = await fetch(`${BASE_URL}/v1/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, device }),
  });
  const body = await parse(response);
  if (!response.ok) {
    const { message, requestId } = messageOf(body, 'could not sign in');
    throw new ApiError(response.status, message, requestId);
  }
  const tokens = body as Tokens;
  await saveTokens(tokens);
  return tokens;
}

/**
 * One refresh at a time, ever.
 *
 * Rotation revokes the old token in the same statement that issues the new one, so two
 * requests refreshing at once is not a wasted round trip — it is the second one presenting
 * a token the first has already killed, getting refused, and signing a caregiver out
 * mid-shift for no reason. Everything that needs a token waits on the same promise.
 */
let refreshing: Promise<string> | null = null;

async function refreshOnce(): Promise<string> {
  const refreshToken = await storedRefreshToken();
  if (!refreshToken) throw new SignedOut();

  const response = await fetch(`${BASE_URL}/v1/sessions/refresh`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ refreshToken }),
  });
  if (!response.ok) {
    // Unknown, revoked or expired. Not an error to show: the client has been offline
    // longer than a session lasts, or somebody signed this device out.
    await forgetTokens();
    throw new SignedOut();
  }
  const tokens = (await parse(response)) as Tokens;
  await saveTokens(tokens);
  return tokens.accessToken;
}

async function accessToken(): Promise<string> {
  const held = currentAccessToken();
  if (held) return held;
  if (!refreshing) {
    refreshing = refreshOnce().finally(() => {
      refreshing = null;
    });
  }
  return refreshing;
}

/**
 * An authenticated request, refreshing once if the token turned out to be stale.
 *
 * Once, and only on a 401. Retrying anything else would repeat a write the server may
 * already have applied, and a care note filed twice is a record that says two things
 * happened.
 */
async function authed(path: string, init: RequestInit = {}): Promise<unknown> {
  const send = async (token: string) =>
    fetch(`${BASE_URL}${path}`, {
      ...init,
      headers: {
        ...(init.headers ?? {}),
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
    });

  let response = await send(await accessToken());
  if (response.status === 401) {
    if (!refreshing) {
      refreshing = refreshOnce().finally(() => {
        refreshing = null;
      });
    }
    response = await send(await refreshing);
  }

  const body = await parse(response);
  if (response.status === 401) throw new SignedOut();
  if (!response.ok) {
    const { message, requestId } = messageOf(body, 'that did not work');
    throw new ApiError(response.status, message, requestId);
  }
  return body;
}

export interface RemoteResident {
  id: string;
  displayName: string;
  facilityId: string;
}

export async function listResidents(): Promise<RemoteResident[]> {
  return (await authed('/v1/residents')) as RemoteResident[];
}

export async function signOut(): Promise<void> {
  const refreshToken = await storedRefreshToken();
  await forgetTokens();
  if (!refreshToken) return;
  // Best effort. The tokens are already gone from the device, so a failure here leaves a
  // session the server will expire on its own rather than a caregiver still signed in.
  try {
    await fetch(`${BASE_URL}/v1/sessions`, {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ refreshToken }),
    });
  } catch {
    // Offline. Nothing to do and nothing worth saying.
  }
}
