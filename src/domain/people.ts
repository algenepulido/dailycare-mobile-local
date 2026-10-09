/**
 * Telling two people with one name apart.
 *
 * Two Maria Santoses is not a contrivance. It is what the staging instance already had and
 * what a care home with forty staff will have, and a screen that prints the name twice is a
 * screen a care manager cannot act from: ending a membership, taking somebody off a
 * resident and assigning somebody to one are all choices between two rows that read the
 * same.
 *
 * The rule is deliberately building-wide rather than list-wide. A name qualified on one
 * screen and bare on the next reads as a glitch, and worse, it means the absence of an
 * address stops being information - the reader cannot tell "this name is unique" from
 * "this list happened not to contain the other one". So the set is worked out once, from
 * everybody the building knows about, and handed to every list that shows a name.
 */

interface Named {
  id: string;
  displayName: string;
}

/**
 * The display names that belong to more than one person.
 *
 * Counts people, not rows: the same member listed twice - two assignments, a membership
 * read alongside itself - is one person and does not make their own name ambiguous.
 */
export function sharedNames(people: Named[]): Set<string> {
  const seen = new Map<string, Set<string>>();
  for (const person of people) {
    const name = person.displayName.trim();
    if (name === '') continue;
    const holders = seen.get(name) ?? new Set<string>();
    holders.add(person.id);
    seen.set(name, holders);
  }
  const shared = new Set<string>();
  for (const [name, holders] of seen) {
    if (holders.size > 1) shared.add(name);
  }
  return shared;
}

/**
 * The address to show under a name, or null when the name says enough on its own.
 *
 * Null rather than an empty string so a caller renders nothing at all: an empty line under
 * a name still takes the gap above it, and the lists this feeds are tight.
 */
export function addressFor(
  name: string,
  email: string | undefined,
  shared: Set<string>,
): string | null {
  if (!shared.has(name.trim())) return null;
  const address = (email ?? '').trim();
  return address === '' ? null : address;
}

/**
 * One line naming several people, qualifying only the ones that need it.
 *
 * Used where there is no room for a second line - the under-line of a resident's card,
 * which answers "who looks after them". A qualified name is parenthesised rather than
 * given its own line because the line is a sentence of names and the address is an aside
 * in it.
 */
export function nameList(
  people: { displayName: string; email?: string }[],
  shared: Set<string>,
): string {
  return people
    .map((person) => {
      const address = addressFor(person.displayName, person.email, shared);
      return address === null ? person.displayName : `${person.displayName} (${address})`;
    })
    .join(', ');
}

/**
 * The one resident a typed name can mean, or null when it cannot mean exactly one.
 *
 * Never guesses. Matching a name against a list and taking the first hit is what put a
 * caregiver's day, her medication record and her photograph on a different resident and in
 * front of a different family: the building holds two people called Maria Santos, a
 * caregiver picked the second, and the phone linked to the first.
 *
 * Null for none and null for several, deliberately. "I do not know which" and "there is no
 * such person" lead to the same place - this phone is not linked and must not file to the
 * server - and a caller that treats them differently is a caller inventing a third answer.
 */
export function theOnlyMatch<T extends { displayName: string }>(
  people: T[],
  name: string,
): T | null {
  const wanted = name.trim().toLowerCase();
  if (wanted === '') return null;
  const matches = people.filter((p) => p.displayName.trim().toLowerCase() === wanted);
  return matches.length === 1 ? matches[0] : null;
}
