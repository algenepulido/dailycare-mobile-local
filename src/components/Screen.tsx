import type { ReactNode } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { color, space } from '@/theme/tokens';

interface ScreenProps {
  children: ReactNode;
  /** Scrolls by default. Turn off for screens that must not move, such as a camera view. */
  scroll?: boolean;
  /** Pinned to the bottom, outside the scrolling area. Use for a primary action. */
  footer?: ReactNode;
}

/**
 * Every screen starts here, so background, safe area and horizontal rhythm are decided
 * in one place rather than repeated per screen.
 */
export function Screen({ children, scroll = true, footer }: ScreenProps) {
  const body = scroll ? (
    <ScrollView
      contentContainerStyle={styles.content}
      keyboardShouldPersistTaps="handled"
      showsVerticalScrollIndicator={false}
    >
      {children}
    </ScrollView>
  ) : (
    <View style={styles.content}>{children}</View>
  );

  return (
    <SafeAreaView style={styles.safe} edges={['top', 'left', 'right']}>
      {body}
      {footer ? <View style={styles.footer}>{footer}</View> : null}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: {
    flex: 1,
    backgroundColor: color.paperDeep,
  },
  content: {
    flexGrow: 1,
    paddingHorizontal: space.xl,
    paddingTop: space.md,
    paddingBottom: space.xxl,
    gap: space.sm,
  },
  footer: {
    paddingHorizontal: space.xl,
    paddingTop: space.md,
    paddingBottom: space.xl,
    backgroundColor: color.paperDeep,
  },
});
