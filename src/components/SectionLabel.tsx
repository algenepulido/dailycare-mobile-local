import { StyleSheet, Text, View } from 'react-native';

import { color, space, type } from '@/theme/tokens';

interface SectionLabelProps {
  children: string;
  /** Right-aligned counter, as in "2/3 done". */
  trailing?: string;
}

/**
 * The small uppercase heading that opens a section, matching the register the daily
 * summary already uses for "WHAT CHANGED TODAY" and "CARE CHECKLIST".
 */
export function SectionLabel({ children, trailing }: SectionLabelProps) {
  return (
    <View style={styles.row}>
      <Text style={styles.label} accessibilityRole="header">
        {children}
      </Text>
      {trailing ? <Text style={styles.trailing}>{trailing}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'baseline',
    justifyContent: 'space-between',
    gap: space.sm,
  },
  label: { ...type.label, color: color.inkFaint },
  trailing: { ...type.caption, color: color.inkFaint },
});
