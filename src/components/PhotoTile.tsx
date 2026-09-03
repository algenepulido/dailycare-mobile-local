import { Image } from 'expo-image';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { color, radius, space, type } from '@/theme/tokens';

interface PhotoTileProps {
  uri: string | null;
  onCapture: () => void;
  onChoose: () => void;
  onRemove: () => void;
  busy?: boolean;
}

/**
 * Presentational only. Picking and storing a photo lives in the data layer, so this
 * component can be rendered anywhere without pulling the camera in behind it.
 */
export function PhotoTile({ uri, onCapture, onChoose, onRemove, busy = false }: PhotoTileProps) {
  if (uri) {
    return (
      <View style={styles.container}>
        <Image source={{ uri }} style={styles.preview} contentFit="cover" transition={150} />
        <Pressable
          onPress={onRemove}
          accessibilityRole="button"
          accessibilityLabel="Remove photo"
          style={({ pressed }) => [styles.remove, pressed && styles.pressed]}
        >
          <Text style={styles.removeText}>Remove photo</Text>
        </Pressable>
      </View>
    );
  }

  return (
    <View style={styles.actions}>
      <Action label="Take a photo" onPress={onCapture} disabled={busy} />
      <Action label="Choose one" onPress={onChoose} disabled={busy} />
    </View>
  );
}

function Action({
  label,
  onPress,
  disabled,
}: {
  label: string;
  onPress: () => void;
  disabled: boolean;
}) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled }}
      style={({ pressed }) => [
        styles.action,
        pressed && styles.pressed,
        disabled && styles.disabled,
      ]}
    >
      <Text style={styles.actionText}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  container: { gap: space.sm },
  preview: {
    width: '100%',
    aspectRatio: 4 / 3,
    borderRadius: radius.md,
    backgroundColor: color.paperDeep,
  },
  actions: { flexDirection: 'row', gap: space.sm },
  action: {
    flex: 1,
    minHeight: 88,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.md,
    borderWidth: 1,
    borderStyle: 'dashed',
    borderColor: color.lineStrong,
    backgroundColor: color.surface,
  },
  actionText: { ...type.bodySmall, color: color.inkSoft, fontWeight: '600' },
  remove: { alignSelf: 'flex-start' },
  removeText: { ...type.caption, color: color.clay, fontWeight: '600' },
  pressed: { opacity: 0.7 },
  disabled: { opacity: 0.4 },
});
