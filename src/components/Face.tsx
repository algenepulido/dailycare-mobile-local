import { Image, StyleSheet, Text, View } from 'react-native';

import { color, radii, type } from '@/theme/tokens';

interface FaceProps {
  /** The name the initial comes from, and what a screen reader is told. */
  name: string;
  /** A signed link, or null while there is none and null when there never was one. */
  url?: string | null;
  size: number;
}

/**
 * Somebody's face, or the first letter of their name.
 *
 * One component because the choice between the two is one decision, and it was about to
 * be made in three places with three different ideas of what counts as having a
 * photograph. A link that has not arrived yet, a link that expired while the screen was
 * open, and a resident nobody has photographed all look the same from here: the initial.
 *
 * The letter is not a placeholder waiting to be replaced. Most residents will not have a
 * photograph for a while, and a grey silhouette on every card says the app is missing
 * something. A letter in a warm circle does not.
 */
export function Face({ name, url, size }: FaceProps) {
  const letter = name.trim().charAt(0).toUpperCase() || '?';
  return (
    <View
      style={[styles.frame, { width: size, height: size, borderRadius: radii.chip }]}
      accessibilityRole="image"
      accessibilityLabel={url ? `Photograph of ${name}` : name}
    >
      {url ? (
        // Square and centre cropped, which is what was asked for and what makes a row of
        // these line up. The frame clips it, so a portrait and a landscape both come out
        // as the same circle-cornered square.
        <Image source={{ uri: url }} style={styles.image} resizeMode="cover" />
      ) : (
        <Text style={[styles.letter, { fontSize: Math.round(size * 0.38) }]}>{letter}</Text>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  frame: {
    backgroundColor: color.honeySoft,
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  image: { width: '100%', height: '100%' },
  letter: { fontFamily: type.buttonPrimary.fontFamily, color: color.ink2 },
});
