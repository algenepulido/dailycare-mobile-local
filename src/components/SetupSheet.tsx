import { useEffect, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import type { Appetite, Baseline, Mood, Sleep } from '@/domain/types';
import { APPETITES, MOODS, SLEEPS } from '@/domain/types';
import { color, radii, type } from '@/theme/tokens';

import { Button } from './Button';
import { Chip } from './Chip';
import { Field } from './Field';
import { Sheet } from './Sheet';

interface SetupSheetProps {
  open: boolean;
  caregiverName: string;
  residentName: string;
  baseline: Baseline;
  onSave: (caregiverName: string, residentName: string, baseline: Baseline) => void;
  onClose: () => void;
  /** First run introduces the app; every later visit is an edit to what is stored. */
  firstRun?: boolean;
}

/**
 * Who is logging, who they are logging for, and what a normal day looks like for them.
 *
 * The baseline lives here rather than in the check-in because it is a fact about the
 * resident, not about today: it decides what counts as news, so it has to be set before
 * the first day is filed and stay editable when the resident's normal shifts.
 */
export function SetupSheet({
  open,
  caregiverName,
  residentName,
  baseline,
  onSave,
  onClose,
  firstRun = false,
}: SetupSheetProps) {
  const [caregiver, setCaregiver] = useState(caregiverName);
  const [resident, setResident] = useState(residentName);
  const [usual, setUsual] = useState<Baseline>(baseline);

  // Reopening shows what is stored now, not what was typed and abandoned last time.
  useEffect(() => {
    if (!open) return;
    setCaregiver(caregiverName);
    setResident(residentName);
    setUsual(baseline);
  }, [open, caregiverName, residentName, baseline]);

  const complete = caregiver.trim().length > 0 && resident.trim().length > 0;

  return (
    <Sheet
      open={open}
      onClose={firstRun ? () => {} : onClose}
      footer={
        <Button
          label={complete ? (firstRun ? 'Start daily care' : 'Save changes') : 'Add both names to continue'}
          disabled={!complete}
          disabledAppearance="muted"
          onPress={() => onSave(caregiver.trim(), resident.trim(), usual)}
        />
      }
    >
      <ScrollView showsVerticalScrollIndicator={false} keyboardShouldPersistTaps="handled">
        <Text style={styles.title}>Let&rsquo;s set up daily care</Text>
        <Text style={styles.blurb}>
          Two names and what a normal day looks like. You can change these later.
        </Text>

        <Text style={styles.label}>Your name</Text>
        <Field
          value={caregiver}
          onChangeText={setCaregiver}
          placeholder="The caregiver reporting"
          accessibilityLabel="Your name"
          autoCapitalize="words"
          sheet
        />

        <View style={styles.gap} />

        <Text style={styles.label}>Who you&rsquo;re caring for</Text>
        <Field
          value={resident}
          onChangeText={setResident}
          placeholder="Their first name"
          accessibilityLabel="Who you're caring for"
          autoCapitalize="words"
          sheet
        />

        <Text style={styles.sectionLabel}>What&rsquo;s usual for them</Text>
        <Text style={styles.hint}>
          Each day is compared against this, so the family only hears about what changed.
        </Text>

        <View style={styles.card}>
          <UsualRow
            label="Usual mood"
            options={MOODS}
            value={usual.mood}
            onChange={(mood: Mood) => setUsual((current) => ({ ...current, mood }))}
          />
          <UsualRow
            label="Usual appetite"
            options={APPETITES}
            value={usual.appetite}
            onChange={(appetite: Appetite) => setUsual((current) => ({ ...current, appetite }))}
          />
          <UsualRow
            label="Usual sleep"
            options={SLEEPS}
            value={usual.sleep}
            onChange={(sleep: Sleep) => setUsual((current) => ({ ...current, sleep }))}
            last
          />
        </View>
      </ScrollView>
    </Sheet>
  );
}

/**
 * One baseline choice. Deliberately not ObservationRow: that row exists to say whether
 * today differs from the usual, and here the usual is the thing being set.
 */
function UsualRow<T extends string>({
  label,
  options,
  value,
  onChange,
  last = false,
}: {
  label: string;
  options: readonly T[];
  value: NoInfer<T>;
  onChange: (value: NoInfer<T>) => void;
  last?: boolean;
}) {
  return (
    <View style={last ? styles.usualLast : styles.usual}>
      <Text style={styles.label}>{label}</Text>
      <View style={styles.chips}>
        {options.map((option) => (
          <Chip
            key={option}
            label={option}
            selected={value === option}
            onPress={() => onChange(option)}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  title: { ...type.setupTitle, color: color.ink },
  blurb: { ...type.blurb, marginTop: 6, marginBottom: 20 },
  label: { ...type.fieldLabel, marginBottom: 8 },
  gap: { height: 16 },

  sectionLabel: { ...type.sectionLabel, marginTop: 24 },
  hint: { ...type.hint, marginTop: 6, marginBottom: 12 },

  card: {
    backgroundColor: color.white,
    borderRadius: radii.setupCard,
    borderWidth: 1,
    borderColor: color.line,
    paddingTop: 14,
    paddingHorizontal: 16,
    paddingBottom: 14,
    marginBottom: 8,
  },
  usual: { marginBottom: 16 },
  usualLast: { marginBottom: 0 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
});
