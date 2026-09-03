import { StyleSheet, Text, TextInput, View } from 'react-native';

import { color, control, radius, space, type } from '@/theme/tokens';

interface FieldProps {
  label: string;
  value: string;
  onChangeText: (value: string) => void;
  placeholder?: string;
  /** Grows into a note box instead of a single line. */
  multiline?: boolean;
  autoCapitalize?: 'none' | 'words' | 'sentences';
}

/** Free text entry. Used for supplemental medication and the caregiver's note. */
export function Field({
  label,
  value,
  onChangeText,
  placeholder,
  multiline = false,
  autoCapitalize = 'sentences',
}: FieldProps) {
  return (
    <View style={styles.container}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        value={value}
        onChangeText={onChangeText}
        placeholder={placeholder}
        placeholderTextColor={color.inkFaint}
        multiline={multiline}
        autoCapitalize={autoCapitalize}
        accessibilityLabel={label}
        style={[styles.input, multiline && styles.inputMultiline]}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { gap: space.sm },
  label: { ...type.label, color: color.inkFaint },
  input: {
    ...type.body,
    color: color.ink,
    minHeight: control.height,
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: color.lineStrong,
    backgroundColor: color.surface,
  },
  inputMultiline: { minHeight: 96, textAlignVertical: 'top', paddingTop: space.md },
});
