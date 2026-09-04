import type { ReactNode } from 'react';
import { useEffect, useRef } from 'react';
import {
  Animated,
  Easing,
  Modal,
  Pressable,
  StyleSheet,
  View,
  useWindowDimensions,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useKeyboardHeight } from '@/hooks/useKeyboardHeight';
import { color, motion, radii, sizes } from '@/theme/tokens';

interface SheetProps {
  open: boolean;
  onClose: () => void;
  children: ReactNode;
  /** Caps the sheet at a share of the screen. The review sheet uses 0.9. */
  maxHeightRatio?: number;
  /** Pinned under the scrolling body. */
  footer?: ReactNode;
}

/**
 * A bottom sheet, the way the web app does it.
 *
 * Both of this app's secondary surfaces are sheets rather than screens — that is what
 * keeps the report underneath visible and makes closing feel like putting something
 * down rather than navigating away.
 */
export function Sheet({ open, onClose, children, maxHeightRatio = 0.9, footer }: SheetProps) {
  const { height } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const translate = useRef(new Animated.Value(height)).current;
  /**
   * The IME reports its height against the content area, which stops above the system
   * navigation bar — but this sheet is laid out edge to edge, from the bottom of the
   * screen. Lifting by the reported height alone leaves the footer short by exactly the
   * navigation inset, which is enough to clip the bottom of the primary action.
   */
  const keyboardInset = useKeyboardHeight();
  const keyboard = keyboardInset > 0 ? keyboardInset + insets.bottom : 0;

  useEffect(() => {
    if (!open) return;
    translate.setValue(height);
    Animated.timing(translate, {
      toValue: 0,
      duration: motion.sheet.durationMs,
      easing: Easing.bezier(...motion.sheet.easing),
      useNativeDriver: true,
    }).start();
  }, [open, height, translate]);

  return (
    <Modal visible={open} transparent animationType="none" onRequestClose={onClose}>
      <View style={styles.root}>
        <Pressable
          style={styles.scrim}
          onPress={onClose}
          accessibilityRole="button"
          accessibilityLabel="Close"
        />
        <Animated.View
          style={[
            styles.sheet,
            {
              maxHeight: height * maxHeightRatio - keyboard,
              marginBottom: keyboard,
              transform: [{ translateY: translate }],
            },
          ]}
        >
          <View style={styles.handle} />
          <View style={styles.body}>{children}</View>
          {footer ? (
            <View
              style={[
                styles.footer,
                { paddingBottom: keyboard > 0 ? 14 : Math.max(insets.bottom, 22) },
              ]}
            >
              {footer}
            </View>
          ) : (
            <View style={{ height: keyboard > 0 ? 8 : Math.max(insets.bottom, 12) }} />
          )}
        </Animated.View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, justifyContent: 'flex-end' },
  scrim: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: color.scrim,
  },
  sheet: {
    backgroundColor: color.paper,
    borderTopLeftRadius: radii.sheetTop,
    borderTopRightRadius: radii.sheetTop,
    shadowColor: color.ink,
    shadowOpacity: 0.2,
    shadowRadius: 40,
    shadowOffset: { width: 0, height: -12 },
    elevation: 24,
  },
  handle: {
    width: sizes.grabHandle.width,
    height: sizes.grabHandle.height,
    borderRadius: 2,
    backgroundColor: color.line2,
    alignSelf: 'center',
    marginTop: 12,
  },
  body: { paddingHorizontal: sizes.screenPaddingH, paddingTop: 14, flexShrink: 1 },
  footer: { paddingHorizontal: sizes.screenPaddingH, paddingTop: 12 },
});
