import { useFonts } from 'expo-font';
import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { ActivityIndicator, StyleSheet, View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { SessionProvider } from '@/state/session';
import { color, fontAssets } from '@/theme/tokens';

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
        <Stack
          screenOptions={{
            headerShadowVisible: false,
            headerStyle: { backgroundColor: color.paper },
            headerTintColor: color.ink,
            headerTitleStyle: { color: color.ink },
            contentStyle: { backgroundColor: color.paper },
          }}
        >
          <Stack.Screen name="index" options={{ headerShown: false }} />
          <Stack.Screen name="setup" options={{ headerShown: false }} />
          <Stack.Screen name="summary" options={{ title: 'Preview', presentation: 'modal' }} />
        </Stack>
      </SessionProvider>
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  loading: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: color.paper,
  },
});
