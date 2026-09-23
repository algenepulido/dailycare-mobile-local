/**
 * The client's own behaviour, against a fetch that counts what it was asked.
 *
 * Not the server's - that has its own tests in api/ against a real database. What is
 * checked here is the handful of things a client gets wrong in ways that only show up on
 * a ward: refreshing twice, retrying a write, and turning a captive portal into a crash.
 */

// mockStore rather than store: jest hoists the factory above everything and only lets it
// reach variables whose names say they belong to a mock.
const mockStore = new Map<string, string>();

// api.ts reaches AsyncStorage through data/uploads, which remembers which photographs
// have already reached the bucket. Nothing here exercises that; it just has to exist.
jest.mock('@react-native-async-storage/async-storage', () => ({
  getItem: jest.fn(async () => null),
  setItem: jest.fn(async () => undefined),
  removeItem: jest.fn(async () => undefined),
  multiRemove: jest.fn(async () => undefined),
}));

jest.mock('expo-secure-store', () => ({
  AFTER_FIRST_UNLOCK: 'afterFirstUnlock',
  setItemAsync: jest.fn(async (k: string, v: string) => {
    mockStore.set(k, v);
  }),
  getItemAsync: jest.fn(async (k: string) => mockStore.get(k) ?? null),
  deleteItemAsync: jest.fn(async (k: string) => {
    mockStore.delete(k);
  }),
}));

import { listResidents, signIn, SignedOut } from '@/data/api';

type Handler = (url: string, init?: RequestInit) => Response;

function respond(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

let handler: Handler;
const calls: string[] = [];

beforeEach(() => {
  mockStore.clear();
  calls.length = 0;
  global.fetch = jest.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
    const u = String(url);
    calls.push(`${init?.method ?? 'GET'} ${u.replace(/^https?:\/\/[^/]+/, '')}`);
    return handler(u, init);
  }) as unknown as typeof fetch;
});

const tokens = (n: number) => ({
  accessToken: `access-${n}`,
  refreshToken: `refresh-${n}`,
  expiresAt: Date.now() + 15 * 60 * 1000,
  userId: 'u1',
});

test('signing in keeps the tokens and uses them', async () => {
  handler = (url) => {
    if (url.endsWith('/v1/sessions')) return respond(201, tokens(1));
    return respond(200, []);
  };
  await signIn('nurse@example.test', 'a passphrase', 'a test');
  await listResidents();
  expect(calls).toEqual(['POST /v1/sessions', 'GET /v1/residents']);
});

/**
 * The one that matters. Rotation revokes the old token in the same statement that issues
 * the new one, so a second concurrent refresh presents a token the first already killed,
 * is refused, and signs a caregiver out mid-shift for no reason at all.
 */
test('five requests with a stale token cause exactly one refresh', async () => {
  let refreshes = 0;
  let accepted = 'access-2';
  handler = (url, init) => {
    if (url.endsWith('/v1/sessions')) return respond(201, tokens(1));
    if (url.endsWith('/v1/sessions/refresh')) {
      refreshes += 1;
      return respond(200, tokens(2));
    }
    const auth = (init?.headers as Record<string, string>)?.Authorization;
    return auth === `Bearer ${accepted}` ? respond(200, []) : respond(401, { error: 'not signed in' });
  };

  await signIn('nurse@example.test', 'a passphrase', 'a test');
  // The server has moved on; every held token is stale.
  accepted = 'access-2';
  const results = await Promise.all([
    listResidents(),
    listResidents(),
    listResidents(),
    listResidents(),
    listResidents(),
  ]);

  expect(results).toHaveLength(5);
  expect(refreshes).toBe(1);
});

test('a refused refresh signs out rather than looping', async () => {
  handler = (url) => {
    if (url.endsWith('/v1/sessions')) return respond(201, tokens(1));
    if (url.endsWith('/v1/sessions/refresh')) return respond(401, { error: 'sign in again' });
    return respond(401, { error: 'not signed in' });
  };
  await signIn('nurse@example.test', 'a passphrase', 'a test');
  await expect(listResidents()).rejects.toBeInstanceOf(SignedOut);
  // One attempt at the resource, one refresh, and then it stops.
  expect(calls.filter((c) => c.includes('refresh'))).toHaveLength(1);
});

test('no refresh token at all is a sign-in screen, not a crash', async () => {
  handler = () => respond(200, []);
  await expect(listResidents()).rejects.toBeInstanceOf(SignedOut);
});

/** A captive portal on the ward wifi answers HTML to everything. */
test('a page that is not JSON does not surface as a parse error', async () => {
  handler = (url) => {
    if (url.endsWith('/v1/sessions')) return respond(201, tokens(1));
    return new Response('<html>Sign in to WardGuest</html>', { status: 200 });
  };
  await signIn('nurse@example.test', 'a passphrase', 'a test');
  await expect(listResidents()).rejects.toThrow('the server did not answer');
});
