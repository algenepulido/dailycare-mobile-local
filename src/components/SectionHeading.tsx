import { StyleSheet, Text, View } from 'react-native';

import { color, type } from "@/theme/tokens";

interface SectionHeadingProps {
  title: string;
  /** One line under the heading, setting expectations before the controls. */
  hint?: string;
}

/** A serif heading standing above a card, not inside one. */
export function SectionHeading({ title, hint }: SectionHeadingProps) {
  return (
    <View style={styles.wrap}>
      <Text style={styles.title} accessibilityRole="header">
        {title}
      </Text>
      {hint ? <Text style={styles.hint}>{hint}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { gap: 4 },
  title: { ...type.sectionHeading, color: color.ink },
  hint: { ...type.meta },
});
