# DailyCare

Native caregiver app for InkTree. A caregiver records a resident's day, and the family
receives a daily summary and a weekly report.

Built with React Native and Expo, one codebase for iOS and Android.

## Milestone 1 — synthetic MVP

This milestone builds the caregiver flow only, running entirely on the device against
made-up residents. There is no server, no account, and no path for real resident data to
enter or leave the app.

Deliberately not in this milestone: backend and database, production authentication,
family accounts, links and photo download, notifications, email and SMS delivery, weekly
report automation, HIPAA production infrastructure, App Store release, and final visual
polish.

## Getting started

```bash
npm install
npx expo start
```

Press `a` for an Android emulator, `i` for an iOS simulator, or scan the QR code with a
development build on a device.

## Verifying

```bash
npm run verify      # types, then tests
npm run typecheck   # tsc only
npm test            # jest only
```

The product rules — what the family is told, and what counts as worth flagging — are
covered by tests, because that logic is the part a change can quietly get wrong.

## Layout

```
src/
  app/          Screens. File-based routing via expo-router.
  theme/        Design tokens. Every colour, size and type style comes from here.
  domain/       Entities, option sets, and the product rules that decide what the
                summary says.
  data/         Storage, IDs and photos. Screens talk to the repository interface,
                never to storage directly, so the backend can replace it without
                touching the UI.
  state/        Session, and the check-in form reducer.
```

## Notes for later milestones

- **Identity is the ID, never the name.** Residents, caregivers and check-ins all carry
  generated IDs, and check-ins reference them. Family access will be granted against a
  resident ID rather than possession of a link.
- **Photos are kept at original resolution** so the family can be offered a real download
  later without going back for files that were never stored.
- **`src/data/repository.ts` is the seam.** Swapping on-device storage for the production
  API means replacing that one implementation.
- **Design tokens come from the existing InkTree stylesheet**, so the visual direction
  starts from the product's own palette rather than a new one.
