import type { ReactNode } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { useKeyboardHeight } from '@/hooks/useKeyboardHeight';
import { color, sizes } from "@/theme/tokens";

interface ScreenProps {
  children: ReactNode;
  scroll?: boolean;
  /** Pinned to the bottom, clear of the scrolling content. */
  footer?: ReactNode;
}

/** Paper surface, 22pt gutters, and enough bottom padding to clear the fixed action. */
export function Screen({ children, scroll = true, footer }: ScreenProps) {
  const keyboard = useKeyboardHeight();

  const body = scroll ? (
    <ScrollView
      contentContainerStyle={[styles.content, keyboard > 0 && { paddingBottom: keyboard }]}
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
      {footer ? (
        <View style={[styles.footer, keyboard > 0 && { paddingBottom: keyboard + 14 }]}>
          {footer}
        </View>
      ) : null}
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: color.paper },
  content: {
    flexGrow: 1,
    paddingHorizontal: sizes.screenPaddingH,
    paddingTop: 14,
    paddingBottom: sizes.scrollBottomPadding,
    gap: sizes.cardGap,
  },
  footer: {
    paddingHorizontal: sizes.screenPaddingH,
    paddingTop: 14,
    paddingBottom: 30,
    backgroundColor: color.paper,
  },
});
