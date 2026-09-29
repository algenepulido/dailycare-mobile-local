import { router } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, Screen } from '@/components';
import { SignedOut, listResidents } from '@/data/api';
import type { RemoteResident } from '@/data/api';
import { useSession } from '@/state/session';
import { color, radii, type } from '@/theme/tokens';

/**
 * Everyone this account may see.
 *
 * For a caregiver that is the residents they are assigned to; for a care manager it is
 * every resident in their building, and neither list is decided here - the server answers
 * with what the policies allow and this screen shows what came back.
 *
 * Read-only on purpose. A care manager reviews records rather than filing them, and the
 * day form is keyed to the resident this phone is set up for: switching that from here
 * would point one phone's drafts and local history at a different person. Opening
 * somebody's history is the thing this is for.
 */
export default function ResidentsScreen() {
  const { resident } = useSession();
  const [people, setPeople] = useState<RemoteResident[] | null>(null);
  const [problem, setProblem] = useState<'refused' | 'signedOut' | null>(null);

  useEffect(() => {
    let live = true;
    void (async () => {
      try {
        const got = await listResidents();
        if (live) setPeople(got);
      } catch (error) {
        if (live) setProblem(error instanceof SignedOut ? 'signedOut' : 'refused');
      }
    })();
    return () => {
      live = false;
    };
  }, []);

  return (
    <Screen footer={<Button label="Back" variant="secondary" onPress={() => router.back()} />}>
      <Text style={styles.title}>Residents</Text>
      <Text style={styles.blurb}>Everyone this account may see.</Text>

      {problem === 'signedOut' ? (
        <Text style={styles.empty}>Your session has ended. Sign in again to see this.</Text>
      ) : problem === 'refused' ? (
        <Text style={styles.empty}>This list is not available to you.</Text>
      ) : people === null ? (
        <View style={styles.loading}>
          <ActivityIndicator color={color.clay} />
        </View>
      ) : people.length === 0 ? (
        // A caregiver with no assignments, which is a real state and not a fault: they
        // have an account and nobody has given them anybody yet.
        <Text style={styles.empty}>Nobody has been assigned to you yet.</Text>
      ) : (
        people.map((person) => {
          const here = person.id === resident?.remoteId;
          return (
            <Pressable
              key={person.id}
              style={styles.row}
              accessibilityRole="button"
              accessibilityLabel={`${person.displayName}. See their last three weeks.`}
              onPress={() =>
                router.push({
                  pathname: '/history',
                  params: { id: person.id, name: person.displayName },
                })
              }
            >
              <Text style={styles.name}>{person.displayName}</Text>
              {here ? <Text style={styles.here}>This phone</Text> : null}
            </Pressable>
          );
        })
      )}
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
    paddingVertical: 16,
    paddingHorizontal: 16,
    marginBottom: 10,
  },
  name: { ...type.checklistItem, color: color.ink },
  here: { ...type.chip, color: color.ink4 },
});
