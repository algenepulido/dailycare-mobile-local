import { router } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, Screen, Sheet } from '@/components';
import { RevisionsSheet } from '@/components/RevisionsSheet';
import { fetchDayRevisions, fetchHistory } from '@/data/api';
import type { HistoryDay } from '@/data/api';
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
  const remoteId = resident?.remoteId;

  const [days, setDays] = useState<HistoryDay[] | null>(null);
  const [refused, setRefused] = useState(false);
  const [openDate, setOpenDate] = useState<string | null>(null);
  const [revisions, setRevisions] = useState<FiledSummary[] | null>(null);

  useEffect(() => {
    if (!remoteId) return;
    let live = true;
    void (async () => {
      try {
        const got = await fetchHistory(remoteId);
        if (live) setDays(got);
      } catch {
        // One state for every refusal. A caregiver who can tell "no such resident" from
        // "not yours" learns something about a building they were not given.
        if (live) setRefused(true);
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
        {resident ? `${resident.displayName}, the last three weeks.` : 'The last three weeks.'}
      </Text>

      {/* A resident the app has locally but the server has never heard of. Nothing to ask
          about, and saying "no history" would be a claim this screen cannot support. */}
      {!remoteId ? (
        <Text style={styles.empty}>This resident is not on the server yet.</Text>
      ) : refused ? (
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

      {openDate && revisions ? (
        <RevisionsSheet
          open
          onClose={() => {
            setOpenDate(null);
            setRevisions(null);
          }}
          revisions={revisions}
          dateLabel={dayLabel(openDate)}
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
});
