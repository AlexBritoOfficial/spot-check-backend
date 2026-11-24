/**
 * Stripe Identity's `verified_outputs.dob`, as returned for a document check.
 * Every field is optional: a document can verify without a legible DOB.
 */
export interface StripeDob {
  day?: number | null;
  month?: number | null;
  year?: number | null;
}

/**
 * Whether a date of birth makes someone 18 or older.
 *
 * This is the 18+ gate. `profiles.age` is self-reported and may legitimately
 * be 13, which is exactly why it must never be used for this -- see the note
 * in 20261124120000_capabilities_and_identity.sql.
 *
 * Returns `null`, not `false`, when the date of birth is missing or partial.
 * The distinction matters: `false` records "we checked and they are a minor",
 * `null` records "we do not know", and only the first should ever be shown to
 * someone as a refusal.
 *
 * Compared in UTC on purpose. A local-timezone comparison would flip the
 * answer for a few hours around someone's 18th birthday depending on where
 * the server happened to be.
 */
export function isAdult(dob: StripeDob | null | undefined, now: Date = new Date()): boolean | null {
  if (!dob) return null;
  const { day, month, year } = dob;
  if (!day || !month || !year) return null;

  // Date.UTC rolls invalid dates over (Feb 30 -> Mar 2), so a nonsense DOB
  // would silently become a real date. Check the parts survive the round trip.
  const birth = new Date(Date.UTC(year, month - 1, day));
  if (
    birth.getUTCFullYear() !== year ||
    birth.getUTCMonth() !== month - 1 ||
    birth.getUTCDate() !== day
  ) {
    return null;
  }

  // Adding 18 years to a Feb 29 birthday lands on Mar 1 in a non-leap year,
  // which is the conventional (and legally usual) reading.
  const eighteenth = new Date(Date.UTC(year + 18, month - 1, day));
  return eighteenth.getTime() <= now.getTime();
}
