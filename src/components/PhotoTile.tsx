import { Image } from 'expo-image';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import { color, radii, sizes, type } from '@/theme/tokens';

interface PhotoTileProps {
  uri: string | null;
  onCapture: () => void;
  onChoose: () => void;
  onRemove: () => void;
  busy?: boolean;
  /** Shown under the buttons when a file could not be read. */
  error?: string | null;
}

/**
 * Presentational only. Picking and storing a photo lives in the data layer, so this can
 * be rendered anywhere without pulling the camera in behind it.
 */
export function PhotoTile({ uri, onCapture, onChoose, onRemove, busy = false, error }: PhotoTileProps) {
  if (uri) {
    return (
      <View>
        <View style={styles.attachedRow}>
          <Pressable
            onPress={onChoose}
            disabled={busy}
            accessibilityRole="button"
            accessibilityLabel="Photo attached, tap to replace"
            style={({ pressed }) => [styles.attached, pressed && styles.pressed]}
          >
            <Image source={{ uri }} style={styles.thumb} contentFit="cover" />
            <Text style={styles.attachedText}>Photo attached — tap to replace</Text>
          </Pressable>
          <Pressable
            onPress={onRemove}
            accessibilityRole="button"
            accessibilityLabel="Remove photo"
            style={({ pressed }) => [styles.remove, pressed && styles.pressed]}
          >
            <Text style={styles.removeGlyph}>✕</Text>
          </Pressable>
        </View>
        {error ? <Text style={styles.error}>{error}</Text> : null}
      </View>
    );
  }

  return (
    <View>
      <View style={styles.emptyRow}>
        <Action label="Attach photo" onPress={onCapture} busy={busy} />
        <Action label="Choose one" onPress={onChoose} busy={busy} />
      </View>
      {error ? <Text style={styles.error}>{error}</Text> : null}
    </View>
  );
}

function Action({ label, onPress, busy }: { label: string; onPress: () => void; busy: boolean }) {
  return (
    <Pressable
      onPress={onPress}
      disabled={busy}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled: busy }}
      style={({ pressed }) => [styles.action, pressed && styles.pressed, busy && styles.busy]}
    >
      {busy ? (
        <ActivityIndicator color={color.ink3} />
      ) : (
        <Text style={styles.actionText}>{label}</Text>
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  emptyRow: { flexDirection: 'row', gap: 8 },
  action: {
    flex: 1,
    height: sizes.photoButtonHeight,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radii.photoButton,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  actionText: { ...type.chip, color: color.ink2 },
  busy: { opacity: 0.6 },

  attachedRow: { flexDirection: 'row', gap: 8 },
  attached: {
    flex: 1,
    height: sizes.photoButtonHeightAttached,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingHorizontal: 10,
    borderRadius: radii.photoButton,
    borderWidth: 1.5,
    borderColor: color.sage,
    backgroundColor: color.white,
  },
  thumb: { width: 44, height: 44, borderRadius: radii.photoThumb, backgroundColor: color.paper2 },
  attachedText: { ...type.chip, color: color.sage, flex: 1 },
  remove: {
    width: 52,
    height: sizes.photoButtonHeightAttached,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radii.photoButton,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  removeGlyph: { fontSize: 18, color: color.ink3 },
  pressed: { opacity: 0.75 },

  error: { ...type.fieldLabel, color: color.warn, marginTop: 8 },
});
