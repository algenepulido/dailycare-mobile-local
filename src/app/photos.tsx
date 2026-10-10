import { Image } from 'expo-image';
import { router, useLocalSearchParams } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useMemo, useState } from 'react';
import {
  ActivityIndicator,
  Dimensions,
  Modal,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';

import { Button, Screen } from '@/components';
import { SignedOut, fetchPhotoRange } from '@/data/api';
import type { DatedPhoto } from '@/data/api';
import { daysEnding, longLabel, today } from '@/domain/dates';
import { color, radii, type } from '@/theme/tokens';

/**
 * Three weeks of photographs, as a family looks back through them.
 *
 * A route rather than a sheet, for the reason the layout already gives about the history
 * screen: this is somewhere you go and come back from, and three weeks of pictures in a
 * sheet is a screen wearing a sheet's clothes.
 *
 * Grouped by the day they were filed against, newest day first, because a photograph
 * without its day is a picture and a photograph with it is a record. The day heading is the
 * same label the rest of the app uses, and tapping it opens that day.
 *
 * One request for the whole span. Asking day by day would be twenty-one requests, each of
 * which costs the server a signing call - and the links expire, so a gallery left open comes
 * back rather than being cached.
 */

/** The span the family screen shows, and the span this asks for. */
const WEEKS_BACK = 21;

/**
 * Back to the day the photograph belongs to.
 *
 * dismissTo rather than push: the family screen is already underneath this one, and pushing
 * a second copy of it would leave a family pressing back twice to get out of a gallery they
 * entered once. navigate is the fallback for a gallery that was somehow opened cold.
 */
function openTheDay(on: string) {
  const to = { pathname: '/family' as const, params: { date: on } };
  if (router.canDismiss()) router.dismissTo(to);
  else router.navigate(to);
}

export default function PhotosScreen() {
  const params = useLocalSearchParams<{ id?: string; name?: string }>();
  const residentId = params.id;
  const who = params.name;

  const [photos, setPhotos] = useState<DatedPhoto[] | null>(null);
  const [problem, setProblem] = useState<'refused' | 'signedOut' | null>(null);
  const [open, setOpen] = useState<DatedPhoto | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  // Bumped to ask again. The links expire, so coming back is the answer rather than caching.
  const [again, setAgain] = useState(0);

  const span = useMemo(() => {
    const days = daysEnding(today(), WEEKS_BACK);
    return { from: days[days.length - 1], to: days[0] };
  }, []);

  useEffect(() => {
    if (!residentId) return;
    let live = true;
    void (async () => {
      try {
        const got = await fetchPhotoRange(residentId, span.from, span.to);
        if (!live) return;
        setProblem(null);
        setPhotos(got);
      } catch (error) {
        if (!live) return;
        setProblem(error instanceof SignedOut ? 'signedOut' : 'refused');
        setPhotos([]);
      } finally {
        if (live) setRefreshing(false);
      }
    })();
    return () => {
      live = false;
    };
  }, [residentId, span.from, span.to, again]);

  /**
   * The photographs gathered under the day they belong to, newest day first.
   *
   * The server returns them oldest first so a gallery that wanted that order would not have
   * to think; this screen wants the other one, because the thing a family opens the gallery
   * for is the most recent picture of their mother.
   */
  const byDay = useMemo(() => {
    const groups = new Map<string, DatedPhoto[]>();
    for (const photo of photos ?? []) {
      const existing = groups.get(photo.on);
      if (existing) existing.push(photo);
      else groups.set(photo.on, [photo]);
    }
    return [...groups.entries()].sort((a, b) => (a[0] < b[0] ? 1 : -1));
  }, [photos]);

  const count = photos?.length ?? 0;

  return (
    <Screen
      footer={<Button label="Back" variant="secondary" onPress={() => router.back()} />}
      refreshControl={
        <RefreshControl
          refreshing={refreshing}
          tintColor={color.clay}
          onRefresh={() => {
            setRefreshing(true);
            setAgain((n) => n + 1);
          }}
        />
      }
    >
      <Text style={styles.title}>{who ? `Photos of ${who}` : 'Photos'}</Text>

      {photos === null ? (
        <ActivityIndicator style={styles.spinner} color={color.clay} />
      ) : problem === 'signedOut' ? (
        <Text style={styles.blurb}>This session has ended. Sign in again to see the photos.</Text>
      ) : problem === 'refused' ? (
        /* A request that did not get an answer, said as that.
         *
         * This screen first showed "no photos have been sent" here, which is a statement
         * about the care home rather than about the request - and the wrong one. Caught by
         * opening the gallery against a server that did not have the route yet: a family
         * would have read that the home had sent nothing for three weeks and rung them
         * about it. Nothing and could-not-ask are different answers and only one of them
         * is about the home. */
        <Text style={styles.blurb}>
          The photos could not be loaded just now. Pull down to try again.
        </Text>
      ) : count === 0 ? (
        /* Nothing is not an error. A home that has not sent a photograph in three weeks has
         * done nothing wrong, and a family told "could not load" would ring them about it. */
        <Text style={styles.blurb}>
          No photos have been sent in the last three weeks. They appear here as soon as a
          caregiver adds one to a day.
        </Text>
      ) : (
        <>
          <Text style={styles.blurb}>
            {count === 1
              ? 'One photo from the last three weeks.'
              : `${count} photos from the last three weeks, newest first.`}
          </Text>
          {byDay.map(([on, ofThatDay]) => (
            <View key={on}>
              <Pressable
                onPress={() => openTheDay(on)}
                accessibilityRole="button"
                accessibilityLabel={`${longLabel(on)}, read this day`}
              >
                <Text style={styles.day}>{longLabel(on)}</Text>
              </Pressable>
              <View style={styles.grid}>
                {ofThatDay.map((photo) => (
                  <Pressable
                    key={photo.id}
                    onPress={() => setOpen(photo)}
                    accessibilityRole="imagebutton"
                    accessibilityLabel={`A photo from ${longLabel(photo.on)}, open it larger`}
                    style={({ pressed }) => [styles.cell, pressed && styles.pressed]}
                  >
                    <Image
                      source={{ uri: photo.url }}
                      style={styles.thumb}
                      contentFit="cover"
                      transition={120}
                    />
                  </Pressable>
                ))}
              </View>
            </View>
          ))}
        </>
      )}

      {/* One photograph, as large as the phone allows.
        *
        * A modal rather than a route: it is a closer look at something already on the screen,
        * and the way out of it is putting it down. Pressing anywhere closes it, because a
        * family member holding a phone one-handed should not have to find a small cross. */}
      <Modal visible={open !== null} transparent animationType="fade" onRequestClose={() => setOpen(null)}>
        <Pressable
          style={styles.scrim}
          onPress={() => setOpen(null)}
          accessibilityRole="button"
          accessibilityLabel="Close the photo"
        >
          {open ? (
            <>
              {/* The app is dark text on paper everywhere else, so the clock and the
                * battery are dark too - and against this scrim they are nearly invisible.
                * Light for as long as the photograph is up, and back on its own when it
                * comes down. */}
              <StatusBar style="light" />
              <Image
                source={{ uri: open.url }}
                style={styles.large}
                contentFit="contain"
                accessibilityLabel={`A photo from ${longLabel(open.on)}`}
              />
              <Text style={styles.largeWhen}>{longLabel(open.on)}</Text>
            </>
          ) : null}
        </Pressable>
      </Modal>
    </Screen>
  );
}

// Three across on a phone, computed rather than guessed: a fixed cell width leaves a ragged
// margin on a narrow screen and clips on a wide one.
const GUTTER = 6;
const CELL = Math.floor((Dimensions.get('window').width - 40 - GUTTER * 2) / 3);

const styles = StyleSheet.create({
  title: { ...type.screenTitle, marginBottom: 6 },
  blurb: { ...type.blurb, marginBottom: 10 },
  spinner: { alignSelf: 'flex-start', marginTop: 20 },

  day: { ...type.sectionLabel, color: color.ink3, marginTop: 20, marginBottom: 6 },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: GUTTER },
  cell: { borderRadius: radii.photoThumb, overflow: 'hidden' },
  pressed: { opacity: 0.7 },
  thumb: { width: CELL, height: CELL, backgroundColor: color.paper2 },

  scrim: {
    flex: 1,
    backgroundColor: 'rgba(26,20,16,0.92)',
    alignItems: 'center',
    justifyContent: 'center',
    padding: 16,
    gap: 14,
  },
  large: { width: '100%', height: '80%' },
  largeWhen: { ...type.meta, color: color.paper2 },
});
