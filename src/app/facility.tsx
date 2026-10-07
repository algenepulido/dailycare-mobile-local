import { router } from 'expo-router';
import { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, RefreshControl, StyleSheet, Text, View } from 'react-native';

import { Button, Screen, SectionHeading } from '@/components';
import { InviteSheet } from '@/components/InviteSheet';
import { AdmitSheet } from '@/components/AdmitSheet';
import { ResidentSheet } from '@/components/ResidentSheet';
import {
  ApiError,
  SignedOut,
  endMembership,
  listAssignments,
  listMembers,
  listResidents,
} from '@/data/api';
import type { RemoteAssignment, RemoteMember, RemoteResident } from '@/data/api';
import { useSession } from '@/state/session';
import { color, radii, sizes, type } from '@/theme/tokens';

/**
 * The screen a building is run from.
 *
 * Everything on it was a terminal job until this milestone, and the test it has to pass is
 * the milestone's own sentence: a care manager sets a building up with no developer in the
 * room. So the actions are here rather than documented, and the destructive-looking ones
 * say what they actually do - a membership ends on a date and the person stays in the list,
 * because a day they filed has their name on it and a name with nothing behind it is worse
 * than a row that says they have left.
 *
 * It decides nothing. Every refusal below is the server's, shown as the sentence it came
 * with: a care manager who reads "only a care manager can do this" learns something, and
 * one who reads "that did not work" learns that the app does not know either.
 */
export default function FacilityScreen() {
  const { account } = useSession();
  // The first building, and there is no switcher. The milestone's card says "the screen the
  // building is run from", singular, and every care manager in the pilot runs one. Somebody
  // who runs two would see the first and have no way to the second, which is why the title
  // is the building's name rather than "Your building" - a screen that quietly picks one of
  // two is worse than one that says which it picked.
  const building = account?.manages?.[0];

  const [members, setMembers] = useState<RemoteMember[] | null>(null);
  const [residents, setResidents] = useState<RemoteResident[] | null>(null);
  const [assignments, setAssignments] = useState<RemoteAssignment[] | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [inviting, setInviting] = useState(false);
  const [admitting, setAdmitting] = useState(false);
  const [looking, setLooking] = useState<RemoteResident | null>(null);

  const load = useCallback(async () => {
    if (!building) return;
    try {
      const [m, r, a] = await Promise.all([
        listMembers(building.id),
        listResidents(),
        listAssignments(building.id),
      ]);
      setMembers(m);
      setResidents(r.filter((person) => person.facilityId === building.id));
      setAssignments(a);
      setProblem(null);
    } catch (error) {
      if (error instanceof SignedOut) {
        setProblem('Your session has ended. Sign in again to see this.');
      } else if (error instanceof ApiError) {
        setProblem(error.message);
      } else {
        setProblem('The building could not be read just now.');
      }
    }
  }, [building]);

  useEffect(() => {
    void load();
  }, [load]);

  const refresh = useCallback(async () => {
    setRefreshing(true);
    await load();
    setRefreshing(false);
  }, [load]);

  // A membership ends rather than being removed, and the screen says so before it happens
  // rather than afterwards. Two taps, no dialog: the second tap is on a row that has already
  // changed to ask the question, which is a confirmation that cannot be dismissed by accident.
  const [ending, setEnding] = useState<string | null>(null);
  const end = useCallback(
    async (member: RemoteMember) => {
      if (ending !== member.id) {
        setEnding(member.id);
        return;
      }
      setEnding(null);
      try {
        await endMembership(member.id);
        await load();
      } catch (error) {
        setProblem(error instanceof ApiError ? error.message : 'That could not be done just now.');
      }
    },
    [ending, load],
  );

  if (!building) {
    // Not an error. Almost every account is this, and the route is reachable by a deep link.
    return (
      <Screen footer={<Button label="Back" variant="secondary" onPress={() => router.back()} />}>
        <Text style={styles.title}>No building to run</Text>
        <Text style={styles.blurb}>
          This screen belongs to a care manager. Your account is not one at any building.
        </Text>
      </Screen>
    );
  }

  const working = members?.filter((m) => !m.endedAt) ?? [];
  const gone = members?.filter((m) => m.endedAt) ?? [];
  const here = residents ?? [];

  return (
    <Screen
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={refresh} tintColor={color.clay} />}
      footer={<Button label="Back" variant="secondary" onPress={() => router.back()} />}
    >
      <Text style={styles.title}>{building.name}</Text>
      <Text style={styles.blurb}>Who works here, who lives here, and who may read about them.</Text>

      {problem ? <Text style={styles.problem}>{problem}</Text> : null}

      {members === null && !problem ? (
        <View style={styles.loading}>
          <ActivityIndicator color={color.clay} />
        </View>
      ) : null}

      {members !== null ? (
        <>
          <SectionHeading title="Residents" hint={`${here.length} living here`} />
          {here.length === 0 ? (
            <Text style={styles.empty}>Nobody has been admitted yet.</Text>
          ) : (
            here.map((person) => {
              const theirs = (assignments ?? []).filter(
                (a) => a.residentId === person.id && !a.endedAt,
              );
              return (
                <Pressable
                  key={person.id}
                  style={styles.row}
                  onPress={() => setLooking(person)}
                  accessibilityRole="button"
                  accessibilityLabel={`${person.displayName}, open`}
                >
                  <View style={styles.rowText}>
                    <Text style={styles.rowName}>{person.displayName}</Text>
                    <Text style={styles.rowUnder}>
                      {theirs.length === 0
                        ? 'Nobody is assigned'
                        : theirs.map((a) => a.displayName).join(', ')}
                    </Text>
                  </View>
                </Pressable>
              );
            })
          )}
          <Button label="Admit a resident" variant="secondary" onPress={() => setAdmitting(true)} />

          <SectionHeading title="People who work here" hint={`${working.length} here now`} />
          {working.map((m) => (
            <Pressable
              key={m.id}
              style={[styles.row, ending === m.id && styles.rowAsking]}
              onPress={() => void end(m)}
              accessibilityRole="button"
              accessibilityLabel={
                ending === m.id ? `Confirm ending ${m.displayName}` : `${m.displayName}, end their time here`
              }
            >
              <View style={styles.rowText}>
                <Text style={styles.rowName}>{m.displayName}</Text>
                <Text style={styles.rowUnder}>
                  {m.role === 'care_manager' ? 'Care manager' : 'Caregiver'}
                  {m.state === 'invited' ? ' — invited, not here yet' : ''}
                </Text>
                {/* The address, where two people in a building share a name.
                  *
                  * Two Maria Santoses is not a contrivance - it is what a staging instance
                  * already had and what a care home with forty staff will have. A list that
                  * cannot tell them apart is a list a manager cannot end the right
                  * membership from. Shown only when it is needed, because an address under
                  * every name is noise the rest of the time, and it is the thing a manager
                  * typed to invite them. */}
                {working.filter((o) => o.displayName === m.displayName).length > 1 ? (
                  <Text style={styles.rowUnder}>{m.email}</Text>
                ) : null}
              </View>
              <Text style={styles.action}>
                {ending === m.id ? 'Tap again to end it' : 'End'}
              </Text>
            </Pressable>
          ))}
          <Button label="Invite somebody" variant="secondary" onPress={() => setInviting(true)} />

          {gone.length > 0 ? (
            <>
              <SectionHeading
                title="People who have left"
                hint="Their records stay, and so do their names on them"
              />
              {gone.map((m) => (
                <View key={m.id} style={[styles.row, styles.rowGone]}>
                  <View style={styles.rowText}>
                    <Text style={styles.rowName}>{m.displayName}</Text>
                    <Text style={styles.rowUnder}>
                      Left {new Date(m.endedAt as string).toLocaleDateString()}
                    </Text>
                  </View>
                </View>
              ))}
            </>
          ) : null}
        </>
      ) : null}

      <InviteSheet
        open={inviting}
        facilityId={building.id}
        onClose={() => setInviting(false)}
        onDone={() => void load()}
      />
      <AdmitSheet
        open={admitting}
        facilityId={building.id}
        onClose={() => setAdmitting(false)}
        onDone={() => void load()}
      />
      <ResidentSheet
        open={looking !== null}
        resident={looking}
        facilityId={building.id}
        members={working}
        assignments={assignments ?? []}
        onClose={() => setLooking(null)}
        onDone={() => void load()}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { ...type.screenTitle, color: color.ink },
  blurb: { ...type.body, color: color.ink3, marginTop: sizes.cardGap / 2, marginBottom: sizes.sectionGap },
  problem: {
    ...type.body,
    color: color.ink,
    backgroundColor: color.flagSoft,
    borderRadius: radii.card,
    padding: sizes.screenPaddingH - 6,
    marginBottom: sizes.screenPaddingH - 6,
  },
  loading: { paddingVertical: sizes.sectionGap * 2, alignItems: 'center' },
  empty: { ...type.body, color: color.ink3, paddingVertical: sizes.screenPaddingH - 6 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: sizes.screenPaddingH - 6,
    backgroundColor: color.white,
    borderRadius: radii.card,
    borderWidth: 1,
    borderColor: color.frame,
    padding: sizes.screenPaddingH - 6,
    marginBottom: sizes.cardGap,
  },
  rowAsking: { borderColor: color.clay, backgroundColor: color.claySoft },
  rowGone: { backgroundColor: color.paper2, borderColor: color.line },
  rowText: { flex: 1, gap: 2 },
  rowName: { ...type.cardTitle, color: color.ink },
  rowUnder: { ...type.meta, color: color.ink3 },
  action: { ...type.chip, color: color.clay },
});
