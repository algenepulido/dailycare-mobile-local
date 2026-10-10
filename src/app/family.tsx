import { Image } from 'expo-image';
import { router, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, RefreshControl, StyleSheet, Text, View } from 'react-native';

import { Button, Face, Icon, Screen, SignInSheet } from '@/components';
import {
  SignedOut,
  acceptGrant,
  fetchDay,
  fetchDayPhotos,
  fetchHistory,
  fetchResidentPhoto,
  listResidents,
  waitingGrants,
} from '@/data/api';
import type { DayPhoto, History, RemoteResident, WaitingGrant } from '@/data/api';
import { baselineFromWire } from '@/data/wire';
import type { FiledSummary } from '@/data/wire';
import { dayNumberLabel, longLabel, today, weekdayLabel } from '@/domain/dates';
import { STEADY_DAY, familyDay } from '@/domain/familyDay';
import type { CareGroup, FamilyDay, FiledDayFacts } from '@/domain/familyDay';
import { familyWeek } from '@/domain/familyWeek';
import type { WeekDay } from '@/domain/familyWeek';
import { DEFAULT_BASELINE } from '@/domain/types';
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
  const [face, setFace] = useState<DayPhoto | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [signInOpen, setSignInOpen] = useState(false);
  // What this account has been offered and not taken up. Asked for alongside the residents
  // rather than only when that list is empty: somebody can hold a reading grant for one
  // parent and a waiting one for the other, and a screen that only looks when it has nothing
  // would never show the second.
  const [waiting, setWaiting] = useState<WaitingGrant[]>([]);
  const [accepting, setAccepting] = useState<string | null>(null);

  // The day being read, which starts at today and is the only thing scrolling back
  // changes. Everything below already keys off it, so moving between days is one piece of
  // state rather than a second screen.
  const [date, setDate] = useState(today());
  // The days, and the window they were asked over. The window is kept because a week
  // drawn at the edge of it must not report days nobody asked about as days the home
  // wrote nothing on.
  const [earlier, setEarlier] = useState<History | null>(null);
  const signedIn = Boolean(account);

  /**
   * A day asked for from somewhere else - the gallery, when somebody taps the date over a
   * photograph and wants to read what happened that day.
   *
   * Followed rather than used as an initial value: the gallery comes back to this screen
   * rather than opening a second copy of it, so the parameter arrives when the screen is
   * already mounted and useState would never see it.
   */
  const asked = useLocalSearchParams<{ date?: string }>().date;
  useEffect(() => {
    if (asked) setDate(asked);
  }, [asked]);

  /** Who this account may read. The server decides; this shows what came back. */
  const loadPeople = useCallback(async () => {
    try {
      const got = await listResidents();
      setPeople(got);
      setProblem(null);
      // Keep the chosen resident across a refresh unless the grant for them has gone.
      setChosen((was) => (was && got.some((p) => p.id === was) ? was : (got[0]?.id ?? null)));
      // Anything offered and not taken up. Failing quietly: an older server has no such
      // route, and a family member who can read her mother's day should not be shown an
      // error because of a list that would have been empty anyway.
      setWaiting(await waitingGrants().catch(() => []));
    } catch (error) {
      setProblem(error instanceof SignedOut ? 'signedOut' : 'refused');
    }
  }, []);

  const accept = useCallback(
    async (grant: WaitingGrant) => {
      setAccepting(grant.id);
      try {
        await acceptGrant(grant.id);
        await loadPeople();
      } catch {
        setProblem('refused');
      } finally {
        setAccepting(null);
      }
    },
    [loadPeople],
  );

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
      // Her face, which does not change with the date and is not refetched with it.
      void fetchResidentPhoto(chosen).then(setFace).catch(() => setFace(null));
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

  /**
   * The days behind this one.
   *
   * Keyed on the resident rather than the date: scrolling back through them must not
   * refetch the list it is being scrolled through. The server's window is three weeks and
   * it returns only the days somebody filed, so a gap in the list is a day nobody wrote
   * rather than a day this screen failed to ask for.
   */
  useEffect(() => {
    if (!chosen) return;
    let live = true;
    void fetchHistory(chosen)
      .then((rows) => {
        if (live) setEarlier(rows);
      })
      .catch(() => {
        if (live) setEarlier(null);
      });
    return () => {
      live = false;
    };
  }, [chosen]);

  // Every day the server returned except the one being read, so the list never offers a
  // way to the day already on screen.
  const behind = (earlier?.days ?? []).filter((entry) => entry.on !== date);


  async function pullToRefresh() {
    setRefreshing(true);
    // Not back to today. Somebody three weeks down the list who pulls to refresh is
    // asking for that day again, not to be returned to this one - and losing their place
    // to a gesture they made by accident is worse than not refreshing at all. The way
    // back is the link at the top, which is on the screen where they can see it.
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
  /**
   * Something has been offered and not taken up.
   *
   * Shown before the empty state, because "nobody is linked to this account" is false when
   * a care home is waiting on an answer - and it is the sentence somebody whose access was
   * restored would otherwise read. It names the building rather than the resident: an
   * invited grant discloses nothing until it is accepted, which is the whole reason it waits.
   */
  const pending =
    waiting.length > 0 ? (
      <>
        {waiting.map((grant) => (
          <View key={grant.id} style={styles.offer}>
            <Text style={styles.offerTitle}>
              {grant.again
                ? `${grant.facility} has shared somebody with you again`
                : `${grant.facility} has shared somebody with you`}
            </Text>
            <Text style={styles.offerBlurb}>
              {grant.again
                ? 'Your access was taken back and the care home has offered it again. Accepting is yours to do.'
                : `They have you down as their ${grant.relation}. Nothing is shown until you accept.`}
            </Text>
            <Button
              label={accepting === grant.id ? 'Accepting…' : 'Accept'}
              disabled={accepting !== null}
              onPress={() => void accept(grant)}
            />
          </View>
        ))}
      </>
    ) : null;

  if (people !== null && people.length === 0) {
    return (
      <Screen footer={<Button label="Sign out" variant="secondary" onPress={() => void signOut()} />}>
        <Text style={styles.title}>DailyCare</Text>
        {pending ?? (
          <Text style={styles.blurb}>
            Nobody is linked to this account yet. When the care home gives you access to a
            resident, their day appears here.
          </Text>
        )}
      </Screen>
    );
  }

  const person = people?.find((p) => p.id === chosen) ?? null;

  /**
   * The week the day on screen sits in.
   *
   * No second request: it is the three weeks already fetched, narrowed. And it follows the
   * day being read rather than always meaning the last seven days, so somebody three weeks
   * back is not shown a week that disagrees with the day in front of them.
   */
  const week = familyWeek({
    filed: (earlier?.days ?? []).map((entry) => ({ on: entry.on, day: factsOf(entry.summary) })),
    baseline: person ? baselineFromWire(person.baseline) : DEFAULT_BASELINE,
    residentName: person?.displayName ?? 'They',
    upTo: date,
    todayIs: today(),
    knownFrom: earlier?.from ?? '',
  });

  return (
    <Screen
      footer={<Button label="Sign out" variant="secondary" onPress={() => void signOut()} />}
      refreshControl={
        <RefreshControl refreshing={refreshing} onRefresh={pullToRefresh} tintColor={color.clay} />
      }
      topWhen={date}
    >
      {/* One view, so the screen's own gap between children does not open up between the
          lines of the summary. It is meant to read as paragraphs rather than as a stack of
          separate things. */}
      <View>
        {/* Her face above her name. This is the screen a daughter opens in the evening,
            and it should look like it is about her mother rather than about a record of
            her mother. Without a photograph it is the first letter of her name, which is
            what it has always been. */}
        <View style={styles.whoRow}>
          <Face name={person ? person.displayName : 'Today'} url={face?.url} size={52} />
          <View style={styles.whoText}>
            <Text style={styles.title}>{person ? person.displayName : 'Today'}</Text>
            <Text style={styles.blurb}>{longLabel(date)}</Text>
          </View>
        </View>

        {/* Only when there is somewhere to come back from. Pull-to-refresh does the same
          * thing and nobody would find it: a reader three weeks down a list needs the way
          * out on the screen, not in a gesture. */}
        {date !== today() ? (
          <Pressable
            onPress={() => setDate(today())}
            accessibilityRole="button"
            accessibilityLabel="Back to today"
            style={({ pressed }) => [styles.backToday, pressed && styles.earlierPressed]}
          >
            <Text style={styles.backTodayText}>Back to today</Text>
          </Pressable>
        ) : null}

        {/* Above the day rather than below it. Somebody reading about one parent and offered
            access to the other should see the offer, and a card under a scrolling summary is
            a card nobody reaches. */}
        {pending}

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
          <Filed day={day} photos={photos} summary={summaryOf(day, person)} />
        )}

        {/* How the week went, above the days that make it up.
          *
          * The card's own test is a family member seeing that their mother ate every day, and
          * that is a sentence about a run of days rather than about any one of them. The strip
          * is the week at a glance and the lines under it are the answer in words; both are
          * built from what was recorded and neither invents a day nobody filed.
          *
          * Hidden entirely when nothing in the week was filed, rather than drawn empty. A
          * blank week reads as a home that recorded nothing, and the screen does not know
          * that - the resident may have been admitted on Friday. */}
        {week.lines.length > 0 ? (
          <>
            <Text style={styles.heading}>
              {date === today() ? 'This week' : `The week to ${longLabel(date)}`}
            </Text>
            <View style={styles.strip}>
              {/* Oldest first, left to right. The list below runs the other way, because a
                * list is read from the top and a week is read across. */}
              {[...week.days].reverse().map((entry) => (
                <WeekColumn key={entry.on} day={entry} onPress={() => setDate(entry.on)} />
              ))}
            </View>
            {week.lines.map((line) => (
              <Text key={line} style={styles.weekLine}>
                {line}
              </Text>
            ))}
          </>
        ) : null}

        {/* All of the photographs, in one place.
          *
          * A link rather than a section, because a gallery of three weeks on the end of this
          * screen is a screen of its own - and because it costs the server a signed link per
          * photograph, which is not a bill to run for somebody who came to read today.
          *
          * Only for a resident this account actually holds, since the gallery is asked for by
          * id and there is nothing to show without one. */}
        {person ? (
          <Pressable
            onPress={() =>
              router.push({
                pathname: '/photos',
                params: { id: person.id, name: person.displayName },
              })
            }
            accessibilityRole="button"
            accessibilityLabel={`See all photos of ${person.displayName}`}
            style={({ pressed }) => [styles.toPhotos, pressed && styles.earlierPressed]}
          >
            <Icon name="camera" size={18} color={color.clay} />
            <Text style={styles.toPhotosText}>See all photos</Text>
          </Pressable>
        ) : null}

        {/* The days behind this one.
          *
          * The point of an app over an email: an evening's update is one day, and this is
          * the week it sits in. A row says how the day went in the same words the day
          * itself would, with the meals under it, because "she ate every day" is a thing
          * somebody sees by scrolling rather than by reading.
          *
          * Only the days somebody filed. Blank rows for the rest would turn a quiet
          * weekend into a wall of nothing recorded. */}
        {behind.length > 0 ? (
          <>
            <Text style={styles.heading}>Earlier days</Text>
            {behind.map((entry) => (
              <Pressable
                key={entry.on}
                onPress={() => setDate(entry.on)}
                accessibilityRole="button"
                accessibilityLabel={`${longLabel(entry.on)}, read this day`}
                style={({ pressed }) => [styles.earlier, pressed && styles.earlierPressed]}
              >
                <Text style={styles.earlierWhen}>{longLabel(entry.on)}</Text>
                <Text style={styles.earlierHow} numberOfLines={2}>
                  {howItWent(entry.summary, person)}
                </Text>
                <Text style={styles.earlierMeals}>{mealsOn(entry.summary)}</Text>
              </Pressable>
            ))}
          </>
        ) : null}
      </View>
    </Screen>
  );
}

/**
 * The day in the words a family reads it in, against the baseline the building holds.
 *
 * Not against a baseline typed on this phone: a family member never set one up, and the
 * comparison has to be the one the caregiver's screen made or the two would disagree about
 * whether the day was ordinary.
 *
 * All of the wording lives in domain/familyDay, deliberately. It is the part that is about
 * what a family is told rather than about how it looks, so it is testable without a screen
 * and survives the design pass untouched.
 */
/** How a day went, in one line, in the same voice the day itself uses. */
function howItWent(day: FiledSummary, person: RemoteResident | null): string {
  const read = summaryOf(day, person);
  return read.changed.length === 0 ? STEADY_DAY : read.changed[0];
}

/**
 * The meals, counted.
 *
 * On every row rather than only when something is wrong, because the question a daughter
 * is actually asking is whether her mother is eating, and the answer to that is a run of
 * ordinary days rather than one alarming one.
 */
function mealsOn(day: FiledSummary): string {
  const had = day.meals.filter((m) => m.happened).length;
  return `${had} of ${day.meals.length} meals`;
}

/**
 * The filed row narrowed to what a family is told.
 *
 * One place rather than two: the day and the week read the same facts, and a field added to
 * one and forgotten in the other would have them describing different days.
 */
function factsOf(day: FiledSummary): FiledDayFacts {
  return {
    mood: day.mood,
    appetite: day.appetite,
    sleep: day.sleep,
    note: day.note,
    shower: day.shower,
    grooming: day.grooming,
    meals: day.meals,
    concerns: day.concerns,
    medication: day.medication,
  };
}

function summaryOf(day: FiledSummary, person: RemoteResident | null): FamilyDay {
  return familyDay(
    factsOf(day),
    person ? baselineFromWire(person.baseline) : DEFAULT_BASELINE,
    person?.displayName ?? 'They',
    day.filedByName,
  );
}

/**
 * One day in the week strip.
 *
 * Text rather than a dot, deliberately. A family member is the reader most likely to have
 * large text turned on, and a dot is a fixed size with nothing inside it to grow - so the
 * day is a weekday, a date and the meals counted, all of which scale with the setting, and
 * the row they sit in wraps rather than squeezing them.
 *
 * A day nobody filed is drawn flat and does nothing when pressed. It is not a bad day and
 * must not look like one, and there is nothing behind it to open.
 */
function WeekColumn({ day, onPress }: { day: WeekDay; onPress: () => void }) {
  // Today is not short of anything, it is unfinished. Colouring it would put a mark on
  // every evening of the week in turn.
  const short = day.recorded && !day.inProgress && day.of > 0 && day.meals < day.of;
  return (
    <Pressable
      onPress={onPress}
      disabled={!day.recorded}
      accessibilityRole={day.recorded ? 'button' : undefined}
      accessibilityLabel={weekColumnLabel(day)}
      style={({ pressed }) => [
        styles.column,
        !day.recorded && styles.columnBlank,
        !day.steady && styles.columnNoted,
        day.inProgress && styles.columnToday,
        pressed && styles.earlierPressed,
      ]}
    >
      <Text style={styles.columnDay} numberOfLines={1}>
        {weekdayLabel(day.on)}
      </Text>
      <Text style={styles.columnDate} numberOfLines={1}>
        {dayNumberLabel(day.on)}
      </Text>
      <Text
        style={[styles.columnMeals, short && styles.columnMealsShort]}
        numberOfLines={1}
      >
        {day.recorded && day.of > 0 ? `${day.meals}/${day.of}` : '\u2013'}
      </Text>
    </Pressable>
  );
}

/** What the strip says out loud. Said in full, because a column read aloud is three numbers. */
function weekColumnLabel(day: WeekDay): string {
  const when = day.inProgress ? 'Today' : longLabel(day.on);
  if (!day.recorded) return `${when}, nothing written down`;
  // "so far" on today for the same reason the week's own sentences say it: the meals that
  // are not ticked are the ones the day has not reached.
  const meals =
    day.of > 0
      ? `${day.meals} of ${day.of} meals${day.inProgress ? ' so far' : ''}`
      : 'no meals written down';
  const noted = day.steady ? '' : ', something was different';
  return `${when}, ${meals}${noted}, read this day`;
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
  summary,
}: {
  day: FiledSummary;
  photos: DayPhoto[] | undefined;
  summary: FamilyDay;
}) {
  return (
    <>
      {summary.from ? <Text style={styles.from}>from {summary.from}</Text> : null}

      {/* That it was updated, not what it used to say. A family is told the record changed;
          the versions behind it are a care manager's to read. */}
      {day.corrected ? (
        <Text style={styles.corrected}>This was updated after it was first written.</Text>
      ) : null}

      <Text style={styles.heading}>What changed today</Text>
      {summary.changed.length === 0 ? (
        <View style={styles.steady}>
          <Icon name="check" size={18} color={color.sage} />
          <Text style={styles.steadyText}>{STEADY_DAY}</Text>
        </View>
      ) : (
        summary.changed.map((line) => (
          <Text key={line} style={styles.line}>
            {line}
          </Text>
        ))
      )}

      <Text style={styles.heading}>Care today</Text>
      {summary.care.map((g) => (
        <CareRow key={g.label} group={g} />
      ))}

      {summary.note ? (
        <>
          <Text style={styles.heading}>
            {summary.from ? `Note from ${summary.from}` : 'Note from the care home'}
          </Text>
          <Text style={styles.quote}>{summary.note}</Text>
        </>
      ) : null}

      {photos === undefined ? (
        <ActivityIndicator style={styles.spinner} color={color.clay} />
      ) : photos.length > 0 ? (
        <>
          <Text style={styles.heading}>Photo from today</Text>
          <View style={styles.photos}>
            {photos.map((photo) => (
              <Image
                key={photo.id}
                source={{ uri: photo.url }}
                style={styles.photo}
                contentFit="cover"
                accessibilityLabel="A photo from today"
              />
            ))}
          </View>
        </>
      ) : null}

      {/* Who it came from, again. The care home's own summary says it twice - once at the
          top and once at the foot - and the second one is what tells a family why this is
          on their phone at all. */}
      <Text style={styles.footnote}>
        {summary.from
          ? `Written by ${summary.from} at the care home, ${timeOfDay(day.filedAt)}.`
          : `Written at the care home, ${timeOfDay(day.filedAt)}.`}
      </Text>
    </>
  );
}

/**
 * One group of care information.
 *
 * A count and the names, which is how the care home's own daily summary puts it and is the
 * fastest thing to take in. No colour standing in for a judgement: the summary a family gets
 * today has no flags in it, and flags belong to the caregiver confirming what they filed.
 */
function CareRow({ group }: { group: CareGroup }) {
  return (
    <View style={styles.care}>
      <View style={styles.careHead}>
        <Text style={styles.careLabel}>{group.label}</Text>
        <Text style={styles.careCount}>
          {group.done} of {group.total}
        </Text>
      </View>
      {group.did.length > 0 ? (
        <Text style={styles.careDid}>{group.did.join(', ')}</Text>
      ) : null}
      {group.didNot.length > 0 ? (
        <Text style={styles.careDidNot}>Not recorded: {group.didNot.join(', ')}</Text>
      ) : null}
      {/* Quiet, and under the thing it is about. A family should be able to tell a
          caregiver's own record from a pharmacy's without being warned about it. */}
      {group.source ? <Text style={styles.careSource}>{group.source}</Text> : null}
    </View>
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
  whoRow: { flexDirection: 'row', alignItems: 'center', gap: 14, marginBottom: 2 },
  earlier: {
    backgroundColor: color.white,
    borderRadius: radii.card,
    borderWidth: 1,
    borderColor: color.frame,
    padding: 16,
    marginBottom: 10,
    gap: 3,
  },
  earlierPressed: { opacity: 0.7 },

  // Wraps rather than squeezes: at the largest text setting seven columns do not fit across
  // a phone, and two rows of four read fine where seven clipped columns do not.
  strip: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 6,
    marginTop: 4,
    marginBottom: 2,
  },
  column: {
    flexGrow: 1,
    flexBasis: 40,
    alignItems: 'center',
    paddingVertical: 8,
    paddingHorizontal: 4,
    borderRadius: radii.innerCard,
    borderWidth: 1,
    borderColor: color.frame,
    backgroundColor: color.white,
    gap: 1,
  },
  columnBlank: { backgroundColor: color.paper, borderColor: color.line },
  columnNoted: { backgroundColor: color.honeySoft, borderColor: color.warnSoft },
  // Today reads as the day you are on rather than as a day with something in it.
  columnToday: { borderColor: color.clay, borderWidth: 2 },
  columnDay: { ...type.meta, color: color.ink3 },
  columnDate: { ...type.fieldLabel, color: color.ink },
  columnMeals: { ...type.meta, color: color.ink3 },
  columnMealsShort: { color: color.clay },
  weekLine: { ...type.body, color: color.ink2, marginTop: 6 },
  backToday: { paddingVertical: 8, alignSelf: 'flex-start' },
  toPhotos: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 12,
    marginTop: 18,
    alignSelf: 'flex-start',
  },
  toPhotosText: { ...type.body, color: color.clay, textDecorationLine: 'underline' },
  backTodayText: { ...type.body, color: color.clay, textDecorationLine: 'underline' },
  earlierWhen: { ...type.cardTitle, color: color.ink },
  earlierHow: { ...type.body, color: color.ink2 },
  earlierMeals: { ...type.meta, color: color.ink3, marginTop: 2 },
  whoText: { flex: 1 },
  title: { ...type.screenTitle, color: color.ink, marginTop: 8 },
  blurb: { ...type.blurb, marginBottom: 8 },
  offer: {
    backgroundColor: color.honeySoft,
    borderRadius: radii.card,
    padding: 18,
    gap: 10,
    marginTop: 12,
  },
  offerTitle: { ...type.cardTitle, color: color.ink },
  offerBlurb: { ...type.blurb, marginBottom: 2 },
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

  // Laid out to be scanned, which is what a daily update is for - the care home's own
  // summary can be taken in at the end of a shift and so should this. No colour standing in
  // for a judgement: that summary has no flags in it. The design pass can replace every
  // number here; what it should not have to undo is the order.
  from: { ...type.meta, color: color.ink3, marginTop: 2 },
  corrected: { ...type.meta, color: color.ink3, marginTop: 14, fontStyle: 'italic' },

  heading: { ...type.sectionLabel, color: color.ink3, marginTop: 26, marginBottom: 4 },
  line: { ...type.body, color: color.ink, fontSize: 16, lineHeight: 25, marginTop: 8 },

  steady: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    marginTop: 8,
    padding: 14,
    borderRadius: radii.innerCard,
    backgroundColor: color.sageSoft,
  },
  steadyText: { ...type.body, color: color.ink, flex: 1 },

  care: {
    marginTop: 8,
    paddingVertical: 12,
    paddingHorizontal: 14,
    borderRadius: radii.innerCard,
    borderWidth: 1,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  careHead: { flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between' },
  careLabel: { ...type.checklistItem, color: color.ink },
  careCount: { ...type.chip, color: color.ink3 },
  careDid: { ...type.body, color: color.ink2, marginTop: 4 },
  careDidNot: { ...type.body, color: color.ink3, marginTop: 4 },
  careSource: { ...type.meta, color: color.ink4, marginTop: 6 },

  quote: {
    ...type.body,
    color: color.ink,
    fontSize: 16,
    lineHeight: 25,
    marginTop: 10,
    paddingLeft: 14,
    borderLeftWidth: 2,
    borderLeftColor: color.frame,
  },

  spinner: { alignSelf: 'flex-start', marginTop: 20 },
  photos: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 8 },
  photo: { width: 196, height: 196, borderRadius: radii.photoThumb, backgroundColor: color.paper2 },

  footnote: { ...type.meta, color: color.ink4, marginTop: 28, lineHeight: 19 },
});
