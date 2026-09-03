import { Redirect, useRouter } from 'expo-router';
import { useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import {
  Button,
  Card,
  ChoiceGroup,
  DateStrip,
  Field,
  PhotoTile,
  Screen,
  SectionLabel,
  ToggleRow,
} from '@/components';
import { deletePhoto, pickPhoto } from '@/data/photos';
import type { PhotoSource } from '@/data/photos';
import { backdateWindow, relativeLabel } from '@/domain/dates';
import { ALERT_APPETITES, ALERT_MOODS, ALERT_SLEEPS, SLEEP_CAN_ALERT } from '@/domain/rules';
import type { Meal, MealState } from '@/domain/types';
import { APPETITES, CONCERNS, MEALS, MEAL_STATES, MOODS, SLEEPS } from '@/domain/types';
import { useCheckInForm } from '@/state/checkInForm';
import { useSession } from '@/state/session';
import { color, space, type } from '@/theme/tokens';

const MEAL_LABEL: Record<Meal, string> = {
  breakfast: 'Breakfast',
  lunch: 'Lunch',
  dinner: 'Dinner',
};

/** Short enough for three segments on a narrow phone. */
const MEAL_STATE_LABEL: Record<MealState, string> = {
  none: 'None',
  partial: 'Some',
  full: 'All',
};

export default function CheckInScreen() {
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

  return <CheckInForm />;
}

/**
 * Split out so the form hook only runs once a resident exists. Calling it above the
 * redirect would mean loading a day for a resident that is not there yet.
 */
function CheckInForm() {
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
          label={form.editingExisting ? 'Update the day' : 'Finish the day'}
          onPress={handleSave}
          busy={form.saving}
          disabled={form.loading}
        />
      }
    >
      <Text style={styles.eyebrow}>{relativeLabel(draft.careDate)}</Text>
      <Text style={styles.title}>{resident.displayName}</Text>

      <DateStrip
        dates={backdateWindow()}
        value={draft.careDate}
        onChange={form.selectDate}
        filed={form.filedDates}
      />

      <Card>
        <SectionLabel>Meals</SectionLabel>
        {MEALS.map((meal) => (
          <View key={meal} style={styles.mealRow}>
            <Text style={styles.mealLabel}>{MEAL_LABEL[meal]}</Text>
            <View style={styles.mealControl}>
              <ChoiceGroup
                options={MEAL_STATES}
                value={draft.meals[meal]}
                onChange={(state) => dispatch({ type: 'setMeal', meal, state })}
                layout="segmented"
                formatLabel={(state) => MEAL_STATE_LABEL[state]}
              />
            </View>
          </View>
        ))}
      </Card>

      <Card>
        <SectionLabel>Medication</SectionLabel>
        <ToggleRow
          label="Morning dose"
          checked={draft.medication.am}
          onChange={() => dispatch({ type: 'toggleMedication', slot: 'am' })}
        />
        <ToggleRow
          label="Evening dose"
          checked={draft.medication.pm}
          onChange={() => dispatch({ type: 'toggleMedication', slot: 'pm' })}
        />
        <Field
          label="Anything extra"
          value={draft.supplementalMedication}
          onChangeText={(value) => dispatch({ type: 'setSupplementalMedication', value })}
          placeholder="Optional"
        />
      </Card>

      <Card>
        <SectionLabel>Hygiene</SectionLabel>
        <ToggleRow
          label="Shower"
          checked={draft.hygiene.shower}
          onChange={() => dispatch({ type: 'toggleHygiene', task: 'shower' })}
        />
        <ToggleRow
          label="Grooming"
          checked={draft.hygiene.grooming}
          onChange={() => dispatch({ type: 'toggleHygiene', task: 'grooming' })}
        />
      </Card>

      <Card>
        <SectionLabel>How they were</SectionLabel>
        <Text style={styles.help}>
          The family only hears about these on the days they differ from usual.
        </Text>

        <Text style={styles.field}>Mood</Text>
        <ChoiceGroup
          options={MOODS}
          value={draft.mood}
          onChange={(value) => dispatch({ type: 'setMood', value })}
          alertValues={ALERT_MOODS}
          hint={`usually ${resident.baseline.mood}`}
        />

        <Text style={styles.field}>Appetite</Text>
        <ChoiceGroup
          options={APPETITES}
          value={draft.appetite}
          onChange={(value) => dispatch({ type: 'setAppetite', value })}
          alertValues={ALERT_APPETITES}
          hint={`usually ${resident.baseline.appetite}`}
        />

        <Text style={styles.field}>Sleep last night</Text>
        <ChoiceGroup
          options={SLEEPS}
          value={draft.sleep}
          onChange={(value) => dispatch({ type: 'setSleep', value })}
          alertValues={SLEEP_CAN_ALERT ? ALERT_SLEEPS : []}
          hint={`usually ${resident.baseline.sleep}`}
        />
      </Card>

      <Card>
        <SectionLabel>Anything to flag</SectionLabel>
        <ChoiceGroup
          multiple
          options={CONCERNS}
          value={draft.concerns}
          onChange={(concern) => dispatch({ type: 'toggleConcern', concern })}
          alertValues={CONCERNS}
        />
      </Card>

      <Card>
        <SectionLabel>Photo</SectionLabel>
        <PhotoTile
          uri={draft.photoUri}
          onCapture={() => handlePickPhoto('camera')}
          onChoose={() => handlePickPhoto('library')}
          onRemove={handleRemovePhoto}
          busy={photoBusy}
        />
      </Card>

      <Card>
        <SectionLabel>Note for the family</SectionLabel>
        <Field
          label="In your words"
          value={draft.note}
          onChangeText={(value) => dispatch({ type: 'setNote', value })}
          placeholder="Sang along to every record this afternoon"
          multiline
        />
      </Card>
    </Screen>
  );
}

const styles = StyleSheet.create({
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: color.paper,
  },
  eyebrow: { ...type.label, color: color.clay },
  title: { ...type.display, color: color.ink, marginTop: -space.sm },
  help: { ...type.caption, color: color.inkSoft },
  field: { ...type.label, color: color.inkFaint, marginTop: space.xs },
  mealRow: { flexDirection: 'row', alignItems: 'center', gap: space.md },
  mealLabel: { ...type.body, color: color.inkMuted, width: 84 },
  mealControl: { flex: 1 },
});
