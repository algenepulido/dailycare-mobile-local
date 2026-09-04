import { useRouter } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, Text } from 'react-native';

import { Button, Card, ObservationRow, Field, Screen } from '@/components';
import { useSession } from '@/state/session';
import type { Appetite, Mood, Sleep } from '@/domain/types';
import { APPETITES, DEFAULT_BASELINE, MOODS, SLEEPS } from '@/domain/types';
import { color, type } from '@/theme/tokens';

/**
 * First run. Creates the caregiver and the resident being logged, and records what that
 * resident is usually like.
 *
 * The baseline matters more than it looks: the daily summary only reports mood, appetite
 * and sleep when they differ from it, so getting it wrong makes every day look eventful.
 */
export default function SetupScreen() {
  const router = useRouter();
  const { startSession } = useSession();

  const [caregiverName, setCaregiverName] = useState('');
  const [residentName, setResidentName] = useState('');
  const [mood, setMood] = useState<Mood>(DEFAULT_BASELINE.mood);
  const [appetite, setAppetite] = useState<Appetite>(DEFAULT_BASELINE.appetite);
  const [sleep, setSleep] = useState<Sleep>(DEFAULT_BASELINE.sleep);
  const [saving, setSaving] = useState(false);

  const complete = caregiverName.trim().length > 0 && residentName.trim().length > 0;

  async function handleStart() {
    if (!complete || saving) return;
    setSaving(true);
    try {
      await startSession({
        caregiverName,
        residentName,
        baseline: { mood, appetite, sleep },
      });
      router.replace('/');
    } finally {
      setSaving(false);
    }
  }

  return (
    <Screen
      footer={
        <Button label="Start logging" onPress={handleStart} disabled={!complete} busy={saving} />
      }
    >
      <Text style={styles.title}>Who is this for?</Text>
      <Text style={styles.lede}>
        Everything here stays on this device. Use made-up names while we build.
      </Text>

      <Card title="Your name (caregiver)">
        <Field
          value={caregiverName}
          onChangeText={setCaregiverName}
          placeholder="Maria"
          accessibilityLabel="Caregiver name"
          autoCapitalize="words"
        />
      </Card>

      <Card title="Person you care for">
        <Field
          value={residentName}
          onChangeText={setResidentName}
          placeholder="Rosie"
          accessibilityLabel="Resident name"
          autoCapitalize="words"
        />
      </Card>

      <Card title="What they are usually like">
        <Text style={styles.help}>
          The family only hears about mood, appetite and sleep on the days they differ from this.
        </Text>
        <ObservationRow label="Mood" options={MOODS} value={mood} baseline={mood} onChange={setMood} />
        <ObservationRow
          label="Appetite"
          options={APPETITES}
          value={appetite}
          baseline={appetite}
          onChange={setAppetite}
        />
        <ObservationRow label="Sleep" options={SLEEPS} value={sleep} baseline={sleep} onChange={setSleep} />
      </Card>
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { ...type.screenTitle, color: color.ink },
  lede: { ...type.body, color: color.ink3, marginTop: 0 },
  help: { ...type.meta, marginBottom: 8 },
});
