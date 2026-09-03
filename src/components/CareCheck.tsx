import { Pressable, StyleSheet, Text, View } from 'react-native';

import { color, control, radius, space, type } from '@/theme/tokens';

interface CareCheckProps {
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
}

/**
 * A single thing that either happened or didn't — a meal, a dose, a shower.
 *
 * Deliberately large: this is what a caregiver taps a dozen times a day, often standing
 * up, often on someone else's phone.
 */
export function CareCheck({ label, checked, onChange, disabled = false }: CareCheckProps) {
  return (
    <Pressable
      onPress={() => onChange(!checked)}
      disabled={disabled}
      accessibilityRole="checkbox"
      accessibilityState={{ checked, disabled }}
      accessibilityLabel={label}
      style={({ pressed }) => [styles.row, pressed && styles.pressed, disabled && styles.disabled]}
    >
      <View style={[styles.box, checked && styles.boxChecked]}>
        {checked ? <Text style={styles.tick}>✓</Text> : null}
      </View>
      <Text style={[styles.label, checked && styles.labelChecked]}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 14, paddingVertical: 11 },
  pressed: { opacity: 0.6 },
  disabled: { opacity: 0.4 },
  box: {
    width: control.checkbox,
    height: control.checkbox,
    borderRadius: radius.sm,
    borderWidth: 2,
    borderColor: color.lineStrong,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'transparent',
  },
  boxChecked: { backgroundColor: color.sage, borderColor: color.sage },
  tick: { color: color.paper, fontSize: 16, fontWeight: '700', lineHeight: 19 },
  label: { ...type.bodyLarge, color: color.inkMuted, flex: 1 },
  labelChecked: { color: color.ink },
});
