/**
 * Design tokens for DailyCare+.
 *
 * These are InkTree's real tokens, taken from the Daily Care package stylesheet — purple
 * primary on white surfaces with near-black text, not the cream and terracotta the older
 * caregiver web page used.
 *
 * Everything visual reads from this file. Changing the look later is editing values here,
 * not touching screens.
 */

export const color = {
  // Grounds
  paper: '#FFFFFF',
  paperDeep: '#F5F5F7',
  surface: '#FFFFFF',

  // Text, darkest to lightest
  ink: '#0C0C0C',
  inkMuted: '#333333',
  inkSoft: '#6E6E6E',
  inkFaint: '#9A9AA2',

  // Hairlines
  line: 'rgba(12, 12, 14, 0.09)',
  lineStrong: 'rgba(12, 12, 14, 0.16)',

  // Brand
  purple: '#923CF6',
  purpleDeep: '#7A2FF0',
  purpleSoft: '#F1E9FE',
  peach: '#F3ECFD',
  peachDeep: '#E7D8FA',

  // Accents
  clay: '#FF9933',
  claySoft: '#FFE7CC',
  honey: '#FFB84D',
  honeySoft: '#FFEBCC',
  rose: '#EC407A',
  roseSoft: '#FBDCE8',
  sky: '#5368EE',
  skySoft: '#E1E5FB',

  // Status. Separate from the brand on purpose.
  sage: '#4FB85E',
  sageSoft: '#E2F5E4',
  warn: '#E8952B',
  warnSoft: '#FFEBCF',
  alert: '#F0483F',
  alertSoft: '#FFE0DE',
} as const;

/**
 * Headings are set in the serif, everything else in the sans, matching the reference.
 * The serif is subset to Latin — the full face carries a Korean glyph set this app has
 * no use for, and it costs nine megabytes.
 */
export const fontFamily = {
  serif: 'NanumMyeongjo-Bold',
  sans: 'RethinkSans-Regular',
  sansMedium: 'RethinkSans-Medium',
  sansBold: 'RethinkSans-ExtraBold',
} as const;

/** Loaded once at startup. Keys must match the names above. */
export const fontAssets = {
  'NanumMyeongjo-Bold': require('../../assets/fonts/NanumMyeongjo-Bold.ttf'),
  'RethinkSans-Regular': require('../../assets/fonts/RethinkSans-Regular.ttf'),
  'RethinkSans-Medium': require('../../assets/fonts/RethinkSans-Medium.ttf'),
  'RethinkSans-ExtraBold': require('../../assets/fonts/RethinkSans-ExtraBold.ttf'),
} as const;

export const type = {
  /** Screen title. "Daily Care Information" in the reference. */
  display: { fontFamily: fontFamily.serif, fontSize: 30, lineHeight: 33, letterSpacing: -0.6 },
  /** Section heading above a card. "Anything different today?" */
  section: { fontFamily: fontFamily.serif, fontSize: 22, lineHeight: 27, letterSpacing: -0.2 },
  /** Card heading. "Meals", "Medication", "Note for Admin". */
  cardTitle: { fontFamily: fontFamily.serif, fontSize: 20, lineHeight: 25 },

  body: { fontFamily: fontFamily.sans, fontSize: 15, lineHeight: 21 },
  /** Checklist rows sit larger than body — they are the thing being tapped. */
  bodyLarge: { fontFamily: fontFamily.sans, fontSize: 18, lineHeight: 24 },
  bodySmall: { fontFamily: fontFamily.sans, fontSize: 14, lineHeight: 20 },
  caption: { fontFamily: fontFamily.sans, fontSize: 13, lineHeight: 18 },
  /** Field labels beside an observation row. */
  fieldLabel: { fontFamily: fontFamily.sansMedium, fontSize: 13, lineHeight: 17 },
  /** The "CHANGED" marker and the caregiver badge. */
  marker: {
    fontFamily: fontFamily.sansBold,
    fontSize: 10,
    lineHeight: 13,
    letterSpacing: 0.5,
    textTransform: 'uppercase' as const,
  },
  chip: { fontFamily: fontFamily.sansMedium, fontSize: 14, lineHeight: 18 },
  button: { fontFamily: fontFamily.sansBold, fontSize: 16, lineHeight: 20 },
} as const;

/** 4pt scale. Use these rather than raw numbers. */
export const space = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 22,
  xxl: 32,
  xxxl: 48,
} as const;

/** Cards in the reference are generously rounded — 22, and 999 for chips. */
export const radius = {
  sm: 9,
  md: 12,
  lg: 16,
  card: 22,
  pill: 999,
} as const;

/** Minimum 44pt for anything a thumb has to hit. */
export const control = {
  height: 48,
  chipHeight: 40,
  checkbox: 28,
  saveHeight: 56,
  hitSlop: { top: 8, bottom: 8, left: 8, right: 8 },
} as const;

export const theme = { color, fontFamily, fontAssets, type, space, radius, control } as const;
export default theme;
