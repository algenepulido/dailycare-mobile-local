import { StyleSheet, TextInput } from 'react-native';

import { color, radii, sizes, type } from "@/theme/tokens";

interface FieldProps {
  value: string;
  onChangeText: (value: string) => void;
  placeholder?: string;
  accessibilityLabel: string;
  multiline?: boolean;
  /** Borderless, for a note sitting inside its own card. */
  bare?: boolean;
  /** Taller white field with a stronger border, used inside sheets. */
  sheet?: boolean;
  autoCapitalize?: 'none' | 'words' | 'sentences';
  keyboardType?: 'default' | 'email-address';
}

export function Field({
  value,
  onChangeText,
  placeholder,
  accessibilityLabel,
  multiline = false,
  bare = false,
  sheet = false,
  autoCapitalize = 'sentences',
  keyboardType = 'default',
}: FieldProps) {
  return (
    <TextInput
      value={value}
      onChangeText={onChangeText}
      placeholder={placeholder}
      placeholderTextColor={color.ink4}
      multiline={multiline}
      autoCapitalize={autoCapitalize}
      keyboardType={keyboardType}
      accessibilityLabel={accessibilityLabel}
      style={[
        styles.input,
        bare ? styles.bare : sheet ? styles.sheet : styles.inline,
        multiline && styles.multiline,
      ]}
    />
  );
}

const styles = StyleSheet.create({
  input: { ...type.input, color: color.ink },
  inline: {
    height: sizes.inlineInputHeight,
    paddingHorizontal: 14,
    borderRadius: radii.inlineInput,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.paper,
  },
  sheet: {
    height: sizes.sheetInputHeight,
    paddingHorizontal: 16,
    borderRadius: radii.sheetInput,
    borderWidth: 1.5,
    borderColor: color.line2,
    backgroundColor: color.white,
  },
  bare: { paddingHorizontal: 0, backgroundColor: 'transparent' },
  multiline: { height: undefined, minHeight: 44, textAlignVertical: 'top', paddingTop: 10 },
});
