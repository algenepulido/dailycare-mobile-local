import DateTimePicker from '@react-native-community/datetimepicker';
import { useState } from 'react';
import { Platform, Pressable, StyleSheet, Text, View } from 'react-native';

import { fromCareDate, longLabel, today } from '@/domain/dates';
import { app, color, radii, type } from '@/theme/tokens';

interface CareDateButtonProps {
  careDate: string;
  onChange: (careDate: string) => void;
}

/**
 * The day being logged.
 *
 * Backdating has to exist — a caregiver catching up on last night needs it — but it is
 * not what the screen is about. So it reads as a date you can tap rather than a row of
 * days to browse, and only says anything loud when the entry is not for today.
 */
export function CareDateButton({ careDate, onChange }: CareDateButtonProps) {
  const [open, setOpen] = useState(false);
  const backdated = careDate !== today();

  const earliest = new Date();
  earliest.setDate(earliest.getDate() - (app.backdateLimitDays - 1));

  return (
    <>
      <Pressable
        onPress={() => setOpen(true)}
        hitSlop={12}
        accessibilityRole="button"
        accessibilityLabel={`Care date, ${longLabel(careDate)}. Tap to change.`}
        style={({ pressed }) => [styles.button, pressed && styles.pressed]}
      >
        <Text style={[styles.label, backdated && styles.labelBackdated]}>
          {longLabel(careDate)}
        </Text>
        {backdated ? (
          <View style={styles.pill}>
            <Text style={styles.pillText}>Not today</Text>
          </View>
        ) : null}
      </Pressable>

      {open ? (
        <DateTimePicker
          value={fromCareDate(careDate)}
          mode="date"
          display={Platform.OS === 'ios' ? 'inline' : 'default'}
          minimumDate={earliest}
          maximumDate={new Date()}
          onChange={(event, picked) => {
            setOpen(Platform.OS === 'ios' && event.type !== 'dismissed');
            if (event.type === 'set' && picked) {
              // Build from Y/M/D parts. Parsing an ISO string is UTC and shifts a day
              // west of Greenwich, which would file the entry against the wrong date.
              const year = picked.getFullYear();
              const month = String(picked.getMonth() + 1).padStart(2, '0');
              const day = String(picked.getDate()).padStart(2, '0');
              onChange(`${year}-${month}-${day}`);
            }
          }}
        />
      ) : null}
    </>
  );
}

const styles = StyleSheet.create({
  button: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingVertical: 2 },
  pressed: { opacity: 0.6 },
  label: {
    fontFamily: type.meta.fontFamily,
    fontSize: 14,
    color: color.ink3,
    borderBottomWidth: 1,
    borderBottomColor: color.ink4,
    borderStyle: 'dashed',
  },
  labelBackdated: { fontFamily: type.fieldLabel.fontFamily, color: color.clay },
  pill: {
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: radii.chip,
    backgroundColor: color.claySoft,
  },
  pillText: { ...type.badge, fontSize: 10, letterSpacing: 0.5, color: color.clay },
});
