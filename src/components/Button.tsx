import { ActivityIndicator, Pressable, StyleSheet, Text } from 'react-native';

import { color, opacity, radii, sizes, type } from "@/theme/tokens";

interface ButtonProps {
  label: string;
  onPress: () => void;
  variant?: 'primary' | 'secondary';
  disabled?: boolean;
  busy?: boolean;
  /**
   * How the button reads when it cannot be pressed.
   *
   * `dim` is design-system's blanket rule, opacity 0.4. `muted` swaps the fill instead,
   * and belongs with a label that says what is still missing — a dimmed button leaves the
   * reader to work that out, a filled one that reads "Add both names to continue" does not.
   */
  disabledAppearance?: 'dim' | 'muted';
}

/** Full-width ink pill, 56pt. The one action anchoring a screen or a sheet. */
export function Button({
  label,
  onPress,
  variant = 'primary',
  disabled = false,
  busy = false,
  disabledAppearance = 'dim',
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
        inactive && (disabledAppearance === 'muted' ? styles.muted : styles.inactive),
        pressed && styles.pressed,
      ]}
    >
      {busy ? (
        <ActivityIndicator color={primary ? color.white : color.ink} />
      ) : (
        <Text
          style={[
            styles.label,
            primary ? styles.labelPrimary : styles.labelSecondary,
            inactive && disabledAppearance === 'muted' && styles.labelMuted,
          ]}
        >
          {label}
        </Text>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  base: {
    height: sizes.pillButtonHeight,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 22,
    borderRadius: radii.pillButton,
  },
  primary: { backgroundColor: color.ink },
  secondary: { backgroundColor: color.white, borderWidth: 1.5, borderColor: color.line },
  inactive: { opacity: opacity.disabled },
  muted: { backgroundColor: color.paper2 },
  labelMuted: { color: color.ink4 },
  pressed: { opacity: 0.85 },
  label: { ...type.buttonPrimary },
  labelPrimary: { color: color.white },
  labelSecondary: { color: color.ink },
});
