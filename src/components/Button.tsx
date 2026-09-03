import { ActivityIndicator, Pressable, StyleSheet, Text } from 'react-native';

import { color, control, radius, space, type } from '@/theme/tokens';

interface ButtonProps {
  label: string;
  onPress: () => void;
  variant?: 'primary' | 'secondary';
  disabled?: boolean;
  busy?: boolean;
}

/** The save action. Near-black and full width, the way the reference anchors a screen. */
export function Button({
  label,
  onPress,
  variant = 'primary',
  disabled = false,
  busy = false,
}: ButtonProps) {
  const inactive = disabled || busy;
  const primary = variant === 'primary';

  return (
    <Pressable
      onPress={onPress}
      disabled={inactive}
      accessibilityRole="button"
      accessibilityState={{ disabled: inactive, busy }}
      accessibilityLabel={label}
      style={({ pressed }) => [
        styles.base,
        primary ? styles.primary : styles.secondary,
        inactive && styles.inactive,
        pressed && styles.pressed,
      ]}
    >
      {busy ? (
        <ActivityIndicator color={primary ? color.paper : color.ink} />
      ) : (
        <Text style={[styles.label, primary ? styles.labelPrimary : styles.labelSecondary]}>
          {label}
        </Text>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    height: control.saveHeight,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: space.xl,
    borderRadius: control.saveHeight / 2,
  },
  primary: { backgroundColor: color.ink },
  secondary: { backgroundColor: color.surface, borderWidth: 1.5, borderColor: color.line },
  inactive: { opacity: 0.4 },
  pressed: { opacity: 0.85 },
  label: { ...type.button },
  labelPrimary: { color: color.paper },
  labelSecondary: { color: color.ink },
});
