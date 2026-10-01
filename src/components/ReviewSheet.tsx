import { useEffect, useState } from 'react';
import { Image } from 'expo-image';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { ApiError } from '@/data/api';
import type { Change, ChecklistGroup } from '@/domain/rules';
import { color, radii, type } from '@/theme/tokens';

import { Button } from './Button';
import { DayReport } from './DayReport';
import { Icon } from './Icon';
import { Sheet } from './Sheet';

interface ReviewSheetProps {
  open: boolean;
  onClose: () => void;
  /**
   * Send the day to the server. Absent when nobody is signed in, which is a normal state:
   * the day is already on the device either way and an account is what lets it travel.
   */
  onSend?: () => Promise<void>;
  clientName: string;
  dateLabel: string;
  changes: Change[];
  checklist: ChecklistGroup[];
  note: string;
  photoUri: string | null;
}

/**
 * What the family would receive, read back before anything leaves.
 *
 * The body of it is DayReport, which the family's own screen renders too - so the sentence
 * above stays true rather than being a claim about two blocks of markup that have to be
 * kept in step by hand. What is left here is the part that belongs to a caregiver: the
 * heading they know this surface by, the send button, and what to say when a send fails.
 */
export function ReviewSheet({
  open,
  onClose,
  clientName,
  dateLabel,
  changes,
  checklist,
  note,
  photoUri,
  onSend,
}: ReviewSheetProps) {
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);

  /**
   * Disabling the button after a send stops a double tap filing the day twice. But the
   * sheet is only hidden, never unmounted, so that state outlived the sheet: a caregiver
   * who filed at noon and came back at four to add the photograph they had forgotten
   * found a greyed-out "Sent" and no way past it. Filing again is a supersede, which is
   * what correcting a day is supposed to be, so the guard belongs to one opening.
   */
  useEffect(() => {
    if (open) {
      setSent(false);
      setProblem(null);
    }
  }, [open]);

  async function send() {
    if (!onSend) return;
    setSending(true);
    setProblem(null);
    try {
      await onSend();
      setSent(true);
    } catch (error) {
      // The day is on the device and stays there. Saying so is the whole message: a
      // caregiver who thinks the note was lost will retype it, and a retyped note is a
      // second correction on a record that only changed once.
      setProblem(
        error instanceof ApiError
          ? `${error.message}. It is still saved on this phone.`
          : 'Could not reach DailyCare. It is still saved on this phone.',
      );
    } finally {
      setSending(false);
    }
  }

  return (
    <Sheet
      open={open}
      onClose={onClose}
      footer={
        onSend ? (
          <View style={styles.footer}>
            <Button label={sent ? 'Sent' : 'Send'} onPress={send} busy={sending} disabled={sent} />
            {problem ? (
              <Text style={styles.problem} accessibilityLiveRegion="polite">
                {problem}
              </Text>
            ) : null}
          </View>
        ) : (
          <Button label="Done" onPress={onClose} />
        )
      }
    >
      <ScrollView showsVerticalScrollIndicator={false}>
        <View style={styles.header}>
          <View style={styles.headerIcon}>
            <Icon name="send" size={22} color={color.clay} />
          </View>
          <View style={styles.headerText}>
            <Text style={styles.title}>{'Review & send'}</Text>
            <Text style={styles.subtitle}>
              {dateLabel} · {clientName}
            </Text>
          </View>
        </View>

        <DayReport changes={changes} checklist={checklist} note={note}>
          {photoUri ? (
            <View style={styles.photoRow}>
              <Image source={{ uri: photoUri }} style={styles.thumb} contentFit="cover" />
              <View style={styles.photoPill}>
                <Icon name="camera" size={15} color={color.sage} />
                <Text style={styles.photoPillText}>Photo attached</Text>
              </View>
            </View>
          ) : (
            <View style={styles.noPhotoRow}>
              <Icon name="camera" size={15} color={color.ink3} />
              <Text style={styles.noPhotoText}>No photo attached</Text>
            </View>
          )}
        </DayReport>

        {/* Only when nothing can leave. The sentence is milestone one's, when there was
            no server to send to and the residents were seeded - and it stayed on the sheet
            after both stopped being true, so a caregiver filing a real day was told it was
            a preview of a made-up person. */}
        {onSend ? (
          <Text style={styles.footnote}>
            This is what the family sees. Medication is not part of it and stays on this
            phone.
          </Text>
        ) : (
          <Text style={styles.footnote}>
            Nothing is sent from this phone until somebody signs in. The day is saved here
            either way.
          </Text>
        )}
      </ScrollView>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  footer: { gap: 10 },
  problem: { ...type.body, color: color.flag, textAlign: 'center' },
  header: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  headerIcon: {
    width: 44,
    height: 44,
    borderRadius: radii.chip,
    backgroundColor: color.claySoft,
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerText: { flexShrink: 1 },
  title: { ...type.sheetTitle, color: color.ink },
  subtitle: { ...type.meta, marginTop: 3 },

  photoRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 12 },
  thumb: {
    width: 64,
    height: 64,
    borderRadius: 12,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.paper2,
  },
  photoPill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingVertical: 8,
    paddingHorizontal: 14,
    borderRadius: radii.chip,
    backgroundColor: color.sageSoft,
  },
  photoPillText: { fontFamily: type.chip.fontFamily, fontSize: 13, color: color.ink },
  noPhotoRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 12 },
  noPhotoText: { fontFamily: type.chip.fontFamily, fontSize: 13, color: color.ink3 },

  footnote: { ...type.meta, color: color.ink4, marginTop: 16, marginBottom: 8 },
});
