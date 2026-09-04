import { useEffect, useState } from 'react';
import { Keyboard } from 'react-native';

/**
 * How much of the screen the keyboard is covering, in points.
 *
 * KeyboardAvoidingView is no help here. The app draws edge to edge, which stopped being
 * optional in Android 15, and an edge-to-edge window is not resized when the IME opens —
 * so the view has nothing to react to, and anything pinned to the bottom stays pinned
 * underneath the keyboard. Measuring the IME directly is the part that works on both
 * platforms, and it is the caller's business what to do with the number.
 */
export function useKeyboardHeight(): number {
  const [height, setHeight] = useState(0);

  useEffect(() => {
    const show = Keyboard.addListener('keyboardDidShow', (event) =>
      setHeight(event.endCoordinates.height),
    );
    const hide = Keyboard.addListener('keyboardDidHide', () => setHeight(0));
    return () => {
      show.remove();
      hide.remove();
    };
  }, []);

  return height;
}
