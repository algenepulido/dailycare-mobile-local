import { useRouter } from 'expo-router';
import { useState } from 'react';
import { StyleSheet, Text } from 'react-native';

import { Button, Card, ChoiceGroup, Field, Screen, SectionLabel } from '@/components';
import { useSession } from '@/state/session';
import type { Appetite, Mood, Sleep } from '@/domain/types';
import { APPETITES, DEFAULT_BASELINE, MOODS, SLEEPS } from '@/domain/types';
import { color, space, type } from '@/theme/tokens';

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
      <Text style={styles.title}>Set up DailyCare</Text>
      <Text style={styles.lede}>
        Everything here stays on this device. Use made-up names while we build.
      </Text>

      <Card>
        <SectionLabel>Who is logging</SectionLabel>
        <Field
          label="Caregiver name"
          value={caregiverName}
          onChangeText={setCaregiverName}
          placeholder="Maria"
          autoCapitalize="words"
        />
      </Card>

      <Card>
        <SectionLabel>Who they are logging for</SectionLabel>
        <Field
          label="Resident name"
          value={residentName}
          onChangeText={setResidentName}
          placeholder="Rosie"
          autoCapitalize="words"
        />
      </Card>

      <Card>
        <SectionLabel>What they are usually like</SectionLabel>
        <Text style={styles.help}>
          The family only hears about mood, appetite and sleep on the days they differ from this.
        </Text>

        <Text style={styles.field}>Mood</Text>
        <ChoiceGroup options={MOODS} value={mood} onChange={setMood} />

        <Text style={styles.field}>Appetite</Text>
        <ChoiceGroup options={APPETITES} value={appetite} onChange={setAppetite} />

        <Text style={styles.field}>Sleep</Text>
        <ChoiceGroup options={SLEEPS} value={sleep} onChange={setSleep} />
      </Card>
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { ...type.display, color: color.ink },
  lede: { ...type.body, color: color.inkSoft, marginTop: -space.sm },
  help: { ...type.caption, color: color.inkSoft },
  field: { ...type.label, color: color.inkFaint, marginTop: space.xs },
});
