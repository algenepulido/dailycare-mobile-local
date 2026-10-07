import type { Baseline } from './types';

/**
 * Which "usual" a day is compared against.
 *
 * There are two in the product and only one of them can govern. A care manager types one
 * when she admits somebody, and it lives with the resident in the building's record. A
 * caregiver setting a phone up types another, because a phone can be used for somebody no
 * building holds at all.
 *
 * The building's wins wherever there is one, for two reasons. It is the one a family
 * member's screen reads - they never set a baseline up, so theirs is the resident's
 * record and nothing else - and it is the one somebody is accountable for having typed.
 * A phone keeping its own copy means the caregiver's review sheet promises "this is what
 * the family sees" above a sentence computed from a different normal, and the better the
 * admission was filled in the further the two drift apart.
 */
export function governingBaseline(theirRecord: Baseline | null, onThisPhone: Baseline): Baseline {
  return theirRecord ?? onThisPhone;
}
