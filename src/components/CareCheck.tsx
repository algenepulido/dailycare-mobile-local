import { Pressable, StyleSheet, Text, View } from 'react-native';

import { color, opacity, radii, sizes, type } from "@/theme/tokens";

interface CareCheckProps {
  label: string;
  checked: boolean;
  onChange: (checked: boolean) => void;
  /** Revealed under the row once it is checked — used for full / partial meals. */
  detail?: React.ReactNode;
  disabled?: boolean;
}

/**
 * A single thing that either happened or didn't — a meal, a dose, a shower.
 *
 * The whole row is the target, and it is deliberately large: this is what a caregiver
 * taps a dozen times a day, often standing up, often on someone else's phone.
 */
export function CareCheck({ label, checked, onChange, detail, disabled = false }: CareCheckProps) {
  return (
    <View>
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
      {checked && detail ? <View style={styles.detail}>{detail}</View> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 14, paddingVertical: 11 },
  pressed: { opacity: 0.6 },
  disabled: { opacity: opacity.disabled },
  box: {
    width: sizes.checkbox,
    height: sizes.checkbox,
    borderRadius: radii.checkbox,
    borderWidth: 2,
    borderColor: color.line2,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'transparent',
  },
  boxChecked: { backgroundColor: color.sage, borderColor: color.sage },
  tick: { color: color.white, fontSize: 16, fontWeight: '700', lineHeight: 19 },
  label: { ...type.checklistItem, color: color.ink2, flex: 1 },
  labelChecked: { color: color.ink },
  /** Indented to the checkbox column so the follow-up reads as belonging to the row. */
  detail: { paddingLeft: sizes.checkbox + 14, paddingBottom: 10, flexDirection: 'row', gap: 8 },
});
