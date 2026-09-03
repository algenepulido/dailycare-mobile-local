import type { ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';

import { color, radius, shadow, space } from '@/theme/tokens';

interface CardProps {
  children: ReactNode;
  /** Removes the inner padding when the card holds its own edge-to-edge rows. */
  flush?: boolean;
}

/** A white surface on the cream ground. The only container that carries elevation. */
export function Card({ children, flush = false }: CardProps) {
  return <View style={[styles.card, flush && styles.flush]}>{children}</View>;
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: color.surface,
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: color.line,
    padding: space.lg,
    gap: space.md,
    ...shadow.card,
  },
  flush: { padding: 0 },
});
