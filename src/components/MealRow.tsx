import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { MealAmount } from '@/domain/types';
import { MEAL_AMOUNTS, MEAL_AMOUNT_LABEL } from '@/domain/types';
import { color, radii, sizes, type } from '@/theme/tokens';

interface MealRowProps {
  label: string;
  done: boolean;
  /** She would not eat it. Never true at the same time as done. */
  refused: boolean;
  amount: MealAmount | null;
  onToggle: (done: boolean) => void;
  /** Tapping it again takes the refusal back, to a meal nobody has written about. */
  onRefuse: (refused: boolean) => void;
  /** Null clears the answer: tapping the chosen amount again takes it back. */
  onAmount: (amount: MealAmount | null) => void;
}

/**
 * A meal, and — only once it happened — how much of it was eaten.
 *
 * The amount is revealed rather than offered up front: on an ordinary day a caregiver
 * ticks three boxes and moves on. It also stays optional, so ticking without answering
 * is a complete record rather than a half-filled one.
 */
export function MealRow({
  label,
  done,
  refused,
  amount,
  onToggle,
  onRefuse,
  onAmount,
}: MealRowProps) {
  return (
    <View>
      <Pressable
        onPress={() => onToggle(!done)}
        accessibilityRole="checkbox"
        accessibilityState={{ checked: done }}
        accessibilityLabel={label}
        style={({ pressed }) => [styles.row, pressed && styles.pressed]}
      >
        <View style={[styles.box, done && styles.boxChecked]}>
          {done ? <Text style={styles.tick}>✓</Text> : null}
        </View>
        <Text style={[styles.label, (done || refused) && styles.labelDone]}>{label}</Text>
        {done && amount ? (
          <View style={styles.badge}>
            <Text style={styles.badgeText}>{MEAL_AMOUNT_LABEL[amount]}</Text>
          </View>
        ) : null}
        {/* The third answer, beside the tick rather than under it.
          *
          * A meal nobody has written about and a meal she turned away are different things,
          * and until now the form could only say the first. It is on the row so that saying
          * it costs one tap, which is what it costs to say she ate it - a caregiver who has
          * to open something to record a refusal records fewer of them. */}
        <Pressable
          onPress={() => onRefuse(!refused)}
          accessibilityRole="button"
          accessibilityState={{ selected: refused }}
          accessibilityLabel={`${label}, would not eat`}
          hitSlop={8}
          style={({ pressed }) => [
            styles.refuse,
            refused && styles.refuseOn,
            pressed && styles.pressed,
          ]}
        >
          <Text style={[styles.refuseText, refused && styles.refuseTextOn]}>Refused</Text>
        </Pressable>
      </Pressable>

      {done ? (
        <View style={styles.detail}>
          <View style={styles.promptRow}>
            <Text style={styles.prompt}>How much did they eat?</Text>
            {/* "not observed" until the design pass settled it. A meal she ate with nobody
              * saying how much is a meal eaten and an amount not recorded, which is the
              * same words the rest of the product uses for a thing nobody wrote down. */}
            {amount ? null : <Text style={styles.unanswered}>not recorded</Text>}
          </View>
          <View style={styles.amounts}>
            {MEAL_AMOUNTS.map((option) => {
              const selected = amount === option;
              return (
                <Pressable
                  key={option}
                  onPress={() => onAmount(selected ? null : option)}
                  accessibilityRole="button"
                  accessibilityState={{ selected }}
                  accessibilityLabel={`${label}, ${MEAL_AMOUNT_LABEL[option]}`}
                  style={({ pressed }) => [
                    styles.amount,
                    selected && styles.amountSelected,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={[styles.amountText, selected && styles.amountTextSelected]}>
                    {MEAL_AMOUNT_LABEL[option]}
                  </Text>
                </Pressable>
              );
            })}
          </View>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'center', gap: 14, paddingVertical: 11 },
  pressed: { opacity: 0.6 },
  box: {
    width: sizes.checkbox,
    height: sizes.checkbox,
    borderRadius: radii.checkbox,
    borderWidth: 2,
    borderColor: color.line2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  boxChecked: { backgroundColor: color.sage, borderColor: color.sage },
  tick: { color: color.white, fontSize: 16, fontWeight: '700', lineHeight: 19 },
  label: { ...type.checklistItem, color: color.ink2, flex: 1 },
  labelDone: { color: color.ink },

  /** Repeats the chosen amount on the row so it reads without expanding anything. */
  badge: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: radii.chip,
    borderWidth: 1,
    borderColor: color.sage,
    backgroundColor: color.sageSoft,
  },
  badgeText: { fontFamily: type.chip.fontFamily, fontSize: 13, color: color.ink },

  /** Reads as an answer rather than as a warning: she turned it down, nothing went wrong. */
  refuse: {
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: radii.chip,
    borderWidth: 1,
    borderColor: color.line2,
    minHeight: sizes.minTouchTarget - 10,
    justifyContent: 'center',
  },
  refuseOn: { backgroundColor: color.claySoft, borderColor: color.clay },
  refuseText: { fontFamily: type.chip.fontFamily, fontSize: 13, color: color.ink3 },
  refuseTextOn: { color: color.ink },

  /** Indented past the checkbox with a hairline rule, so it reads as belonging to the row. */
  promptRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  unanswered: { fontFamily: type.meta.fontFamily, fontSize: 11, color: color.ink4 },
  detail: {
    marginLeft: sizes.checkbox + 14,
    paddingLeft: 14,
    paddingBottom: 12,
    borderLeftWidth: 2,
    borderLeftColor: color.line,
    gap: 10,
  },
  prompt: { fontFamily: type.fieldLabel.fontFamily, fontSize: 12.5, color: color.ink3 },
  amounts: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  amount: {
    height: sizes.minTouchTarget,
    minWidth: 36,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 10,
    borderRadius: radii.chip,
    borderWidth: 1,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  amountSelected: { backgroundColor: color.ink, borderColor: color.ink },
  amountText: { fontFamily: type.chip.fontFamily, fontSize: 14.5, color: color.ink2 },
  amountTextSelected: { color: color.white },
});
