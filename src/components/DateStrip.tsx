import { useEffect, useRef } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import { dayNumberLabel, weekdayLabel } from '@/domain/dates';
import { color, control, radius, space, type } from '@/theme/tokens';

interface DateStripProps {
  /** Care dates, most recent first. */
  dates: readonly string[];
  value: string;
  onChange: (careDate: string) => void;
  /** Dates that already have an entry filed, so a caregiver can see the gaps. */
  filed?: readonly string[];
}

/**
 * A horizontal run of days rather than a date picker.
 *
 * The window is only two weeks, so every day a caregiver can file against fits on one
 * strip. That is one tap instead of opening a picker, and it shows at a glance which
 * days are still missing an entry.
 */
export function DateStrip({ dates, value, onChange, filed = [] }: DateStripProps) {
  const scrollRef = useRef<ScrollView>(null);

  useEffect(() => {
    scrollRef.current?.scrollTo({ x: 0, animated: false });
  }, []);

  return (
    <ScrollView
      ref={scrollRef}
      horizontal
      showsHorizontalScrollIndicator={false}
      contentContainerStyle={styles.strip}
    >
      {dates.map((careDate) => {
        const selected = careDate === value;
        const hasEntry = filed.includes(careDate);

        return (
          <Pressable
            key={careDate}
            onPress={() => onChange(careDate)}
            hitSlop={control.hitSlop}
            accessibilityRole="button"
            accessibilityState={{ selected }}
            accessibilityLabel={`${weekdayLabel(careDate)} ${dayNumberLabel(careDate)}${
              hasEntry ? ', already filed' : ''
            }`}
            style={({ pressed }) => [
              styles.day,
              selected && styles.daySelected,
              pressed && styles.dayPressed,
            ]}
          >
            <Text style={[styles.weekday, selected && styles.textSelected]}>
              {weekdayLabel(careDate)}
            </Text>
            <Text style={[styles.number, selected && styles.textSelected]}>
              {dayNumberLabel(careDate)}
            </Text>
            {/* The dot means "this day already has an entry", so it is only painted when
                there is one. Selection decides its colour, not whether it shows. */}
            <View
              style={[styles.dot, hasEntry && (selected ? styles.dotOnSelected : styles.dotFiled)]}
            />
          </Pressable>
        );
      })}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  strip: { gap: space.sm, paddingVertical: space.xs },
  day: {
    width: 54,
    paddingVertical: space.sm,
    alignItems: 'center',
    gap: space.xs,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: color.lineStrong,
    backgroundColor: color.surface,
  },
  daySelected: { backgroundColor: color.ink, borderColor: color.ink },
  dayPressed: { opacity: 0.7 },
  weekday: { ...type.caption, color: color.inkFaint, fontSize: 11 },
  number: { ...type.heading, color: color.ink },
  textSelected: { color: color.paper },
  dot: { width: 5, height: 5, borderRadius: radius.pill, backgroundColor: 'transparent' },
  dotFiled: { backgroundColor: color.sage },
  dotOnSelected: { backgroundColor: color.paper },
});
