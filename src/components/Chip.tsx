import { Pressable, StyleSheet, Text } from 'react-native';

import { color, control, radius, space, type } from '@/theme/tokens';

interface ChipProps {
  label: string;
  selected: boolean;
  /** Marks a value worth the family's attention. Fills solid red rather than tinting. */
  alert?: boolean;
  onPress: () => void;
  disabled?: boolean;
}

/**
 * One option in a set.
 *
 * Selected fills solid — near-black normally, red when the value is one the family
 * should notice. A tint with an outline reads as "sort of chosen" from arm's length,
 * which is the wrong signal on a screen someone fills in standing up.
 */
export function Chip({ label, selected, alert = false, onPress, disabled = false }: ChipProps) {
  const flag = selected && alert;
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      hitSlop={control.hitSlop}
      accessibilityRole="button"
      accessibilityState={{ selected, disabled }}
      accessibilityLabel={label}
      style={({ pressed }) => [
        styles.chip,
        selected && styles.selected,
        flag && styles.flagged,
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
    height: control.chipHeight,
    justifyContent: 'center',
    paddingHorizontal: 14,
    borderRadius: radius.pill,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.surface,
  },
  selected: { backgroundColor: color.ink, borderColor: color.ink },
  flagged: { backgroundColor: color.alert, borderColor: color.alert },
  disabled: { opacity: 0.4 },
  pressed: { opacity: 0.75 },
  label: { ...type.chip, color: color.ink },
  labelSelected: { color: color.paper },
});
