import { Pressable, StyleSheet, Text, View } from 'react-native';

import { color, control, radius, space, type } from '@/theme/tokens';

type Layout = 'wrap' | 'segmented';

interface BaseProps<T extends string> {
  options: readonly T[];
  /** 'wrap' flows chips onto as many lines as needed. 'segmented' splits one row evenly. */
  layout?: Layout;
  /** Options that should read as needing attention once chosen. */
  alertValues?: readonly T[];
  /** Turns a stored value into what the caregiver reads. Defaults to the value itself. */
  formatLabel?: (option: T) => string;
  /** Sits under the group. Used for the resident's baseline, as "usually Calm". */
  hint?: string;
  disabled?: boolean;
}

interface SingleSelectProps<T extends string> extends BaseProps<T> {
  multiple?: false;
  value: T | null;
  onChange: (value: T) => void;
}

interface MultiSelectProps<T extends string> extends BaseProps<T> {
  multiple: true;
  value: readonly T[];
  /** Fires with the option that was tapped. The caller decides how to add or remove it. */
  onChange: (value: T) => void;
}

export type ChoiceGroupProps<T extends string> = SingleSelectProps<T> | MultiSelectProps<T>;

/**
 * One control for every set of options in the check-in.
 *
 * Single select carries mood, appetite and sleep. Multi select carries concerns. The
 * segmented layout carries the three meal states. Keeping them one component means a
 * change to how a choice looks lands everywhere at once.
 */
export function ChoiceGroup<T extends string>(props: ChoiceGroupProps<T>) {
  const {
    options,
    layout = 'wrap',
    alertValues = [],
    formatLabel = (option: T) => option,
    hint,
    disabled = false,
  } = props;

  const isSelected = (option: T): boolean =>
    props.multiple ? props.value.includes(option) : props.value === option;

  return (
    <View style={styles.container}>
      <View style={layout === 'segmented' ? styles.segmented : styles.wrap}>
        {options.map((option) => {
          const selected = isSelected(option);
          const alert = selected && alertValues.includes(option);

          return (
            <Pressable
              key={option}
              onPress={() => props.onChange(option)}
              disabled={disabled}
              hitSlop={control.hitSlop}
              accessibilityRole={props.multiple ? 'checkbox' : 'radio'}
              accessibilityState={{ selected, checked: selected, disabled }}
              accessibilityLabel={formatLabel(option)}
              style={({ pressed }) => [
                styles.option,
                layout === 'segmented' && styles.optionSegmented,
                selected && styles.optionSelected,
                alert && styles.optionAlert,
                disabled && styles.optionDisabled,
                pressed && styles.optionPressed,
              ]}
            >
              <Text
                numberOfLines={1}
                style={[styles.text, selected && styles.textSelected, alert && styles.textAlert]}
              >
                {formatLabel(option)}
              </Text>
            </Pressable>
          );
        })}
      </View>
      {hint ? <Text style={styles.hint}>{hint}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { gap: space.sm },
  wrap: { flexDirection: 'row', flexWrap: 'wrap', gap: space.sm },
  segmented: { flexDirection: 'row', gap: space.xs },
  option: {
    minHeight: control.heightSmall,
    justifyContent: 'center',
    paddingHorizontal: space.md,
    paddingVertical: space.sm,
    borderRadius: radius.pill,
    borderWidth: 1,
    borderColor: color.lineStrong,
    backgroundColor: color.surface,
  },
  optionSegmented: { flex: 1, alignItems: 'center', paddingHorizontal: space.sm },
  optionSelected: { backgroundColor: color.ink, borderColor: color.ink },
  optionAlert: { backgroundColor: color.alertSoft, borderColor: color.alert },
  optionDisabled: { opacity: 0.4 },
  optionPressed: { opacity: 0.7 },
  text: { ...type.bodySmall, color: color.inkMuted },
  textSelected: { color: color.paper, fontWeight: '600' },
  textAlert: { color: color.alert, fontWeight: '600' },
  hint: { ...type.caption, color: color.inkFaint },
});
