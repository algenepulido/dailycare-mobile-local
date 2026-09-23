import { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { Image } from 'expo-image';

import { fetchDayPhotos } from '@/data/api';
import type { DayPhoto } from '@/data/api';
import type { FiledSummary } from '@/data/wire';
import { MEAL_AMOUNT_LABEL } from '@/domain/types';
import { color, radii, sizes, type } from '@/theme/tokens';

import { Button } from './Button';
import { Sheet } from './Sheet';

interface AlreadyFiledProps {
  summary: FiledSummary;
  residentName: string;
  /** Asked for only when the sheet opens - see fetchDayPhotos. */
  residentId: string;
  careDate: string;
}

/**
 * That this day is already on the server, and what is in it.
 *
 * Two caregivers on one shift is normal and neither phone knows about the other. Without
 * this the second one fills the form again and sends it, which the server takes as a
 * correction - so a day that was recorded once reads as a day somebody changed their mind
 * about twice. Saying "this is already filed" before the form is the whole point; the
 * detail is behind a tap because most of the time knowing it exists is enough.
 *
 * Deliberately read-only. Loading it into the form would look like the day and not be one:
 * medication is recorded on the device and never sent, and the photograph has a path of
 * its own, so a loaded day would show a blank medication list that the caregiver would
 * reasonably read as "not given".
 */
export function AlreadyFiled({
  summary,
  residentName,
  residentId,
  careDate,
}: AlreadyFiledProps) {
  const [open, setOpen] = useState(false);
  const at = timeOfDay(summary.filedAt);

  /**
   * The photographs, fetched when the sheet opens and not before.
   *
   * `undefined` is "not asked yet", an empty array is "asked, and there are none", and
   * those are different things on screen: one is a spinner and the other is silence.
   */
  const [photos, setPhotos] = useState<DayPhoto[] | undefined>();
  const [photosFailed, setPhotosFailed] = useState(false);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setPhotosFailed(false);
    fetchDayPhotos(residentId, careDate)
      .then((found) => {
        if (!cancelled) setPhotos(found);
      })
      .catch(() => {
        if (!cancelled) {
          setPhotos([]);
          setPhotosFailed(true);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [open, residentId, careDate]);

  return (
    <>
      <Pressable
        onPress={() => setOpen(true)}
        accessibilityRole="button"
        accessibilityLabel={`This day is already filed${at ? `, at ${at}` : ''}. Tap to see it.`}
        style={({ pressed }) => [styles.banner, pressed && styles.pressed]}
      >
        <View style={styles.dot} />
        <Text style={styles.bannerText}>
          {at ? `Already filed at ${at}` : 'Already filed'}
        </Text>
        <Text style={styles.bannerAction}>See it</Text>
      </Pressable>

      <Sheet open={open} onClose={() => setOpen(false)} footer={<Button label="Done" onPress={() => setOpen(false)} />}>
        <ScrollView showsVerticalScrollIndicator={false}>
          <Text style={styles.title}>What was filed</Text>
          <Text style={styles.subtitle}>
            {residentName}
            {at ? ` · ${at}` : ''}
          </Text>

          <Row label="Mood" value={summary.mood} />
          <Row label="Appetite" value={summary.appetite} />
          <Row label="Sleep" value={summary.sleep} />

          <Text style={styles.heading}>MEALS</Text>
          {summary.meals.length === 0 ? (
            <Text style={styles.nothing}>Nothing recorded</Text>
          ) : (
            summary.meals.map((meal) => (
              <Row
                key={meal.slot}
                label={capitalise(meal.slot)}
                value={
                  meal.happened
                    ? meal.amount
                      ? MEAL_AMOUNT_LABEL[meal.amount]
                      : 'Yes'
                    : 'Not done'
                }
              />
            ))
          )}

          <Text style={styles.heading}>HYGIENE</Text>
          <Row label="Shower" value={summary.shower ? 'Done' : 'Not done'} />
          <Row label="Grooming" value={summary.grooming ? 'Done' : 'Not done'} />

          {summary.concerns.length > 0 ? (
            <>
              <Text style={styles.heading}>FLAGGED</Text>
              <Text style={styles.body}>{summary.concerns.join(', ')}</Text>
            </>
          ) : null}

          {summary.note ? (
            <>
              <Text style={styles.heading}>NOTE</Text>
              <Text style={styles.body}>{summary.note}</Text>
            </>
          ) : null}

          <Text style={styles.heading}>PHOTOS</Text>
          {photos === undefined ? (
            <ActivityIndicator style={styles.spinner} />
          ) : photosFailed ? (
            <Text style={styles.nothing}>The photos could not be loaded just now.</Text>
          ) : photos.length === 0 ? (
            <Text style={styles.nothing}>None</Text>
          ) : (
            <View style={styles.photos}>
              {photos.map((photo) => (
                <Image
                  key={photo.id}
                  source={{ uri: photo.url }}
                  style={styles.photo}
                  contentFit="cover"
                  accessibilityLabel="Photo filed with this day"
                />
              ))}
            </View>
          )}

          {/* Medication is the one thing here that genuinely never leaves the phone: a
              tick is a caregiver saying they gave it, and medication_events is a record
              that it was dispensed, and the schema is careful about the difference. */}
          <Text style={styles.footnote}>
            Medication stays on the phone that recorded it and is not sent.
          </Text>
        </ScrollView>
      </Sheet>
    </>
  );
}

function Row({ label, value }: { label: string; value: string | null }) {
  return (
    <View style={styles.row}>
      <Text style={styles.rowLabel}>{label}</Text>
      <Text style={styles.rowValue}>{value ?? '—'}</Text>
    </View>
  );
}

function capitalise(word: string): string {
  return word.charAt(0).toUpperCase() + word.slice(1);
}

/**
 * Local time, because the caregiver reading it is standing in the building. Empty rather
 * than a guess if the timestamp will not parse - a wrong time on a care record is worse
 * than no time.
 */
function timeOfDay(iso: string): string {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return '';
  return at.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
}

const styles = StyleSheet.create({
  banner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    backgroundColor: color.honeySoft,
    borderRadius: radii.card,
    paddingVertical: 12,
    paddingHorizontal: 14,
    marginBottom: sizes.cardGap,
    minHeight: sizes.minTouchTarget,
  },
  pressed: { opacity: 0.7 },
  dot: { width: 8, height: 8, borderRadius: 4, backgroundColor: color.clay },
  bannerText: { ...type.body, color: color.ink, flex: 1 },
  bannerAction: { ...type.body, color: color.clay, fontWeight: '600' },

  title: { ...type.sheetTitle, color: color.ink },
  subtitle: { ...type.body, color: color.ink3, marginTop: 2, marginBottom: 18 },
  heading: { ...type.sectionHeading, color: color.ink3, marginTop: 20, marginBottom: 6 },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'baseline',
    paddingVertical: 7,
    borderBottomWidth: 1,
    borderBottomColor: color.line,
    gap: 16,
  },
  rowLabel: { ...type.body, color: color.ink2 },
  rowValue: { ...type.body, color: color.ink, flexShrink: 1, textAlign: 'right' },
  body: { ...type.body, color: color.ink },
  nothing: { ...type.body, color: color.ink3 },
  footnote: { ...type.body, color: color.ink3, marginTop: 20 },
  spinner: { alignSelf: 'flex-start', marginTop: 4 },
  photos: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 4 },
  photo: { width: 104, height: 104, borderRadius: radii.photoThumb, backgroundColor: color.paper2 },
});
