/**
 * DailyCare design tokens.
 *
 * These are the values from the handoff package's tokens.ts, which were extracted from
 * the live caregiver web app. Warm paper and ink, not the purple-on-white the earlier
 * handoff described — that design no longer exists.
 *
 * Everything visual reads from this file, so the polish pass against design-system.md is
 * an adjustment of values rather than a rewrite of screens.
 */

/*
 * Imported one weight per entry point, not from the package root.
 *
 * Each package's index re-exports every face it ships as a top-level `require` of a .ttf.
 * Metro registers an asset require as a side effect, so importing a single name from the
 * root still bundles the whole family — three Nanum Myeongjo faces and ten Rethink Sans,
 * italics included, when the type scale asks for one and five.
 */
import { NanumMyeongjo_700Bold } from '@expo-google-fonts/nanum-myeongjo/700Bold';
import { RethinkSans_400Regular } from '@expo-google-fonts/rethink-sans/400Regular';
import { RethinkSans_500Medium } from '@expo-google-fonts/rethink-sans/500Medium';
import { RethinkSans_600SemiBold } from '@expo-google-fonts/rethink-sans/600SemiBold';
import { RethinkSans_700Bold } from '@expo-google-fonts/rethink-sans/700Bold';
import { RethinkSans_800ExtraBold } from '@expo-google-fonts/rethink-sans/800ExtraBold';

export const color = {
  ink: '#1A1410',
  ink2: '#3A3128',
  ink3: '#6B5F52',
  ink4: '#9A8E7F',
  paper: '#FBF7F0',
  paper2: '#F1E8DA',
  frame: '#E7DBC9',
  white: '#FFFFFF',

  /** Exactly one use: the "Add contact" link in the review sheet. */
  purple: '#8B47E8',
  clay: '#C8784F',
  claySoft: '#F2DBCB',
  flag: '#E02718',
  flagSoft: '#FBDAD5',
  warn: '#E0A100',
  warnSoft: '#F8E9BE',
  sage: '#87A07C',
  sageSoft: '#E0E9D9',
  honeySoft: '#F6E6C4',
  roseSoft: '#F2DCDE',

  line: 'rgba(26,20,16,0.09)',
  line2: 'rgba(26,20,16,0.16)',
  scrim: 'rgba(26,20,16,0.4)',
} as const;

export const fontFamily = {
  /** Headings only, and only at bold — every serif line in the type scale asks for 700. */
  serif: {
    bold: 'NanumMyeongjo_700Bold',
  },
  sans: {
    regular: 'RethinkSans_400Regular',
    medium: 'RethinkSans_500Medium',
    semiBold: 'RethinkSans_600SemiBold',
    bold: 'RethinkSans_700Bold',
    extraBold: 'RethinkSans_800ExtraBold',
  },
} as const;

/** Bundled into the binary, so nothing is fetched at runtime. */
export const fontAssets = {
  NanumMyeongjo_700Bold,
  RethinkSans_400Regular,
  RethinkSans_500Medium,
  RethinkSans_600SemiBold,
  RethinkSans_700Bold,
  RethinkSans_800ExtraBold,
} as const;

export const type = {
  screenTitle: { fontFamily: fontFamily.serif.bold, fontSize: 30, lineHeight: 32, letterSpacing: -0.6 },
  sectionHeading: { fontFamily: fontFamily.serif.bold, fontSize: 22, letterSpacing: -0.22 },
  cardTitle: { fontFamily: fontFamily.serif.bold, fontSize: 20 },
  sheetTitle: { fontFamily: fontFamily.serif.bold, fontSize: 22 },
  /** The setup drawer opens larger than a plain sheet, closer to a screen title. */
  setupTitle: { fontFamily: fontFamily.serif.bold, fontSize: 26, lineHeight: 28.6, letterSpacing: -0.02 },
  checklistItem: { fontFamily: fontFamily.sans.regular, fontSize: 18 },
  body: { fontFamily: fontFamily.sans.regular, fontSize: 15 },
  input: { fontFamily: fontFamily.sans.regular, fontSize: 16 },
  buttonPrimary: { fontFamily: fontFamily.sans.bold, fontSize: 16 },
  chip: { fontFamily: fontFamily.sans.semiBold, fontSize: 14 },
  fieldLabel: { fontFamily: fontFamily.sans.semiBold, fontSize: 13, color: color.ink2 },
  meta: { fontFamily: fontFamily.sans.regular, fontSize: 13, color: color.ink3 },
  /** Sits under a sheet title or a section label to say why the section exists. */
  blurb: { fontFamily: fontFamily.sans.regular, fontSize: 14, lineHeight: 20.3, color: color.ink3 },
  hint: { fontFamily: fontFamily.sans.regular, fontSize: 13, lineHeight: 18.85, color: color.ink3 },
  sectionLabel: {
    fontFamily: fontFamily.sans.bold,
    fontSize: 11,
    letterSpacing: 1.5,
    textTransform: 'uppercase' as const,
    color: color.ink3,
  },
  changedTag: {
    fontFamily: fontFamily.sans.bold,
    fontSize: 10,
    letterSpacing: 0.5,
    textTransform: 'uppercase' as const,
    color: color.warn,
  },
  badge: {
    fontFamily: fontFamily.sans.bold,
    fontSize: 11,
    letterSpacing: 1,
    textTransform: 'uppercase' as const,
  },
} as const;

export const radii = {
  card: 22,
  innerCard: 14,
  contactRow: 16,
  pillButton: 28,
  smallButton: 22,
  chip: 999,
  checkbox: 9,
  selectionCircle: 12,
  sheetInput: 14,
  /** The setup drawer's baseline card. Between a card (22) and a review inner card (14). */
  setupCard: 18,
  inlineInput: 12,
  sheetTop: 30,
  photoButton: 16,
  photoThumb: 10,
} as const;

export const sizes = {
  screenPaddingH: 22,
  cardGap: 8,
  sectionGap: 22,
  scrollBottomPadding: 130,
  pillButtonHeight: 56,
  smallButtonHeight: 44,
  chipHeight: 40,
  checkbox: 28,
  selectionCircle: 24,
  sheetInputHeight: 52,
  inlineInputHeight: 46,
  avatarLarge: 44,
  avatarMedium: 40,
  avatarSmall: 30,
  grabHandle: { width: 40, height: 4 },
  photoButtonHeight: 52,
  photoButtonHeightAttached: 64,
  minTouchTarget: 44,
} as const;

export const motion = {
  sheet: { durationMs: 340, easing: [0.32, 0.72, 0, 1] as const },
  spinner: { durationMs: 700 },
} as const;

export const opacity = { disabled: 0.4 } as const;

export const app = {
  displayName: 'DailyCare',
  /** Same keys as the web app, so the shapes stay recognisable across the two. */
  storeKey: 'inktree_caregiver_v1',
  draftKey: 'inktree_caregiver_draft_v1',
  backdateLimitDays: 14,
  /** For the send milestone. Milestone 1 keeps photos at full resolution. */
  photoMaxEdgePx: 1280,
  photoJpegQuality: 0.82,
} as const;

export const theme = { color, fontFamily, fontAssets, type, radii, sizes, motion, opacity, app } as const;
export default theme;
