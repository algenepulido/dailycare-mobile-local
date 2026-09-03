import { StyleSheet, Text, View } from 'react-native';

import { color, space, type } from '@/theme/tokens';

import { Chip } from './Chip';

export interface MealRowProps<T extends string> {
  label: string;
  options: readonly T[];
  value: NoInfer<T>;
  onChange: (value: NoInfer<T>) => void;
  formatLabel?: (option: NoInfer<T>) => string;
}

/**
 * A meal and how much of it was eaten.
 *
 * The reference records meals as a plain checkbox. Three states are Trevor's addition,
 * so this keeps the reference's row shape — name on the left, controls on the right —
 * rather than inventing a different pattern for one section.
 */
export function MealRow<T extends string>({
  label,
  options,
  value,
  onChange,
  formatLabel = (option) => option,
}: MealRowProps<T>) {
  return (
    <View style={styles.row}>
      <Text style={styles.label}>{label}</Text>
      <View style={styles.options}>
        {options.map((option) => (
          <Chip
            key={option}
            label={formatLabel(option)}
            selected={value === option}
            onPress={() => onChange(option)}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: space.md, paddingVertical: space.sm },
  label: { ...type.bodyLarge, color: color.inkMuted, width: 92 },
  options: { flex: 1, flexDirection: 'row', gap: 6, justifyContent: 'flex-end' },
});
