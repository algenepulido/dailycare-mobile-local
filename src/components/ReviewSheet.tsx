import { useState } from 'react';
import { Image } from 'expo-image';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { ApiError } from '@/data/api';
import type { Change, ChecklistGroup } from '@/domain/rules';
import { color, radii, type } from '@/theme/tokens';

import { Button } from './Button';
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
 * Sections, order and copy follow the web app's sheet — what changed, the care checklist,
 * the note, the photo. Milestone 1 removes sending, not the heading the caregiver already
 * knows this surface by, so the title stays and the footer is the only thing that differs;
 * the footnote below says plainly that nothing leaves the device.
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

        <Text style={styles.sectionLabel}>What changed today</Text>
        {changes.length === 0 ? (
          <View style={styles.steady}>
            <Icon name="check" size={18} color={color.sage} />
            <Text style={styles.steadyText}>A steady day — everything as usual.</Text>
          </View>
        ) : (
          <View style={styles.stack}>
            {changes.map((change) => (
              <ChangeRow key={`${change.kind}-${change.value}`} change={change} />
            ))}
          </View>
        )}

        <Text style={styles.sectionLabel}>Care checklist</Text>
        <View style={styles.stack}>
          {checklist.map((group) => (
            <ChecklistCard key={group.label} group={group} />
          ))}
        </View>

        {note.trim() ? (
          <>
            <Text style={styles.sectionLabel}>Note</Text>
            <View style={styles.card}>
              <Text style={styles.note}>{note.trim()}</Text>
            </View>
          </>
        ) : null}

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

        <Text style={styles.footnote}>
          Preview only. Nothing is sent, and every resident here is made up.
        </Text>
      </ScrollView>
    </Sheet>
  );
}

function ChangeRow({ change }: { change: Change }) {
  const tone = change.alert ? color.flag : color.warn;
  return (
    <View style={[styles.changeRow, { borderColor: tone }]}>
      <View style={[styles.dot, { backgroundColor: tone }]} />
      <Text style={styles.changeText}>
        <Text style={styles.changeKind}>{change.kind}: </Text>
        {change.value}
        {change.baselineNote ? (
          <Text style={styles.changeNote}> · {change.baselineNote}</Text>
        ) : null}
      </Text>
      <Icon name="flag" size={16} color={tone} />
    </View>
  );
}

function ChecklistCard({ group }: { group: ChecklistGroup }) {
  const missed = group.missedItems.length > 0;
  return (
    <View style={styles.card}>
      <View style={styles.checklistHead}>
        <Text style={styles.checklistLabel}>{group.label}</Text>
        <Text style={[styles.checklistCount, { color: missed ? color.flag : color.sage }]}>
          {group.done}/{group.total} done
        </Text>
      </View>
      {group.doneItems.length > 0 ? (
        <View style={styles.line}>
          <Icon name="check" size={14} color={color.sage} />
          <Text style={styles.lineText}>{group.doneItems.join(', ')}</Text>
        </View>
      ) : null}
      {missed ? (
        <View style={styles.line}>
          <Icon name="flag" size={14} color={color.flag} />
          <Text style={styles.lineMuted}>Not done: {group.missedItems.join(', ')}</Text>
        </View>
      ) : null}
      {group.extra ? (
        <View style={styles.line}>
          <Icon name="plus" size={13} color={color.ink3} />
          <Text style={styles.lineText}>Supplemental: {group.extra}</Text>
        </View>
      ) : null}
    </View>
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

  sectionLabel: { ...type.sectionLabel, marginTop: 22, marginBottom: 10, marginHorizontal: 2 },
  stack: { gap: 8 },

  steady: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    padding: 14,
    borderRadius: radii.innerCard,
    backgroundColor: color.sageSoft,
  },
  steadyText: { fontFamily: type.chip.fontFamily, fontSize: 14, color: color.ink },

  changeRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingVertical: 12,
    paddingHorizontal: 14,
    borderRadius: radii.innerCard,
    borderWidth: 1.5,
    backgroundColor: color.white,
  },
  dot: { width: 9, height: 9, borderRadius: radii.chip },
  changeText: { flex: 1, fontFamily: type.body.fontFamily, fontSize: 14, color: color.ink },
  changeKind: { fontFamily: type.buttonPrimary.fontFamily },
  changeNote: { fontSize: 12, color: color.ink3 },

  card: {
    paddingVertical: 12,
    paddingHorizontal: 14,
    borderRadius: radii.innerCard,
    borderWidth: 1.5,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  checklistHead: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  checklistLabel: { fontFamily: type.buttonPrimary.fontFamily, fontSize: 15, color: color.ink },
  checklistCount: { fontFamily: type.buttonPrimary.fontFamily, fontSize: 12 },
  line: { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 5 },
  lineText: { flex: 1, fontFamily: type.meta.fontFamily, fontSize: 13, color: color.ink2 },
  lineMuted: { flex: 1, fontFamily: type.meta.fontFamily, fontSize: 13, color: color.ink3 },

  note: { fontFamily: type.meta.fontFamily, fontSize: 14, lineHeight: 20, color: color.ink2 },

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
