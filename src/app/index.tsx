import { Redirect, useRouter } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import {
  Button,
  Card,
  CareCheck,
  ChipGroup,
  Field,
  MealRow,
  ObservationRow,
  PhotoTile,
  Screen,
  SectionHeading,
} from '@/components';
import { deletePhoto, pickPhoto } from '@/data/photos';
import type { PhotoSource } from '@/data/photos';
import { longLabel, relativeLabel, today, yesterday } from '@/domain/dates';
import { ALERT_APPETITES, ALERT_MOODS, ALERT_SLEEPS, SLEEP_CAN_ALERT } from '@/domain/rules';
import type { Meal, MealState } from '@/domain/types';
import { APPETITES, CONCERNS, MEALS, MEAL_STATES, MOODS, SLEEPS } from '@/domain/types';
import { useCheckInForm } from '@/state/checkInForm';
import { useSession } from '@/state/session';
import { color, radius, space, type } from '@/theme/tokens';

const MEAL_LABEL: Record<Meal, string> = {
  breakfast: 'Breakfast',
  lunch: 'Lunch',
  dinner: 'Dinner',
};

/** Short enough for three chips beside a meal name on a narrow phone. */
const MEAL_STATE_LABEL: Record<MealState, string> = {
  none: 'None',
  partial: 'Some',
  full: 'All',
};

export default function CareReportScreen() {
  const { caregiver, resident, ready } = useSession();

  if (!ready) {
    return (
      <View style={styles.centered}>
        <ActivityIndicator color={color.purple} />
      </View>
    );
  }

  if (!caregiver || !resident) {
    return <Redirect href="/setup" />;
  }

  return <CareReport />;
}

/**
 * Split out so the form hook only runs once a resident exists. Calling it above the
 * redirect would mean loading a day for a resident that is not there yet.
 */
function CareReport() {
  const router = useRouter();
  const { caregiver, resident } = useSession();
  const [photoBusy, setPhotoBusy] = useState(false);

  // Guarded by the caller, but narrowing has to happen for the compiler too.
  if (!caregiver || !resident) return null;

  const form = useCheckInForm({
    residentId: resident.id,
    caregiverId: caregiver.id,
    baseline: resident.baseline,
  });
  const { draft, dispatch } = form;
  const onToday = draft.careDate === today();

  async function handlePickPhoto(source: PhotoSource) {
    setPhotoBusy(true);
    try {
      const uri = await pickPhoto(source);
      if (uri) dispatch({ type: 'setPhoto', uri });
    } finally {
      setPhotoBusy(false);
    }
  }

  function handleRemovePhoto() {
    if (draft.photoUri) deletePhoto(draft.photoUri);
    dispatch({ type: 'setPhoto', uri: null });
  }

  async function handleSave() {
    const saved = await form.save();
    if (saved) router.push({ pathname: '/summary', params: { checkInId: saved.id } });
  }

  return (
    <Screen
      footer={
        <Button
          label={form.editingExisting ? 'Update daily care' : 'Save daily care'}
          onPress={handleSave}
          busy={form.saving}
          disabled={form.loading}
        />
      }
    >
      <View style={styles.header}>
        <View style={styles.avatar}>
          <Text style={styles.avatarLetter}>{caregiver.displayName.charAt(0).toUpperCase()}</Text>
        </View>
        <View style={styles.badge}>
          <Text style={styles.badgeText}>Caregiver</Text>
        </View>
      </View>

      <View>
        <Text style={styles.title}>Daily Care Information</Text>
        <Text style={styles.subtitle}>Caregiver to family</Text>
      </View>

      {/* Which resident, and which day. Today unless someone deliberately steps back. */}
      <View style={styles.dayRow}>
        <Text style={styles.residentName}>{resident.displayName}</Text>
        <Text style={styles.dot}>·</Text>
        <Text style={styles.dayLabel}>
          {onToday ? longLabel(draft.careDate) : relativeLabel(draft.careDate)}
        </Text>
        <Pressable
          onPress={() => form.selectDate(onToday ? yesterday() : today())}
          hitSlop={16}
          accessibilityRole="button"
          accessibilityLabel={onToday ? 'Log yesterday instead' : 'Back to today'}
          style={({ pressed }) => [styles.dayAction, pressed && styles.pressed]}
        >
          <Text style={styles.dayActionText}>{onToday ? 'Yesterday' : 'Today'}</Text>
        </Pressable>
      </View>

      <Card title="Meals">
        {MEALS.map((meal) => (
          <MealRow
            key={meal}
            label={MEAL_LABEL[meal]}
            options={MEAL_STATES}
            value={draft.meals[meal]}
            onChange={(state) => dispatch({ type: 'setMeal', meal, state })}
            formatLabel={(state) => MEAL_STATE_LABEL[state]}
          />
        ))}
      </Card>

      <Card title="Medication">
        <CareCheck
          label="A.M"
          checked={draft.medication.am}
          onChange={() => dispatch({ type: 'toggleMedication', slot: 'am' })}
        />
        <CareCheck
          label="P.M"
          checked={draft.medication.pm}
          onChange={() => dispatch({ type: 'toggleMedication', slot: 'pm' })}
        />
        <SupplementalMed
          value={draft.supplementalMedication}
          onChange={(value) => dispatch({ type: 'setSupplementalMedication', value })}
        />
      </Card>

      <Card title="Hygiene">
        <CareCheck
          label="Shower"
          checked={draft.hygiene.shower}
          onChange={() => dispatch({ type: 'toggleHygiene', task: 'shower' })}
        />
        <CareCheck
          label="Grooming"
          checked={draft.hygiene.grooming}
          onChange={() => dispatch({ type: 'toggleHygiene', task: 'grooming' })}
        />
      </Card>

      <SectionHeading
        title="Anything different today?"
        hint="Most days stay the same. Just tap what changed."
      />
      <Card>
        <ObservationRow
          label="Mood"
          options={MOODS}
          value={draft.mood}
          baseline={resident.baseline.mood}
          onChange={(value) => dispatch({ type: 'setMood', value })}
          alertValues={ALERT_MOODS}
        />
        <ObservationRow
          label="Appetite"
          options={APPETITES}
          value={draft.appetite}
          baseline={resident.baseline.appetite}
          onChange={(value) => dispatch({ type: 'setAppetite', value })}
          alertValues={ALERT_APPETITES}
        />
        <ObservationRow
          label="Sleep last night"
          options={SLEEPS}
          value={draft.sleep}
          baseline={resident.baseline.sleep}
          onChange={(value) => dispatch({ type: 'setSleep', value })}
          alertValues={SLEEP_CAN_ALERT ? ALERT_SLEEPS : []}
        />
        <Text style={styles.flagLabel}>Flag a concern</Text>
        <ChipGroup
          options={CONCERNS}
          selected={draft.concerns}
          onToggle={(concern) => dispatch({ type: 'toggleConcern', concern })}
          alertAll
        />
      </Card>

      <PhotoTile
        uri={draft.photoUri}
        onCapture={() => handlePickPhoto('camera')}
        onChoose={() => handlePickPhoto('library')}
        onRemove={handleRemovePhoto}
        busy={photoBusy}
      />

      <Card title="Note for the family">
        <Field
          value={draft.note}
          onChangeText={(value) => dispatch({ type: 'setNote', value })}
          placeholder="Add anything worth mentioning…"
          accessibilityLabel="Note for the family"
          multiline
          bare
        />
      </Card>
    </Screen>
  );
}

/**
 * Supplemental medication stays folded away until it is needed.
 *
 * Most days there isn't one, and an always-open field reads as something left blank
 * rather than something that didn't happen.
 */
function SupplementalMed({
  value,
  onChange,
}: {
  value: string;
  onChange: (value: string) => void;
}) {
  const [open, setOpen] = useState(value.length > 0);

  if (!open) {
    return (
      <Pressable
        onPress={() => setOpen(true)}
        accessibilityRole="button"
        accessibilityLabel="Add supplemental med"
        style={({ pressed }) => [styles.suppTrigger, pressed && styles.pressed]}
      >
        <View style={styles.suppPlus}>
          <Text style={styles.suppPlusMark}>+</Text>
        </View>
        <Text style={styles.suppTriggerText}>
          Add supplemental med <Text style={styles.suppOptional}>(optional)</Text>
        </Text>
      </Pressable>
    );
  }

  return (
    <View style={styles.suppOpen}>
      <View style={styles.suppHead}>
        <Text style={styles.suppLabel}>Supplemental med given</Text>
        <Pressable
          onPress={() => {
            onChange('');
            setOpen(false);
          }}
          hitSlop={12}
          accessibilityRole="button"
          accessibilityLabel="Remove supplemental med"
        >
          <Text style={styles.suppRemove}>Remove</Text>
        </Pressable>
      </View>
      <Field
        value={value}
        onChangeText={onChange}
        placeholder="e.g. Tylenol 500mg for headache"
        accessibilityLabel="Supplemental med given"
      />
    </View>
  );
}

const styles = StyleSheet.create({
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: color.paperDeep,
  },

  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  avatar: {
    width: 44,
    height: 44,
    borderRadius: radius.pill,
    backgroundColor: color.honeySoft,
    alignItems: 'center',
    justifyContent: 'center',
  },
  avatarLetter: { ...type.button, color: color.clay },
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: space.md,
    paddingVertical: 6,
    borderRadius: radius.pill,
    backgroundColor: color.claySoft,
  },
  badgeText: { ...type.marker, color: color.clay, letterSpacing: 1 },

  title: { ...type.display, color: color.ink },
  subtitle: { ...type.bodySmall, color: color.inkSoft, marginTop: space.xs },

  dayRow: { flexDirection: 'row', alignItems: 'center', gap: space.sm },
  residentName: { ...type.body, fontFamily: type.fieldLabel.fontFamily, color: color.ink },
  dot: { ...type.body, color: color.inkFaint },
  dayLabel: { ...type.bodySmall, color: color.inkSoft, flex: 1 },
  dayAction: {
    paddingHorizontal: space.md,
    paddingVertical: 6,
    borderRadius: radius.pill,
    backgroundColor: color.purpleSoft,
  },
  dayActionText: { ...type.caption, color: color.purpleDeep },
  pressed: { opacity: 0.7 },

  flagLabel: { ...type.fieldLabel, color: color.inkMuted, marginBottom: 10 },

  suppTrigger: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    marginTop: 10,
    paddingTop: space.md,
    borderTopWidth: 1,
    borderTopColor: color.line,
  },
  suppPlus: {
    width: 22,
    height: 22,
    borderRadius: 7,
    borderWidth: 1.5,
    borderStyle: 'dashed',
    borderColor: color.lineStrong,
    alignItems: 'center',
    justifyContent: 'center',
  },
  suppPlusMark: { ...type.caption, color: color.inkSoft, lineHeight: 16 },
  suppTriggerText: { ...type.body, color: color.inkSoft },
  suppOptional: { color: color.inkFaint },

  suppOpen: { marginTop: 10, paddingTop: space.md, borderTopWidth: 1, borderTopColor: color.line, gap: space.sm },
  suppHead: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  suppLabel: { ...type.fieldLabel, color: color.inkMuted },
  suppRemove: { ...type.caption, color: color.inkSoft },
});
