import type { ReactNode } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { color, radius, space, type } from '@/theme/tokens';

interface CardProps {
  children: ReactNode;
  /** Serif heading inside the card, the way every card in the reference opens. */
  title?: string;
}

/** A white card with a hairline border. Flat — the reference carries no elevation. */
export function Card({ children, title }: CardProps) {
  return (
    <View style={styles.card}>
      {title ? <Text style={styles.title}>{title}</Text> : null}
      {children}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: color.surface,
    borderRadius: radius.card,
    borderWidth: 1,
    borderColor: color.line,
    paddingVertical: space.md,
    paddingHorizontal: space.lg,
  },
  title: { ...type.cardTitle, color: color.ink, marginBottom: space.xs },
});
