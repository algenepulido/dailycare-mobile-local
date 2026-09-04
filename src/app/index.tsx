import { Redirect, useRouter } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import {
  Button,
  Card,
  CareCheck,
  CareDateButton,
  ChipGroup,
  MealRow,
  Field,
  ObservationRow,
  PhotoTile,
  Screen,
  SectionHeading,
} from '@/components';
import { PHOTO_READ_ERROR, deletePhoto, pickPhoto } from '@/data/photos';
import type { PhotoSource } from '@/data/photos';
import { ALERT_APPETITES, ALERT_MOODS, ALERT_SLEEPS, SLEEP_CAN_ALERT } from '@/domain/rules';
import type { Meal } from '@/domain/types';
import { APPETITES, CONCERNS, MEALS, MOODS, SLEEPS } from '@/domain/types';
import { useCheckInForm } from '@/state/checkInForm';
import { useSession } from '@/state/session';
import { color, radii, sizes, type } from '@/theme/tokens';

const MEAL_LABEL: Record<Meal, string> = {
  breakfast: 'Breakfast',
  lunch: 'Lunch',
  dinner: 'Dinner',
};

export default function CareReportScreen() {
  const { caregiver, resident, ready } = useSession();

  if (!ready) {
    return (
      <View style={styles.centered}>
        <ActivityIndicator color={color.clay} />
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
  const [photoError, setPhotoError] = useState<string | null>(null);

  // Guarded by the caller, but narrowing has to happen for the compiler too.
  if (!caregiver || !resident) return null;

  const form = useCheckInForm({
    residentId: resident.id,
    caregiverId: caregiver.id,
    baseline: resident.baseline,
  });
  const { draft, dispatch } = form;

  async function handlePickPhoto(source: PhotoSource) {
    setPhotoBusy(true);
    setPhotoError(null);
    try {
      const result = await pickPhoto(source);
      if (result.uri) dispatch({ type: 'setPhoto', uri: result.uri });
      if (result.failed) setPhotoError(PHOTO_READ_ERROR);
    } finally {
      setPhotoBusy(false);
    }
  }

  function handleRemovePhoto() {
    if (draft.photoUri) deletePhoto(draft.photoUri);
    dispatch({ type: 'setPhoto', uri: null });
    setPhotoError(null);
  }

  async function handleReview() {
    const saved = await form.save();
    if (saved) router.push({ pathname: '/summary', params: { checkInId: saved.id } });
  }

  const openNames = () => router.push('/setup');

  return (
    <Screen
      footer={
        <Button
          label="Review summary"
          onPress={handleReview}
          busy={form.saving}
          disabled={form.loading}
        />
      }
    >
      <View style={styles.header}>
        <Pressable
          onPress={openNames}
          accessibilityRole="button"
          accessibilityLabel="Change who is logging"
          style={({ pressed }) => [styles.avatarLarge, pressed && styles.pressed]}
        >
          <Text style={styles.avatarLargeText}>{initials(caregiver.displayName)}</Text>
        </Pressable>
        <View style={styles.badge}>
          <Text style={styles.badgeText}>Caregiver</Text>
        </View>
        <View style={styles.headerSpacer} />
      </View>

      <View>
        <Text style={styles.title}>Daily Care Information</Text>
        <Text style={styles.subtitle}>From {caregiver.displayName}</Text>
      </View>

      <View style={styles.clientRow}>
        <Pressable
          onPress={openNames}
          accessibilityRole="button"
          accessibilityLabel={`Logging for ${resident.displayName}. Tap to change.`}
          style={({ pressed }) => [styles.clientButton, pressed && styles.pressed]}
        >
          <View style={styles.avatarSmall}>
            <Text style={styles.avatarSmallText}>{initials(resident.displayName)}</Text>
          </View>
          <Text style={styles.clientName}>{resident.displayName}</Text>
        </Pressable>
        <Text style={styles.separator}>·</Text>
        <CareDateButton careDate={draft.careDate} onChange={form.selectDate} />
      </View>

      <Card title="Meals">
        {MEALS.map((meal) => (
          <MealRow
            key={meal}
            label={MEAL_LABEL[meal]}
            done={draft.meals[meal].done}
            amount={draft.meals[meal].amount}
            onToggle={(done) => dispatch({ type: 'toggleMeal', meal, done })}
            onAmount={(amount) => dispatch({ type: 'setMealAmount', meal, amount })}
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

      <View style={styles.sectionGap}>
        <SectionHeading
          title="Anything different today?"
          hint="Most days stay the same. Just tap what changed."
        />
      </View>
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
        error={photoError}
      />

      <Card title="Note">
        <Field
          value={draft.note}
          onChangeText={(value) => dispatch({ type: 'setNote', value })}
          placeholder="Add anything worth mentioning…"
          accessibilityLabel="Note"
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
function SupplementalMed({ value, onChange }: { value: string; onChange: (v: string) => void }) {
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

function initials(name: string): string {
  return name.trim().charAt(0).toUpperCase() || '?';
}

const styles = StyleSheet.create({
  centered: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: color.paper },
  pressed: { opacity: 0.7 },

  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  avatarLarge: {
    width: sizes.avatarLarge,
    height: sizes.avatarLarge,
    borderRadius: radii.chip,
    backgroundColor: color.honeySoft,
    alignItems: 'center',
    justifyContent: 'center',
  },
  avatarLargeText: { fontFamily: type.buttonPrimary.fontFamily, fontSize: 16, color: color.ink2 },
  headerSpacer: { width: sizes.avatarLarge },
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: radii.chip,
    backgroundColor: color.claySoft,
  },
  badgeText: { ...type.badge, color: color.clay },

  title: { ...type.screenTitle, color: color.ink },
  subtitle: { fontFamily: type.meta.fontFamily, fontSize: 14, color: color.ink3, marginTop: 4 },

  clientRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginTop: 6 },
  clientButton: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  avatarSmall: {
    width: sizes.avatarSmall,
    height: sizes.avatarSmall,
    borderRadius: radii.chip,
    backgroundColor: color.claySoft,
    alignItems: 'center',
    justifyContent: 'center',
  },
  avatarSmallText: { fontFamily: type.buttonPrimary.fontFamily, fontSize: 11, color: color.ink2 },
  clientName: { fontFamily: type.chip.fontFamily, fontSize: 15, color: color.ink },
  separator: { color: color.ink4 },

  sectionGap: { marginTop: 14 },
  flagLabel: { ...type.fieldLabel, marginTop: 4, marginBottom: 10 },

  suppTrigger: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginTop: 10,
    paddingTop: 12,
    borderTopWidth: 1,
    borderTopColor: color.line,
  },
  suppPlus: {
    width: 22,
    height: 22,
    borderRadius: 7,
    borderWidth: 1.5,
    borderStyle: 'dashed',
    borderColor: color.line2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  suppPlusMark: { fontFamily: type.meta.fontFamily, fontSize: 13, color: color.ink3, lineHeight: 16 },
  suppTriggerText: { ...type.body, color: color.ink3 },
  suppOptional: { color: color.ink4 },

  suppOpen: { marginTop: 10, paddingTop: 12, borderTopWidth: 1, borderTopColor: color.line, gap: 8 },
  suppHead: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  suppLabel: { ...type.fieldLabel },
  suppRemove: { ...type.meta },
});
