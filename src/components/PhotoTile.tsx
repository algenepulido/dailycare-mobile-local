import { Image } from 'expo-image';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import { color, radii, sizes, type } from '@/theme/tokens';

import { Icon } from './Icon';

interface PhotoTileProps {
  uri: string | null;
  /** Opens the source choice. Where the photo comes from is asked after this, not before. */
  onAttach: () => void;
  onRemove: () => void;
  /** True while a picked file is being read and copied. */
  busy?: boolean;
  /** Shown under the buttons when a file could not be read. */
  error?: string | null;
}

/**
 * Presentational only. Picking and storing a photo lives in the data layer, so this can
 * be rendered anywhere without pulling the camera in behind it.
 */
export function PhotoTile({ uri, onAttach, onRemove, busy = false, error }: PhotoTileProps) {
  if (busy) {
    return (
      <View>
        <View style={[styles.action, styles.reading]}>
          <ActivityIndicator color={color.ink3} />
          <Text style={styles.actionText}>Reading photo…</Text>
        </View>
        {error ? <Text style={styles.error}>{error}</Text> : null}
      </View>
    );
  }

  if (uri) {
    return (
      <View>
        <View style={styles.row}>
          <Pressable
            onPress={onAttach}
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
            <Icon name="close" size={18} color={color.ink3} />
          </Pressable>
        </View>
        {error ? <Text style={styles.error}>{error}</Text> : null}
      </View>
    );
  }

  return (
    <View>
      <Pressable
        onPress={onAttach}
        accessibilityRole="button"
        accessibilityLabel="Attach photo"
        style={({ pressed }) => [styles.action, pressed && styles.pressed]}
      >
        <Icon name="camera" size={18} color={color.ink2} />
        <Text style={styles.actionText}>Attach photo</Text>
      </Pressable>
      {error ? <Text style={styles.error}>{error}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', gap: 8 },
  action: {
    height: sizes.photoButtonHeight,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    paddingHorizontal: 14,
    borderRadius: radii.photoButton,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  reading: { opacity: 0.7 },
  actionText: { fontFamily: type.chip.fontFamily, fontSize: 14, color: color.ink2 },

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
  attachedText: { fontFamily: type.chip.fontFamily, fontSize: 14, color: color.sage, flex: 1 },
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
  pressed: { opacity: 0.75 },

  /** 13 semibold amber, sitting under the button rather than replacing it. */
  error: { fontFamily: type.fieldLabel.fontFamily, fontSize: 13, color: color.warn, marginTop: 8 },
});
