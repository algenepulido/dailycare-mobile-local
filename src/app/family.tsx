import { Image } from 'expo-image';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, RefreshControl, StyleSheet, Text, View } from 'react-native';

import { Button, DayReport, Icon, Screen, SignInSheet } from '@/components';
import { SignedOut, fetchDay, fetchDayPhotos, listResidents } from '@/data/api';
import type { DayPhoto, RemoteResident } from '@/data/api';
import { baselineFromWire } from '@/data/wire';
import type { FiledSummary } from '@/data/wire';
import { longLabel, today } from '@/domain/dates';
import { buildChanges, buildFamilyChecklist } from '@/domain/rules';
import type { Change, ChecklistGroup } from '@/domain/rules';
import { useSession } from '@/state/session';
import { color, radii, type } from '@/theme/tokens';

/**
 * The app as a family member holds it.
 *
 * One person's day, and nothing to fill in. There is no form here and no send, which is not
 * a button hidden from them: the database refuses a day filed by a family member, and this
 * screen is the shape of that refusal rather than a polite way of avoiding it. A resident
 * switcher appears only when they hold more than one grant - two parents in the same
 * building is the ordinary case the model was built for, and a list of one is a list nobody
 * needs.
 *
 * Today, and only today. A day nobody has filed says so plainly rather than reading as an
 * error, because "nothing recorded yet" is a true and ordinary thing for a morning. The
 * weeks behind it belong to milestone six and are deliberately not here.
 */
export default function FamilyScreen() {
  const { account, signOut } = useSession();

  const [people, setPeople] = useState<RemoteResident[] | null>(null);
  const [chosen, setChosen] = useState<string | null>(null);
  const [problem, setProblem] = useState<'refused' | 'signedOut' | null>(null);

  const [day, setDay] = useState<FiledSummary | null | undefined>();
  const [photos, setPhotos] = useState<DayPhoto[] | undefined>();
  const [refreshing, setRefreshing] = useState(false);
  const [signInOpen, setSignInOpen] = useState(false);

  const date = today();
  const signedIn = Boolean(account);

  /** Who this account may read. The server decides; this shows what came back. */
  const loadPeople = useCallback(async () => {
    try {
      const got = await listResidents();
      setPeople(got);
      setProblem(null);
      // Keep the chosen resident across a refresh unless the grant for them has gone.
      setChosen((was) => (was && got.some((p) => p.id === was) ? was : (got[0]?.id ?? null)));
    } catch (error) {
      setProblem(error instanceof SignedOut ? 'signedOut' : 'refused');
    }
  }, []);

  useEffect(() => {
    if (signedIn) void loadPeople();
  }, [signedIn, loadPeople]);

  /**
   * Nothing of one person's record survives the next person signing in.
   *
   * Signing out leaves this screen mounted - the device is still a family phone, so there is
   * nowhere else for it to go - and everything it is holding is somebody's care record. A
   * phone handed to a second family member would have shown them the first one's resident
   * for as long as the new request took.
   */
  useEffect(() => {
    if (!signedIn) {
      setPeople(null);
      setChosen(null);
      setDay(undefined);
      setPhotos(undefined);
      setProblem(null);
    }
  }, [signedIn]);

  /**
   * The day, and its photographs, for whoever is chosen.
   *
   * The photographs are a second call because each link costs the server a signing call and
   * cannot be withdrawn once it exists - the same reason the caregiver's app asks for them
   * separately. Here they are always wanted, because the whole point of this screen is to
   * show them.
   */
  const loadDay = useCallback(async () => {
    if (!chosen) return;
    setDay(undefined);
    setPhotos(undefined);
    try {
      const filed = await fetchDay(chosen, date);
      setDay(filed);
      // Only if there is a day. Asking for the photographs of a day nobody filed mints
      // nothing and still costs a round trip on a family phone's connection.
      setPhotos(filed ? await fetchDayPhotos(chosen, date).catch(() => []) : []);
    } catch (error) {
      if (error instanceof SignedOut) setProblem('signedOut');
      // A day that will not load is left as "not asked yet" rather than as "nothing
      // recorded": telling somebody their mother's day is empty when the truth is that the
      // request failed is the one wrong answer this screen can give.
      else setDay(undefined);
    }
  }, [chosen, date]);

  useEffect(() => {
    void loadDay();
  }, [loadDay]);

  async function pullToRefresh() {
    setRefreshing(true);
    await loadPeople();
    await loadDay();
    setRefreshing(false);
  }

  // Signed out deliberately, or a session that ended on its own. The same screen for both,
  // because the way back is the same and a family member has no half-written day underneath
  // that the distinction would matter to.
  if (!signedIn || problem === 'signedOut') {
    return (
      <Screen footer={<Button label="Sign in" onPress={() => setSignInOpen(true)} />}>
        <Text style={styles.title}>DailyCare</Text>
        <Text style={styles.blurb}>
          {problem === 'signedOut'
            ? 'This session has ended. Sign in again to see today.'
            : 'Sign in to see how your person is doing today.'}
        </Text>
        <SignInSheet open={signInOpen} opened="family" onClose={() => setSignInOpen(false)} />
      </Screen>
    );
  }

  // An account linked to nobody. A grant that was withdrawn, or one that has not been given
  // yet - and the two read the same from here on purpose, because which of them it is is the
  // facility's to say and not this screen's to guess.
  if (people !== null && people.length === 0) {
    return (
      <Screen footer={<Button label="Sign out" variant="secondary" onPress={() => void signOut()} />}>
        <Text style={styles.title}>DailyCare</Text>
        <Text style={styles.blurb}>
          Nobody is linked to this account yet. When the care home gives you access to a
          resident, their day appears here.
        </Text>
      </Screen>
    );
  }

  const person = people?.find((p) => p.id === chosen) ?? null;

  return (
    <Screen
      footer={<Button label="Sign out" variant="secondary" onPress={() => void signOut()} />}
      refreshControl={
        <RefreshControl refreshing={refreshing} onRefresh={pullToRefresh} tintColor={color.clay} />
      }
    >
      {/* One view, so the screen's own gap between children does not open up between the
          sections of the day - DayReport spaces those itself and the review sheet shows
          them at that spacing. */}
      <View>
        <Text style={styles.title}>{person ? person.displayName : 'Today'}</Text>
        <Text style={styles.blurb}>{longLabel(date)}</Text>

        {/* Only with more than one. A switcher over a list of one is a control that cannot
            do anything, and two parents in the same building is the case it exists for. */}
        {people && people.length > 1 ? (
          <View style={styles.switcher}>
            {people.map((p) => {
              const here = p.id === chosen;
              return (
                <Pressable
                  key={p.id}
                  onPress={() => setChosen(p.id)}
                  accessibilityRole="button"
                  accessibilityState={{ selected: here }}
                  accessibilityLabel={`Show ${p.displayName}'s day`}
                  style={[styles.tab, here && styles.tabOn]}
                >
                  <Text style={[styles.tabText, here && styles.tabTextOn]}>{p.displayName}</Text>
                </Pressable>
              );
            })}
          </View>
        ) : null}

        {problem === 'refused' ? (
          <Text style={styles.empty}>Today is not available just now. Pull down to try again.</Text>
        ) : day === undefined ? (
          <View style={styles.loading}>
            <ActivityIndicator color={color.clay} />
          </View>
        ) : day === null ? (
          <Nothing name={person?.displayName ?? 'they'} />
        ) : (
          <Filed
            day={day}
            photos={photos}
            changes={changesOf(day, person)}
            checklist={buildFamilyChecklist(day)}
          />
        )}
      </View>
    </Screen>
  );
}

/**
 * What changed, against the baseline the building holds for this resident.
 *
 * Not against a baseline typed on this phone: a family member never set one up, and the
 * comparison has to be the same one the caregiver's screen made or the two would disagree
 * about whether the day was ordinary.
 *
 * Empty when any of the three observations came back as a word this app cannot name, which
 * fromWire turns into null. Reporting "Mood: " with nothing after it would be worse than
 * reporting nothing, and the checklist and the note are still there to read.
 */
function changesOf(day: FiledSummary, person: RemoteResident | null): Change[] {
  if (!person || !day.mood || !day.appetite || !day.sleep) return [];
  return buildChanges(
    { mood: day.mood, appetite: day.appetite, sleep: day.sleep, concerns: day.concerns },
    baselineFromWire(person.baseline),
  );
}

function Nothing({ name }: { name: string }) {
  return (
    <View style={styles.nothing}>
      <Icon name="check" size={20} color={color.ink3} />
      <Text style={styles.nothingText}>
        Nothing has been recorded for {name} today yet. It appears here as soon as a
        caregiver files it.
      </Text>
    </View>
  );
}

function Filed({
  day,
  photos,
  changes,
  checklist,
}: {
  day: FiledSummary;
  photos: DayPhoto[] | undefined;
  changes: Change[];
  checklist: ChecklistGroup[];
}) {
  return (
    <>
      {/* That it was corrected, not what it used to say. A family is told the record
          changed; the versions behind it are a care manager's to read. */}
      {day.corrected ? (
        <View style={styles.corrected}>
          <Icon name="flag" size={15} color={color.warn} />
          <Text style={styles.correctedText}>This day was corrected after it was first filed.</Text>
        </View>
      ) : null}

      <DayReport changes={changes} checklist={checklist} note={day.note}>
        <Text style={styles.photoLabel}>Photo</Text>
        {photos === undefined ? (
          <ActivityIndicator style={styles.spinner} color={color.clay} />
        ) : photos.length === 0 ? (
          <View style={styles.noPhoto}>
            <Icon name="camera" size={15} color={color.ink3} />
            <Text style={styles.noPhotoText}>No photo today</Text>
          </View>
        ) : (
          <View style={styles.photos}>
            {photos.map((photo) => (
              <Image
                key={photo.id}
                source={{ uri: photo.url }}
                style={styles.photo}
                contentFit="cover"
                accessibilityLabel="Photo filed with today"
              />
            ))}
          </View>
        )}
      </DayReport>

      {/* Said rather than left to be noticed. A checklist with no medication group reads
          to a family like a gap in the care, and it is a gap in what this app records. */}
      <Text style={styles.footnote}>
        Medication is not part of this record. The care home keeps it in their own system.
      </Text>
      <Text style={styles.footnote}>Filed {timeOfDay(day.filedAt)}.</Text>
    </>
  );
}

/** Local time, because the person reading it is in their own day. Empty if it will not
 *  parse - a wrong time on a care record is worse than no time. */
function timeOfDay(iso: string): string {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return 'earlier today';
  return `at ${at.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })}`;
}

const styles = StyleSheet.create({
  title: { ...type.screenTitle, color: color.ink, marginTop: 8 },
  blurb: { ...type.blurb, marginBottom: 8 },
  empty: { ...type.body, color: color.ink3, paddingVertical: 24 },
  loading: { paddingVertical: 48, alignItems: 'center' },

  switcher: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 10, marginBottom: 4 },
  tab: {
    paddingVertical: 9,
    paddingHorizontal: 16,
    borderRadius: radii.chip,
    borderWidth: 1.5,
    borderColor: color.frame,
    backgroundColor: color.white,
  },
  tabOn: { borderColor: color.clay, backgroundColor: color.claySoft },
  tabText: { ...type.chip, color: color.ink2 },
  tabTextOn: { color: color.ink },

  nothing: {
    flexDirection: 'row',
    gap: 10,
    alignItems: 'flex-start',
    marginTop: 20,
    padding: 16,
    borderRadius: radii.innerCard,
    backgroundColor: color.paper2,
  },
  nothingText: { ...type.body, color: color.ink2, flex: 1 },

  corrected: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginTop: 14,
    paddingVertical: 10,
    paddingHorizontal: 14,
    borderRadius: radii.innerCard,
    backgroundColor: color.honeySoft,
  },
  correctedText: { ...type.chip, color: color.ink, flex: 1 },

  photoLabel: { ...type.sectionLabel, marginTop: 22, marginBottom: 10, marginHorizontal: 2 },
  spinner: { alignSelf: 'flex-start' },
  photos: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  photo: { width: 148, height: 148, borderRadius: radii.photoThumb, backgroundColor: color.paper2 },
  noPhoto: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  noPhotoText: { ...type.chip, color: color.ink3 },

  footnote: { ...type.meta, color: color.ink4, marginTop: 14 },
});
