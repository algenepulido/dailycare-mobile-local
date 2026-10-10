/**
 * The content type has to be right, not plausible.
 *
 * It is part of what an upload URL is signed for, so a wrong one is answered by Cloud
 * Storage with SignatureDoesNotMatch — a 403 that reads like a permissions problem and is
 * not one. That cost a rebuild to find, because a blob's own `type` is empty for a file://
 * URI on Android and the fallback looked like it was working.
 */

// A file system that holds whatever a test puts on it, so the guard below can be shown
// the two cases that matter: a file that is not there, and one with nothing in it.
jest.mock('expo-file-system', () => {
  const shelf: Record<string, { exists: boolean; size: number | null }> = {};
  class MockFile {
    at: string;
    constructor(at: string) {
      this.at = at;
    }
    get exists() {
      return shelf[this.at] ? shelf[this.at].exists : false;
    }
    get size() {
      return shelf[this.at] ? shelf[this.at].size : null;
    }
  }
  class MockDirectory {
    exists = true;
    create() {}
  }
  return {
    File: MockFile,
    Directory: MockDirectory,
    Paths: { document: 'file:///documents' },
    __shelf: shelf,
  };
});

import { PHOTO_EMPTY, contentTypeFor, photoSize } from '@/data/photos';

// Puts a file on the shelf the mock above reads from.
function onDisk(uri: string, exists: boolean, size: number | null) {
  const shelf = (jest.requireMock('expo-file-system') as { __shelf: Record<string, unknown> })
    .__shelf;
  shelf[uri] = { exists, size };
}

test.each([
  ['file:///data/user/0/app/files/photos/abc.jpg', 'image/jpeg'],
  ['file:///data/user/0/app/files/photos/abc.jpeg', 'image/jpeg'],
  ['file:///data/user/0/app/files/photos/abc.png', 'image/png'],
  ['file:///data/user/0/app/files/photos/abc.PNG', 'image/png'],
  ['file:///data/user/0/app/files/photos/abc.heic', 'image/heic'],
  ['file:///data/user/0/app/files/photos/abc.heif', 'image/heic'],
  ['file:///data/user/0/app/files/photos/abc.webp', 'image/webp'],
])('%s is %s', (uri, expected) => {
  expect(contentTypeFor(uri)).toBe(expected);
});

test('a name with no extension is a photograph from a camera, which is jpeg', () => {
  expect(contentTypeFor('file:///data/user/0/app/files/photos/abc')).toBe('image/jpeg');
});

test('a query string does not become part of the extension', () => {
  expect(contentTypeFor('file:///photos/abc.png?width=100')).toBe('image/png');
});

// The bucket only accepts these. A type this returns that the server refuses is an upload
// that fails after the day was already filed.
test('every type this can return is one the server accepts', () => {
  // Copied from api/internal/media/media.go rather than shared. A constant both sides
  // imported would move on both at once and prove nothing - the point is to notice when
  // they stop agreeing. The first version of this test left .webp out of the names below
  // and passed while the client could produce a type the server refused.
  const accepted = ['image/jpeg', 'image/png', 'image/heic', 'image/webp'];
  const produced = new Set(
    ['a.jpg', 'a.jpeg', 'a.png', 'a.PNG', 'a.heic', 'a.heif', 'a.webp', 'a'].map((n) =>
      contentTypeFor('file:///photos/' + n),
    ),
  );
  for (const type of produced) {
    expect(accepted).toContain(type);
  }
});

/**
 * Reading a photograph back off the phone.
 *
 * The guard matters more than the reader. An empty file uploaded anyway puts a row in the
 * table saying a photograph arrived with nothing behind it, and a family is then shown a
 * broken image. That is worse than a row saying it never came, because that one is on a
 * list to be tidied up.
 */
describe('reading a photograph off the phone', () => {
  const uri = 'file:///data/user/0/app/files/photos/a.jpg';

  it('hands back what is on disk', () => {
    onDisk(uri, true, 4096);
    expect(photoSize(uri)).toBe(4096);
  });

  it('refuses a file that is not there', () => {
    onDisk(uri, false, null);
    expect(() => photoSize(uri)).toThrow(PHOTO_EMPTY);
  });

  it('refuses one with no image in it', () => {
    // The case that actually happened: persist() did not wait for the copy it started,
    // so a photograph picked and uploaded in the same breath was empty, and the upload
    // went ahead with it - an object with nothing in it, marked as arrived.
    onDisk(uri, true, 0);
    expect(() => photoSize(uri)).toThrow(PHOTO_EMPTY);
  });
});
