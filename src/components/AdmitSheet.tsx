import { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button } from './Button';
import { Chip } from './Chip';
import { Field } from './Field';
import { Sheet } from './Sheet';
import { ApiError, admitResident } from '@/data/api';
import { APPETITE_WIRE, MOOD_WIRE, SLEEP_WIRE } from '@/data/wire';
import { APPETITES, MOODS, SLEEPS } from '@/domain/types';
import type { Appetite, Mood, Sleep } from '@/domain/types';
import { color, radii, sizes, type } from '@/theme/tokens';

interface AdmitSheetProps {
  open: boolean;
  facilityId: string;
  onClose: () => void;
  onDone: () => void;
}

/**
 * Admitting a resident, and the three answers that make a day readable afterwards.
 *
 * The baseline is asked for here rather than left to default because it is what the family
 * screen compares against: "what changed today" has no meaning without "what is usual for
 * her", and a resident admitted with the column defaults gets a week of days that all read
 * as ordinary whether they were or not.
 */
export function AdmitSheet({ open, facilityId, onClose, onDone }: AdmitSheetProps) {
  const [name, setName] = useState('');
  // The screen's words, translated on the way out by the same tables the day form uses.
  // Two places writing these values with two spellings is how a baseline comes to disagree
  // with the days compared against it.
  // Nothing chosen to begin with, which is the opposite of how this read.
  //
  // It opened on Calm, Fair and Restless, and a care manager who admitted somebody without
  // looking at this card had stated a normal for them by not touching it. That one answer
  // is what every later day is compared against, so a baseline accepted by default makes
  // "what changed today" wrong for as long as nobody notices - and the family hears the
  // wrong thing, or hears nothing at all. The rule the day form already follows, that a
  // usual answer is never pre-marked, belongs here most of all.
  const [mood, setMood] = useState<Mood | null>(null);
  const [appetite, setAppetite] = useState<Appetite | null>(null);
  const [sleep, setSleep] = useState<Sleep | null>(null);
  const [saving, setSaving] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  const close = () => {
    setName('');
    setMood(null);
    setAppetite(null);
    setSleep(null);
    setProblem(null);
    onClose();
  };

  const admit = async () => {
    if (mood === null || appetite === null || sleep === null) return;
    setSaving(true);
    setProblem(null);
    try {
      await admitResident(facilityId, name.trim(), {
        mood: MOOD_WIRE[mood],
        appetite: APPETITE_WIRE[appetite],
        sleep: SLEEP_WIRE[sleep],
      });
      onDone();
      close();
    } catch (error) {
      setProblem(error instanceof ApiError ? error.message : 'That could not be done just now.');
    } finally {
      setSaving(false);
    }
  };

  function row<T extends string>(
    label: string,
    options: readonly T[],
    value: T | null,
    set: (v: T) => void,
  ) {
    return (
      <>
        <Text style={styles.label}>{label}</Text>
        <View style={styles.chips}>
          {options.map((o) => (
            <Chip key={o} label={o} selected={value === o} onPress={() => set(o)} />
          ))}
        </View>
      </>
    );
  }

  return (
    <Sheet
      open={open}
      onClose={close}
      footer={
        <Button
          label={
            saving
              ? 'Admitting…'
              : name.trim() === ''
                ? 'Add their name'
                : mood === null || appetite === null || sleep === null
                  ? 'Say what is usual for them'
                  : 'Admit'
          }
          onPress={() => void admit()}
          disabled={
            saving ||
            name.trim() === '' ||
            mood === null ||
            appetite === null ||
            sleep === null
          }
          disabledAppearance="muted"
        />
      }
    >
      <Text style={styles.title}>Admit a resident</Text>
      <Text style={styles.blurb}>
        What is usual for them, so their family can be told when a day is not.
      </Text>

      {problem ? (
        <Text style={styles.problem} accessibilityLiveRegion="polite">
          {problem}
        </Text>
      ) : null}

      <Text style={styles.label}>Their name</Text>
      <Field
        value={name}
        onChangeText={setName}
        placeholder="Cathy Alvarez"
        accessibilityLabel="Their name"
        sheet
        autoCapitalize="words"
      />

      {row('How they usually are', MOODS, mood, setMood)}
      {row('How they usually eat', APPETITES, appetite, setAppetite)}
      {row('How they usually sleep', SLEEPS, sleep, setSleep)}
    </Sheet>
  );
}

const styles = StyleSheet.create({
  title: { ...type.sheetTitle, color: color.ink },
  blurb: { ...type.blurb, marginTop: 6, marginBottom: sizes.sectionGap },
  label: { ...type.fieldLabel, marginTop: sizes.sectionGap, marginBottom: sizes.cardGap },
  chips: { flexDirection: 'row', gap: sizes.cardGap, flexWrap: 'wrap' },
  problem: {
    ...type.body,
    color: color.ink,
    backgroundColor: color.flagSoft,
    borderRadius: radii.innerCard,
    padding: 14,
    marginBottom: sizes.cardGap,
  },
});
