import { backdateWindow, daysEnding, longLabel, relativeLabel, toCareDate } from './dates';
import { BACKDATE_WINDOW_DAYS } from './types';

describe('care dates', () => {
  it('offers exactly the backdate window', () => {
    expect(backdateWindow()).toHaveLength(BACKDATE_WINDOW_DAYS);
  });

  it('puts the most recent day first and runs strictly backwards', () => {
    const window = backdateWindow();
    expect(window[0]).toBe(toCareDate(new Date()));
    expect(window.every((date, index) => index === 0 || date < window[index - 1])).toBe(true);
  });

  it('names the first two days rather than dating them', () => {
    const window = backdateWindow();
    expect(relativeLabel(window[0])).toBe('Today');
    expect(relativeLabel(window[1])).toBe('Yesterday');
    expect(relativeLabel(window[5])).toBe(longLabel(window[5]));
  });

  it('keeps a late evening on its own day', () => {
    // A timestamp would push this into the previous day for anyone west of the caregiver.
    expect(toCareDate(new Date(2026, 8, 3, 23, 30))).toBe('2026-09-03');
  });
});

describe('daysEnding', () => {
  it('ends on the day asked for and runs backwards', () => {
    expect(daysEnding('2026-10-07', 7)).toEqual([
      '2026-10-07',
      '2026-10-06',
      '2026-10-05',
      '2026-10-04',
      '2026-10-03',
      '2026-10-02',
      '2026-10-01',
    ]);
  });

  it('crosses a month without arithmetic of its own', () => {
    expect(daysEnding('2026-10-02', 4)).toEqual([
      '2026-10-02',
      '2026-10-01',
      '2026-09-30',
      '2026-09-29',
    ]);
  });

  it('crosses a year', () => {
    expect(daysEnding('2027-01-01', 2)).toEqual(['2027-01-01', '2026-12-31']);
  });

  it('crosses a leap day', () => {
    expect(daysEnding('2028-03-01', 2)).toEqual(['2028-03-01', '2028-02-29']);
  });
});
