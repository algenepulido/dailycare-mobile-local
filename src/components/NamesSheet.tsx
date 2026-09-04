import { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { color, type } from '@/theme/tokens';

import { Button } from './Button';
import { Field } from './Field';
import { Sheet } from './Sheet';

interface NamesSheetProps {
  open: boolean;
  caregiverName: string;
  residentName: string;
  onSave: (caregiverName: string, residentName: string) => void;
  onClose: () => void;
  /** First run has nothing to go back to, so the scrim must not dismiss it. */
  dismissible?: boolean;
}

/**
 * Who is logging, and who they are logging for.
 *
 * Opens by itself on first run and stays reachable from the avatar and the client name,
 * so the pair can be corrected later without clearing the app.
 */
export function NamesSheet({
  open,
  caregiverName,
  residentName,
  onSave,
  onClose,
  dismissible = true,
}: NamesSheetProps) {
  const [caregiver, setCaregiver] = useState(caregiverName);
  const [resident, setResident] = useState(residentName);

  // Reopening shows what is stored now, not what was typed and abandoned last time.
  useEffect(() => {
    if (!open) return;
    setCaregiver(caregiverName);
    setResident(residentName);
  }, [open, caregiverName, residentName]);

  const complete = caregiver.trim().length > 0 && resident.trim().length > 0;

  return (
    <Sheet
      open={open}
      onClose={dismissible ? onClose : () => {}}
      maxHeightRatio={0.75}
      footer={
        <Button
          label="Save"
          disabled={!complete}
          onPress={() => onSave(caregiver.trim(), resident.trim())}
        />
      }
    >
      <Text style={styles.title}>Who is this for?</Text>

      <Text style={styles.label}>Your name (caregiver)</Text>
      <Field
        value={caregiver}
        onChangeText={setCaregiver}
        placeholder="e.g. Maria"
        accessibilityLabel="Your name (caregiver)"
        autoCapitalize="words"
        sheet
      />

      <View style={styles.gap} />

      <Text style={styles.label}>Person you care for</Text>
      <Field
        value={resident}
        onChangeText={setResident}
        placeholder="e.g. Cathy"
        accessibilityLabel="Person you care for"
        autoCapitalize="words"
        sheet
      />
    </Sheet>
  );
}

const styles = StyleSheet.create({
  title: { ...type.sheetTitle, color: color.ink, marginBottom: 16 },
  label: { ...type.fieldLabel, marginBottom: 8 },
  gap: { height: 16 },
});
