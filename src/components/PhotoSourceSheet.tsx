import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { PhotoSource } from '@/data/photos';
import { color, radii, sizes, type } from '@/theme/tokens';

import { Sheet } from './Sheet';

interface PhotoSourceSheetProps {
  open: boolean;
  onPick: (source: PhotoSource) => void;
  onClose: () => void;
}

/**
 * Where the photo comes from, asked only once the caregiver has said they want one.
 *
 * Android has no system action sheet, so this is the platform's own equivalent — the
 * same bottom sheet the rest of the app uses. iOS never renders this; it gets
 * ActionSheetIOS instead. Both are text-only, which is what the iOS sheet allows and
 * what keeps this inside an icon set that has no gallery glyph.
 */
export function PhotoSourceSheet({ open, onPick, onClose }: PhotoSourceSheetProps) {
  return (
    <Sheet open={open} onClose={onClose}>
      <Text style={styles.title}>Add a photo</Text>
      <Row label="Camera" onPress={() => onPick('camera')} />
      <Row label="Photo Library" onPress={() => onPick('library')} />
      <Row label="Cancel" onPress={onClose} muted />
    </Sheet>
  );
}

function Row({
  label,
  onPress,
  muted = false,
}: {
  label: string;
  onPress: () => void;
  muted?: boolean;
}) {
  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={label}
      style={({ pressed }) => [styles.row, pressed && styles.pressed]}
    >
      <Text style={[styles.rowLabel, muted && styles.rowLabelMuted]}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  title: { ...type.sheetTitle, color: color.ink, marginBottom: 14 },
  row: {
    height: sizes.pillButtonHeight,
    justifyContent: 'center',
    paddingHorizontal: 18,
    marginBottom: 8,
    borderRadius: radii.sheetInput,
    borderWidth: 1,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  pressed: { opacity: 0.75 },
  rowLabel: { ...type.buttonPrimary, color: color.ink },
  rowLabelMuted: { color: color.ink3 },
});
