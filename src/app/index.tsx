import { StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { color, space, type } from '@/theme/tokens';

export default function Home() {
  return (
    <SafeAreaView style={styles.screen}>
      <View style={styles.body}>
        <Text style={styles.eyebrow}>Caregiver</Text>
        <Text style={styles.title}>DailyCare</Text>
        <Text style={styles.lede}>Setup and the daily check-in land here next.</Text>
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: color.paper },
  body: { flex: 1, paddingHorizontal: space.xl, paddingTop: space.xxl, gap: space.sm },
  eyebrow: { ...type.label, color: color.clay },
  title: { ...type.display, color: color.ink },
  lede: { ...type.body, color: color.inkSoft },
});
