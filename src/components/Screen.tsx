import type { ReactNode } from 'react';
import { ScrollView, StyleSheet, View } from 'react-native';
import type { ScrollViewProps } from 'react-native';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';

import { useKeyboardHeight } from '@/hooks/useKeyboardHeight';
import { color, sizes } from "@/theme/tokens";

interface ScreenProps {
  children: ReactNode;
  scroll?: boolean;
  /** Pinned to the bottom, clear of the scrolling content. */
  footer?: ReactNode;
  /**
   * Pull to refresh, for a screen whose content is the server's rather than the phone's.
   *
   * Here rather than in the screen because there can only be one scrolling container: a
   * screen that passed scroll={false} and brought its own ScrollView left the inner one
   * unbounded, so it grew past the bottom and took the footer with it. Found on a device -
   * the family screen rendered perfectly and had no way to sign out.
   */
  refreshControl?: ScrollViewProps['refreshControl'];
}

/** Paper surface, 22pt gutters, and enough bottom padding to clear the fixed action. */
export function Screen({ children, scroll = true, footer, refreshControl }: ScreenProps) {
  const insets = useSafeAreaInsets();
  const keyboardInset = useKeyboardHeight();
  // Same edge-to-edge correction the sheet makes: the IME height excludes the nav inset.
  const keyboard = keyboardInset > 0 ? keyboardInset + insets.bottom : 0;

  const body = scroll ? (
    <ScrollView
      contentContainerStyle={[styles.content, keyboard > 0 && { paddingBottom: keyboard }]}
      keyboardShouldPersistTaps="handled"
      showsVerticalScrollIndicator={false}
      refreshControl={refreshControl}
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
