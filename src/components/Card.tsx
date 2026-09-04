import type { ReactNode } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { color, radii, type } from "@/theme/tokens";

interface CardProps {
  children: ReactNode;
  /** Serif heading inside the card, the way every card in the reference opens. */
  title?: string;
}

/** White card on the paper surface, hairline border, radius 22. No elevation. */
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
    backgroundColor: color.white,
    borderRadius: radii.card,
    borderWidth: 1,
    borderColor: color.line,
    paddingVertical: 14,
    paddingHorizontal: 18,
  },
  title: { ...type.cardTitle, color: color.ink, marginBottom: 2 },
});
