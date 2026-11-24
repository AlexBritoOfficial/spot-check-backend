// The 18+ gate is the one piece of pure logic in this directory that has a
// legal consequence if it is wrong, so it gets real tests. Run with:
//
//   docker run --rm -v "$PWD":/fn -w /fn --entrypoint deno \
//     denoland/deno:latest test _shared/age_test.ts
import { assertEquals } from 'jsr:@std/assert@1';
import { isAdult } from './age.ts';

// A fixed "now" so these never start failing on a particular date.
const now = new Date(Date.UTC(2026, 10, 24)); // 2026-11-24

Deno.test('clearly an adult', () => {
  assertEquals(isAdult({ year: 1993, month: 4, day: 12 }, now), true);
});

Deno.test('clearly a minor', () => {
  assertEquals(isAdult({ year: 2015, month: 1, day: 1 }, now), false);
});

Deno.test('18th birthday today is an adult', () => {
  assertEquals(isAdult({ year: 2008, month: 11, day: 24 }, now), true);
});

Deno.test('18th birthday tomorrow is not yet an adult', () => {
  // The off-by-one that matters: this must not round up.
  assertEquals(isAdult({ year: 2008, month: 11, day: 25 }, now), false);
});

Deno.test('the day after the 18th birthday is an adult', () => {
  // Born 2008-11-23, so they turned 18 yesterday.
  assertEquals(isAdult({ year: 2008, month: 11, day: 23 }, now), true);
});

Deno.test('leap-year birthday resolves to March 1 in a non-leap year', () => {
  // Born 2008-02-29; turns 18 in 2026, which is not a leap year.
  assertEquals(isAdult({ year: 2008, month: 2, day: 29 }, now), true);
});

Deno.test('missing dob is unknown, not a refusal', () => {
  assertEquals(isAdult(null, now), null);
  assertEquals(isAdult(undefined, now), null);
  assertEquals(isAdult({}, now), null);
});

Deno.test('partial dob is unknown', () => {
  assertEquals(isAdult({ year: 2000, month: 5 }, now), null);
  assertEquals(isAdult({ year: 2000, day: 5 }, now), null);
  assertEquals(isAdult({ month: 5, day: 5 }, now), null);
});

Deno.test('a date that does not exist is unknown, not rolled over', () => {
  // Date.UTC would turn Feb 30 2008 into Mar 1 2008 and call it an adult.
  assertEquals(isAdult({ year: 2008, month: 2, day: 30 }, now), null);
  assertEquals(isAdult({ year: 2008, month: 13, day: 1 }, now), null);
});

Deno.test('year zero and other junk is unknown', () => {
  assertEquals(isAdult({ year: 0, month: 1, day: 1 }, now), null);
});
