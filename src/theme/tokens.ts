/**
 * Design tokens for DailyCare.
 *
 * Colour values are lifted from the InkTree caregiver prototype stylesheet, so the app
 * starts from the product's existing visual language instead of a new one. Type, spacing,
 * radius and control sizes are set here too.
 *
 * Everything visual reads from this file. Changing the look later is editing values here,
 * not touching screens.
 */

import { Platform } from 'react-native';

export const color = {
  // Grounds
  paper: '#FBF7F0',
  paperDeep: '#F1E8DA',
  surface: '#FFFFFF',

  // Text, darkest to lightest
  ink: '#1A1410',
  inkMuted: '#3A3128',
  inkSoft: '#6B5F52',
  inkFaint: '#9A8E7F',

  // Hairlines
  line: 'rgba(26, 20, 16, 0.09)',
  lineStrong: 'rgba(26, 20, 16, 0.16)',

  // Accents
  clay: '#C8784F',
  claySoft: '#F2DBCB',
  purple: '#8B47E8',
  sage: '#87A07C',
  sageSoft: '#E0E9D9',

  // Status. Separate from the accents on purpose.
  warn: '#E0A100',
  warnSoft: '#F8E9BE',
  alert: '#E02718',
  alertSoft: '#FBDAD5',

  honeySoft: '#F6E6C4',
  roseSoft: '#F2DCDE',
} as const;

/**
 * The weekly report pairs a serif for headings with the system sans for body text.
 * Georgia ships on iOS; Android resolves 'serif' to Noto Serif, which is close enough
 * to hold the same register.
 */
export const font = {
  serif: Platform.select({ ios: 'Georgia', android: 'serif', default: 'Georgia' }),
  body: Platform.select({ ios: 'System', android: 'sans-serif', default: 'System' }),
} as const;

export const type = {
  display: { fontFamily: font.serif, fontSize: 30, lineHeight: 36, letterSpacing: -0.4 },
  title: { fontFamily: font.serif, fontSize: 22, lineHeight: 28, letterSpacing: -0.2 },
  heading: { fontFamily: font.body, fontSize: 17, lineHeight: 23, fontWeight: '600' as const },
  body: { fontFamily: font.body, fontSize: 16, lineHeight: 23 },
  bodySmall: { fontFamily: font.body, fontSize: 14, lineHeight: 20 },
  label: {
    fontFamily: font.body,
    fontSize: 11,
    lineHeight: 14,
    fontWeight: '600' as const,
    letterSpacing: 0.9,
    textTransform: 'uppercase' as const,
  },
  caption: { fontFamily: font.body, fontSize: 13, lineHeight: 18 },
} as const;

/** 4pt scale. Use these rather than raw numbers. */
export const space = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
  xxxl: 48,
} as const;

export const radius = {
  sm: 8,
  md: 14,
  lg: 22,
  pill: 999,
} as const;

/** Minimum 44pt for anything a thumb has to hit. */
export const control = {
  height: 48,
  heightSmall: 36,
  hitSlop: { top: 8, bottom: 8, left: 8, right: 8 },
} as const;

export const shadow = {
  card: {
    shadowColor: '#1A1410',
    shadowOpacity: 0.05,
    shadowRadius: 10,
    shadowOffset: { width: 0, height: 2 },
    elevation: 1,
  },
} as const;

export const theme = { color, font, type, space, radius, control, shadow } as const;
export default theme;
