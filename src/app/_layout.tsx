import { useFonts } from 'expo-font';
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { SessionProvider } from '@/state/session';
import { color, fontAssets } from '@/theme/tokens';

/**
 * One screen. The names sheet and the review sheet are sheets over it, not routes, so
 * the report stays visible underneath and closing puts something down rather than
 * navigating away.
 */
export default function RootLayout() {
  const [fontsReady] = useFonts(fontAssets);

  // Rendering before the faces load shows a system fallback and then reflows every
  // heading, which is worse than a moment of nothing.
  if (!fontsReady) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator color={color.clay} />
      </View>
    );
  }

  return (
    <SafeAreaProvider>
      <SessionProvider>
        <StatusBar style="dark" />
        <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: color.paper } }}>
          <Stack.Screen name="index" />
        </Stack>
      </SessionProvider>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  loading: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: color.paper },
});
