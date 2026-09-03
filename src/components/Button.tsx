import { ActivityIndicator, Pressable, StyleSheet, Text } from 'react-native';

import { color, control, radius, space, type } from '@/theme/tokens';

interface ButtonProps {
  label: string;
  onPress: () => void;
  variant?: 'primary' | 'secondary';
  disabled?: boolean;
  busy?: boolean;
}

export function Button({
  label,
  onPress,
  variant = 'primary',
  disabled = false,
  busy = false,
}: ButtonProps) {
  const inactive = disabled || busy;

  return (
    <Pressable
      onPress={onPress}
      disabled={inactive}
      accessibilityRole="button"
      accessibilityState={{ disabled: inactive, busy }}
      accessibilityLabel={label}
      style={({ pressed }) => [
        styles.base,
        variant === 'primary' ? styles.primary : styles.secondary,
        inactive && styles.inactive,
        pressed && styles.pressed,
      ]}
    >
      {busy ? (
        <ActivityIndicator color={variant === 'primary' ? color.paper : color.ink} />
      ) : (
        <Text style={[styles.label, variant === 'primary' ? styles.labelPrimary : styles.labelSecondary]}>
          {label}
        </Text>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    minHeight: control.height,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: space.xl,
    borderRadius: radius.pill,
    borderWidth: 1,
  },
  primary: { backgroundColor: color.clay, borderColor: color.clay },
  secondary: { backgroundColor: color.surface, borderColor: color.lineStrong },
  inactive: { opacity: 0.45 },
  pressed: { opacity: 0.8 },
  label: { ...type.body, fontWeight: '600' },
  labelPrimary: { color: color.paper },
  labelSecondary: { color: color.ink },
});
