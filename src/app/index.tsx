import { Redirect } from 'expo-router';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { Card, Screen, SectionLabel } from '@/components';
import { relativeLabel, today } from '@/domain/dates';
import { useSession } from '@/state/session';
import { color, space, type } from '@/theme/tokens';

/**
 * The caregiver's home. Sends anyone without a session to setup first, so no screen
 * further in has to handle a missing resident.
 */
export default function HomeScreen() {
  const { caregiver, resident, ready } = useSession();

  if (!ready) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator color={color.clay} />
      </View>
    );
  }

  if (!caregiver || !resident) {
    return <Redirect href="/setup" />;
  }

  return (
    <Screen>
      <Text style={styles.eyebrow}>{relativeLabel(today())}</Text>
      <Text style={styles.title}>{resident.displayName}</Text>

      <Card>
        <SectionLabel>Usually</SectionLabel>
        <Text style={styles.body}>
          {resident.baseline.mood} · {resident.baseline.appetite} · {resident.baseline.sleep}
        </Text>
      </Card>

      <Card>
        <SectionLabel>Logging as</SectionLabel>
        <Text style={styles.body}>{caregiver.displayName}</Text>
      </Card>

      <Text style={styles.pending}>The daily check-in lands here next.</Text>
    </Screen>
  );
}

const styles = StyleSheet.create({
  loading: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: color.paper },
  eyebrow: { ...type.label, color: color.clay },
  title: { ...type.display, color: color.ink, marginTop: -space.sm },
  body: { ...type.body, color: color.inkMuted },
  pending: { ...type.caption, color: color.inkFaint },
});
