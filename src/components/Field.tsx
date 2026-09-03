import { StyleSheet, TextInput } from 'react-native';

import { color, control, radius, space, type } from '@/theme/tokens';

interface FieldProps {
  value: string;
  onChangeText: (value: string) => void;
  placeholder?: string;
  accessibilityLabel: string;
  /** Grows into a note box with no visible frame, the way the reference note reads. */
  multiline?: boolean;
  /** Borderless, for a note that sits inside its own card. */
  bare?: boolean;
  autoCapitalize?: 'none' | 'words' | 'sentences';
}

export function Field({
  value,
  onChangeText,
  placeholder,
  accessibilityLabel,
  multiline = false,
  bare = false,
  autoCapitalize = 'sentences',
}: FieldProps) {
  return (
    <TextInput
      value={value}
      onChangeText={onChangeText}
      placeholder={placeholder}
      placeholderTextColor={color.inkFaint}
      multiline={multiline}
      autoCapitalize={autoCapitalize}
      accessibilityLabel={accessibilityLabel}
      style={[styles.input, bare ? styles.bare : styles.framed, multiline && styles.multiline]}
    />
  );
}

const styles = StyleSheet.create({
  input: { ...type.body, color: color.ink },
  framed: {
    height: control.height,
    paddingHorizontal: 14,
    borderRadius: radius.md,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.paper,
  },
  bare: { paddingHorizontal: 0, backgroundColor: 'transparent' },
  multiline: { height: undefined, minHeight: 60, textAlignVertical: 'top', paddingTop: space.sm },
});
