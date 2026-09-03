import { StyleSheet, Text, View } from 'react-native';

import { color, space, type } from '@/theme/tokens';

import { Chip } from './Chip';

interface ObservationRowProps<T extends string> {
  label: string;
  options: readonly T[];
  value: NoInfer<T>;
  /** What this resident is usually like. Deciding what counts as news. */
  baseline: NoInfer<T>;
  onChange: (value: NoInfer<T>) => void;
  /** Values that should read as needing attention once chosen. */
  alertValues?: readonly NoInfer<T>[];
}

/**
 * Mood, appetite or sleep, with a live marker saying whether this is news.
 *
 * The marker is the point. A caregiver needs to know at the moment they tap that this
 * one is going to reach the family — the summary only reports what differs from the
 * resident's usual, so without it they are choosing blind.
 */
export function ObservationRow<T extends string>({
  label,
  options,
  value,
  baseline,
  onChange,
  alertValues = [],
}: ObservationRowProps<T>) {
  const changed = value !== baseline;

  return (
    <View style={styles.row}>
      <View style={styles.head}>
        <Text style={styles.label}>{label}</Text>
        {changed ? (
          <Text style={styles.changed}>changed</Text>
        ) : (
          <Text style={styles.same}>same as usual</Text>
        )}
      </View>
      <View style={styles.options}>
        {options.map((option) => (
          <Chip
            key={option}
            label={option}
            selected={value === option}
            alert={alertValues.includes(option)}
            onPress={() => onChange(option)}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  row: { marginBottom: space.lg },
  head: { flexDirection: 'row', alignItems: 'center', gap: space.sm, marginBottom: 10 },
  label: { ...type.fieldLabel, color: color.inkMuted },
  changed: { ...type.marker, color: color.warn },
  same: { ...type.caption, fontSize: 11, color: color.inkFaint },
  options: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
});
