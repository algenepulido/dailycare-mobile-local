/**
 * The content type has to be right, not plausible.
 *
 * It is part of what an upload URL is signed for, so a wrong one is answered by Cloud
 * Storage with SignatureDoesNotMatch — a 403 that reads like a permissions problem and is
 * not one. That cost a rebuild to find, because a blob's own `type` is empty for a file://
 * URI on Android and the fallback looked like it was working.
 */

import { contentTypeFor } from '@/data/photos';

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
