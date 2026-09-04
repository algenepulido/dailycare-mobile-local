import { Pressable, StyleSheet, Text } from 'react-native';

import { color, opacity, radii, sizes, type } from "@/theme/tokens";

interface ChipProps {
  label: string;
  selected: boolean;
  /** Marks a value worth the family's attention. Fills solid red rather than tinting. */
  alert?: boolean;
  onPress: () => void;
  disabled?: boolean;
}

/** Off: white with a hairline. On: solid ink. On and alerting: solid flag red. */
export function Chip({ label, selected, alert = false, onPress, disabled = false }: ChipProps) {
  const flagged = selected && alert;
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityState={{ selected, disabled }}
      accessibilityLabel={label}
      style={({ pressed }) => [
        styles.chip,
        selected && styles.selected,
        flagged && styles.flagged,
        disabled && styles.disabled,
        pressed && styles.pressed,
      ]}
    >
      <Text numberOfLines={1} style={[styles.label, selected && styles.labelSelected]}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  chip: {
    height: sizes.chipHeight,
    justifyContent: 'center',
    paddingHorizontal: 14,
    borderRadius: radii.chip,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  selected: { backgroundColor: color.ink, borderColor: color.ink },
  flagged: { backgroundColor: color.flag, borderColor: color.flag },
  disabled: { opacity: opacity.disabled },
  pressed: { opacity: 0.75 },
  label: { ...type.chip, color: color.ink },
  labelSelected: { color: color.white },
});
