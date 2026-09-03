import { StyleSheet, View } from 'react-native';

import { space } from '@/theme/tokens';

import { Chip } from './Chip';

interface ChipGroupProps<T extends string> {
  options: readonly T[];
  selected: readonly NoInfer<T>[];
  onToggle: (value: NoInfer<T>) => void;
  /** Concerns are always worth attention, so the whole set reads as alerting. */
  alertAll?: boolean;
}

/** Multi-select set. Used for concerns, where any number can be true at once. */
export function ChipGroup<T extends string>({
  options,
  selected,
  onToggle,
  alertAll = false,
}: ChipGroupProps<T>) {
  return (
    <View style={styles.wrap}>
      {options.map((option) => (
        <Chip
          key={option}
          label={option}
          selected={selected.includes(option)}
          alert={alertAll}
          onPress={() => onToggle(option)}
        />
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
});
