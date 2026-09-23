/**
 * The API client.
 *
 * The app is local-first and stays that way. A caregiver in a basement corridor with no
 * signal still files the day; this is how it reaches the server afterwards, not a
 * replacement for the storage underneath. Every call here can fail and none of them
 * should stop somebody working.
 */

import { contentTypeFor } from '@/data/photos';
import { rememberUpload, uploadedAs } from '@/data/uploads';
import { fromWire } from '@/data/wire';
import type { FiledDay, FiledSummary, WireDay } from '@/data/wire';
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

/**
 * Send a day to the server.
 *
 * POST, not PUT, and a second one for the same date is not a mistake to swallow — it is a
 * correction, and the database records it as a new row pointing back at what it corrected.
 * Which is why this is not retried on anything but a 401: a retry that the server had
 * already applied would file the same day twice and read as two corrections.
 */
/**
 * A day as the server has it, or null if nobody has filed one.
 *
 * Read on the day screen so a caregiver picking up a phone can see that the shift is
 * already recorded, rather than filing it a second time and turning one day into two
 * corrections. The server answers with an empty day rather than a 404 for a date nobody
 * has touched, so the absence of filedAt is the question being asked here.
 */
export async function fetchDay(residentId: string, date: string): Promise<FiledSummary | null> {
  const body = (await authed(`/v1/residents/${residentId}/days/${date}`)) as FiledDay;
  return fromWire(body);
}

export async function fileDay(residentId: string, date: string, day: WireDay): Promise<string> {
  const body = (await authed(`/v1/residents/${residentId}/days/${date}`, {
    method: 'POST',
    body: JSON.stringify(day),
  })) as { careDayId: string };
  return body.careDayId;
}

export interface PhotoPlace {
  url: string;
  objectId: string;
  expiresAt: string;
}

/**
 * Ask for somewhere to put a photograph, then put it there.
 *
 * The photograph does not go through DailyCare's API. It goes straight to Cloud Storage
 * with a URL good for one object and a few minutes, so a resident's photograph is never in
 * the server's memory or its logs on the way past.
 *
 * Two things that have to match or the upload is refused: the content type is part of what
 * was signed, and the object can only be written once. A retry that appears to succeed
 * locally and fails at the bucket is better than one that quietly replaces a photograph
 * already attached to a filed day.
 */
export interface DayPhoto {
  id: string;
  url: string;
  expiresAt: string;
}

/**
 * Links to the photographs filed for a day.
 *
 * Asked for separately from the day, and only when somebody opens them. Each link costs
 * the server a signing call and cannot be withdrawn once it exists, so reading a day
 * should not mint links nobody is going to look at.
 *
 * The links are short-lived by design. A screen holding one for a long time will find it
 * stops working, and asking again is the answer rather than caching it.
 */
export async function fetchDayPhotos(residentId: string, date: string): Promise<DayPhoto[]> {
  const body = (await authed(`/v1/residents/${residentId}/days/${date}/photos`)) as DayPhoto[];
  return Array.isArray(body) ? body : [];
}

export async function uploadPhoto(
  residentId: string,
  uri: string,
  careDayId?: string,
): Promise<string> {
  // Already in the bucket. A day gets filed more than once - a corrected note, a tick
  // that was missed - and re-sending the photograph each time put a second copy in the
  // bucket with nothing pointing at it, paid for by whatever connection the phone is on.
  const already = await uploadedAs(uri);
  if (already) return already;

  const file = await fetch(uri);
  if (!file.ok) throw new ApiError(0, 'that photograph could not be read from this phone');
  const bytes = await file.blob();

  // From the file's name, which persist() kept. Not from the blob: its `type` is empty
  // for a file:// URI on Android, so reading it gave image/jpeg for a png and Cloud
  // Storage answered SignatureDoesNotMatch - the content type is part of what the URL was
  // signed for, and that 403 reads like a permissions problem and is not one.
  const contentType = contentTypeFor(uri);

  const place = (await authed(`/v1/residents/${residentId}/photos`, {
    method: 'POST',
    body: JSON.stringify({
      contentType,
      byteSize: bytes.size,
      ...(careDayId ? { careDayId } : {}),
    }),
  })) as PhotoPlace;

  // The body is a Blob with its type set, not a Blob plus a header.
  //
  // React Native derives the Content-Type from the blob when one is given, and appends a
  // charset - so a header saying image/png arrives as "image/png; charset=utf-8". The
  // signature covers content-type exactly, so the bucket answers SignatureDoesNotMatch:
  // a 403 that reads like a permissions problem and is not one. Confirmed by sending the
  // same URL three ways with curl - bare works, either charset spelling does not.
  //
  // Setting it on the blob instead means there is one place the type comes from and
  // nothing left to append to it.
  const put = await fetch(place.url, {
    method: 'PUT',
    body: bytes.slice(0, bytes.size, contentType),
  });
  if (!put.ok) {
    // Deliberately not the bucket's XML. It says SignatureDoesNotMatch when the content
    // type is not exactly what was signed and AccessDenied for an overwrite, and both
    // read to a caregiver like they have done something wrong.
    throw new ApiError(put.status, 'the photograph did not upload');
  }

  // Tell the server it arrived. Until this the row is a place that was offered, not a
  // photograph - a phone that lost signal here leaves one behind, and the server lists
  // those rather than showing them to a family.
  await authed(`/v1/photos/${place.objectId}/arrived`, { method: 'POST' });

  // After the server has been told, never before. Remembering an upload the server does
  // not know arrived would skip the only call that can still tell it.
  await rememberUpload(uri, place.objectId);
  return place.objectId;
}
