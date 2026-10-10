import { router, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, Screen, Sheet } from '@/components';
import { RevisionsSheet } from '@/components/RevisionsSheet';
import { TrailSheet } from '@/components/TrailSheet';
import { SignedOut, fetchDayRevisions, fetchHistory, fetchTrail } from '@/data/api';
import type { HistoryDay, TrailEntry } from '@/data/api';
import type { FiledSummary } from '@/data/wire';
import { useSession } from '@/state/session';
import { color, radii, type } from '@/theme/tokens';

/** Fri, Sep 25 - the form the rest of the app uses for a care date. */
function dayLabel(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString(undefined, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  });
}

/** One line saying what the day holds, for somebody scanning three weeks of them. */
function oneLine(summary: FiledSummary): string {
  const parts: string[] = [];
  const meals = summary.meals.filter((m) => m.happened).length;
  if (meals > 0) parts.push(`${meals} of 3 meals`);
  const hygiene = [summary.shower, summary.grooming].filter(Boolean).length;
  if (hygiene > 0) parts.push(hygiene === 2 ? 'shower and grooming' : summary.shower ? 'shower' : 'grooming');
  if (summary.concerns.length > 0) {
    parts.push(summary.concerns.length === 1 ? '1 concern' : `${summary.concerns.length} concerns`);
  }
  return parts.length > 0 ? parts.join(' · ') : 'Nothing recorded';
}

/**
 * Three weeks of one resident, most recent first.
 *
 * Only the days somebody filed. A screen of blank rows for the days nobody did says
 * nothing a caregiver does not already know, and the gaps between the rows are the part
 * worth seeing.
 *
 * A day that was corrected says so, and opening it shows every version rather than a note
 * that one existed. That is the whole claim a care record makes about itself: amended,
 * not overwritten, and the thing it was amended from is still there to read.
 */
export default function HistoryScreen() {
  const { resident } = useSession();
  // Reached from the residents list for somebody this phone is not set up for, and from
  // the day screen for the one it is. The parameters win when they are there.
  const params = useLocalSearchParams<{ id?: string; name?: string }>();
  const remoteId = params.id ?? resident?.remoteId;
  const who = params.name ?? resident?.displayName;

  const [days, setDays] = useState<HistoryDay[] | null>(null);
  const [problem, setProblem] = useState<'refused' | 'signedOut' | null>(null);
  const [openDate, setOpenDate] = useState<string | null>(null);
  const [revisions, setRevisions] = useState<FiledSummary[] | null>(null);
  // Null until the answer is known, and stays null for anybody the server refuses. The
  // control appears only for somebody it will work for, rather than appearing and then
  // saying no - a caregiver has no use for a button that exists to be refused.
  const [trail, setTrail] = useState<TrailEntry[] | null>(null);
  const [trailOpen, setTrailOpen] = useState(false);

  useEffect(() => {
    if (!remoteId) return;
    let live = true;
    void (async () => {
      try {
        const got = (await fetchHistory(remoteId)).days;
        if (live) setDays(got);
      } catch (error) {
        // Two states, not one. Every refusal says the same thing - a caregiver who can
        // tell "no such resident" from "not yours" learns something about a building
        // they were not given - but a session that has ended is a third case and telling
        // somebody their resident is unavailable when they only need to sign in again is
        // how a working app gets reported as broken. Seen on a device: a password reset
        // revoked the session and this screen said the record was not theirs.
        if (live) setProblem(error instanceof SignedOut ? 'signedOut' : 'refused');
      }
    })();
    return () => {
      live = false;
    };
  }, [remoteId]);

  useEffect(() => {
    if (!remoteId) return;
    let live = true;
    void (async () => {
      try {
        const got = await fetchTrail(remoteId);
        if (live) setTrail(got);
      } catch {
        // Refused, which is the ordinary answer for a caregiver. Nothing to show and
        // nothing to say: the history above is what they came for.
      }
    })();
    return () => {
      live = false;
    };
  }, [remoteId]);

  const open = useCallback(
    async (date: string) => {
      if (!remoteId) return;
      setOpenDate(date);
      setRevisions(null);
      try {
        setRevisions(await fetchDayRevisions(remoteId, date));
      } catch {
        setOpenDate(null);
      }
    },
    [remoteId],
  );

  return (
    <Screen footer={<Button label="Back" variant="secondary" onPress={() => router.back()} />}>
      <Text style={styles.title}>History</Text>
      <Text style={styles.blurb}>
        {who ? `${who}, the last three weeks.` : 'The last three weeks.'}
      </Text>

      {/* A resident the app has locally but the server has never heard of. Nothing to ask
          about, and saying "no history" would be a claim this screen cannot support. */}
      {!remoteId ? (
        <Text style={styles.empty}>This resident is not on the server yet.</Text>
      ) : problem === 'signedOut' ? (
        <Text style={styles.empty}>
          Your session has ended. Sign in again to see this.
        </Text>
      ) : problem === 'refused' ? (
        <Text style={styles.empty}>This record is not available to you.</Text>
      ) : days === null ? (
        <View style={styles.loading}>
          <ActivityIndicator color={color.clay} />
        </View>
      ) : days.length === 0 ? (
        <Text style={styles.empty}>No days have been filed in the last three weeks.</Text>
      ) : (
        days.map((day) => (
          <Pressable
            key={day.on}
            style={styles.row}
            onPress={() => void open(day.on)}
            accessibilityRole="button"
            accessibilityLabel={`${dayLabel(day.on)}. ${oneLine(day.summary)}.${
              day.summary.corrected ? ' Corrected.' : ''
            } Tap to see every version.`}
          >
            <View style={styles.rowText}>
              <Text style={styles.rowDate}>{dayLabel(day.on)}</Text>
              <Text style={styles.rowSummary}>{oneLine(day.summary)}</Text>
            </View>
            {day.summary.corrected ? <Text style={styles.corrected}>Corrected</Text> : null}
          </Pressable>
        ))
      )}

      {trail ? (
        <Pressable
          onPress={() => setTrailOpen(true)}
          accessibilityRole="button"
          accessibilityLabel="Who has opened this record"
          style={({ pressed }) => [styles.trailLink, pressed && { opacity: 0.6 }]}
        >
          <Text style={styles.trailLinkText}>Who has opened this record</Text>
        </Pressable>
      ) : null}

      {trail && trailOpen ? (
        <TrailSheet open onClose={() => setTrailOpen(false)} entries={trail} who={who ?? ''} />
      ) : null}

      {openDate && revisions ? (
        <RevisionsSheet
          open
          onClose={() => {
            setOpenDate(null);
            setRevisions(null);
          }}
          revisions={revisions}
          dateLabel={dayLabel(openDate)}
          careDate={openDate}
        />
      ) : openDate ? (
        <Sheet open onClose={() => setOpenDate(null)}>
          <View style={styles.loading}>
            <ActivityIndicator color={color.clay} />
          </View>
        </Sheet>
      ) : null}
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { ...type.screenTitle, color: color.ink, marginTop: 8 },
  blurb: { ...type.blurb, marginBottom: 20 },
  loading: { paddingVertical: 40, alignItems: 'center' },
  empty: { ...type.body, color: color.ink3, paddingVertical: 24 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    backgroundColor: color.white,
    borderWidth: 1,
    borderColor: color.frame,
    borderRadius: radii.innerCard,
    paddingVertical: 14,
    paddingHorizontal: 16,
    marginBottom: 10,
  },
  rowText: { flex: 1, paddingRight: 12 },
  rowDate: { ...type.checklistItem, color: color.ink },
  rowSummary: { ...type.meta, marginTop: 2 },
  corrected: { ...type.chip, color: color.clay },
  trailLink: { alignSelf: 'flex-start', paddingVertical: 10, marginTop: 6 },
  trailLinkText: { ...type.chip, color: color.clay },
});
