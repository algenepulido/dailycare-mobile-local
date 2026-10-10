import { useFonts } from 'expo-font';
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { SessionProvider } from '@/state/session';
import { color, fontAssets } from '@/theme/tokens';

/**
 * The names sheet and the review sheet are sheets over the day, not routes,
 * so the report stays visible underneath and closing puts something down rather than
 * navigating away. History is a route because it is somewhere you go and come back from,
 * and because a sheet that scrolls three weeks is a screen wearing a sheet's clothes. The
 * photo gallery is a route for the same two reasons; the one photograph it opens large is a
 * modal, because that is a closer look at something already on the screen.
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
          <Stack.Screen name="history" />
          <Stack.Screen name="residents" />
          <Stack.Screen name="family" />
          <Stack.Screen name="photos" />
        </Stack>
      </SessionProvider>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  loading: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: color.paper },
});
