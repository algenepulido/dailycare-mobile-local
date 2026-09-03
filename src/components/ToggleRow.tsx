import { Pressable, StyleSheet, Text, View } from 'react-native';

import { color, control, radius, space, type } from '@/theme/tokens';

interface ToggleRowProps {
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
}

/**
 * A labelled row that is either done or not. Carries medication slots and hygiene tasks,
 * where the only thing recorded is whether it happened.
 */
export function ToggleRow({ label, checked, onChange, disabled = false }: ToggleRowProps) {
  return (
    <Pressable
      onPress={() => onChange(!checked)}
      disabled={disabled}
      accessibilityRole="checkbox"
      accessibilityState={{ checked, disabled }}
      accessibilityLabel={label}
      style={({ pressed }) => [styles.row, pressed && styles.pressed, disabled && styles.disabled]}
    >
      <Text style={[styles.label, checked && styles.labelChecked]}>{label}</Text>
      <View style={[styles.box, checked && styles.boxChecked]}>
        {checked ? <Text style={styles.tick}>✓</Text> : null}
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: {
    minHeight: control.height,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.md,
  },
  pressed: { opacity: 0.6 },
  disabled: { opacity: 0.4 },
  label: { ...type.body, color: color.inkMuted, flexShrink: 1 },
  labelChecked: { color: color.ink },
  box: {
    width: 26,
    height: 26,
    borderRadius: radius.sm,
    borderWidth: 1.5,
    borderColor: color.lineStrong,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: color.surface,
  },
  boxChecked: { backgroundColor: color.sage, borderColor: color.sage },
  tick: { color: color.surface, fontSize: 15, fontWeight: '700', lineHeight: 18 },
});
