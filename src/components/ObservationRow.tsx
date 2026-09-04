import { StyleSheet, Text, View } from 'react-native';

import { color, type } from "@/theme/tokens";

import { Chip } from './Chip';

interface ObservationRowProps<T extends string> {
  label: string;
  options: readonly T[];
  value: NoInfer<T>;
  /** What this resident is usually like. It decides what counts as news. */
  baseline: NoInfer<T>;
  onChange: (value: NoInfer<T>) => void;
  alertValues?: readonly NoInfer<T>[];
}

/**
 * Mood, appetite or sleep, with a live tag saying whether this is news.
 *
 * The tag is the point. The summary only reports what differs from the resident's usual,
 * so without it a caregiver is choosing blind.
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
  row: { marginBottom: 16 },
  head: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 10 },
  label: { ...type.fieldLabel },
  changed: { ...type.changedTag },
  same: { fontFamily: type.meta.fontFamily, fontSize: 11, color: color.ink4 },
  options: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
});
