import { Image } from 'expo-image';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { Button, Screen } from '@/components';
import { repository } from '@/data/repository';
import { longLabel } from '@/domain/dates';
import { buildChanges, buildChecklist } from '@/domain/rules';
import type { Change, ChecklistGroup } from '@/domain/rules';
import type { CheckIn } from '@/domain/types';
import { useSession } from '@/state/session';
import { color, radii, sizes, type } from '@/theme/tokens';

/**
 * What the family would receive, built from the entry that was just filed.
 *
 * Sections and their order follow product-spec § 7.1 — what changed, the care checklist,
 * the note, then the photo. Nothing is sent in this milestone; this is the preview.
 */
export default function SummaryScreen() {
  const router = useRouter();
  const { checkInId } = useLocalSearchParams<{ checkInId: string }>();
  const { caregiver, resident } = useSession();
  const [checkIn, setCheckIn] = useState<CheckIn | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const entry = checkInId ? await repository.getCheckIn(checkInId) : null;
      if (cancelled) return;
      setCheckIn(entry);
      setLoading(false);
    }
    void load();
    return () => {
      cancelled = true;
    };
  }, [checkInId]);

  /**
   * Pop back to the report rather than pushing a second copy of it. Falls back to
   * replace only when there is nothing to pop, which is the case if someone opens this
   * route directly.
   */
  const close = () => {
    if (router.canGoBack()) router.back();
    else router.replace('/');
  };

  if (loading) {
    return (
      <View style={styles.centered}>
        <ActivityIndicator color={color.clay} />
      </View>
    );
  }

  if (!checkIn || !resident || !caregiver) {
    return (
      <Screen footer={<Button label="Back to the report" onPress={close} />}>
        <Text style={styles.title}>Nothing to show</Text>
        <Text style={styles.subtitle}>That entry is no longer on this device.</Text>
      </Screen>
    );
  }

  const changes = buildChanges(checkIn, resident.baseline);
  const checklist = buildChecklist(checkIn);

  return (
    <Screen footer={<Button label="Back to the report" onPress={close} />}>
      <Text style={styles.title}>Daily care summary</Text>
      <Text style={styles.subtitle}>
        {longLabel(checkIn.careDate)} · {resident.displayName}
      </Text>

      <Text style={styles.sectionLabel}>What changed today</Text>
      {changes.length === 0 ? (
        <View style={styles.steady}>
          <Text style={styles.steadyText}>A steady day — everything as usual.</Text>
        </View>
      ) : (
        changes.map((change) => (
          <ChangeRow key={`${change.kind}-${change.value}`} change={change} />
        ))
      )}

      <Text style={styles.sectionLabel}>Care checklist</Text>
      {checklist.map((group) => (
        <ChecklistCard key={group.label} group={group} />
      ))}

      {checkIn.note ? (
        <>
          <Text style={styles.sectionLabel}>Note</Text>
          <View style={styles.card}>
            <Text style={styles.note}>{checkIn.note}</Text>
          </View>
        </>
      ) : null}

      {checkIn.photoUri ? (
        <View style={styles.photoRow}>
          <Image source={{ uri: checkIn.photoUri }} style={styles.thumb} contentFit="cover" />
          <View style={styles.photoPill}>
            <Text style={styles.photoPillText}>Photo attached</Text>
          </View>
        </View>
      ) : (
        <Text style={styles.noPhoto}>No photo attached</Text>
      )}

      <Text style={styles.footnote}>
        Preview only. Nothing is sent, and every resident here is made up.
      </Text>
    </Screen>
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
        <Text style={styles.checklistLine}>Done: {group.doneItems.join(', ')}</Text>
      ) : null}
      {missed ? (
        <Text style={[styles.checklistLine, styles.missedLine]}>
          Not done: {group.missedItems.join(', ')}
        </Text>
      ) : null}
      {group.extra ? <Text style={styles.checklistLine}>Supplemental: {group.extra}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  centered: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: color.paper,
  },

  title: { ...type.sheetTitle, color: color.ink },
  subtitle: { ...type.meta, marginBottom: 6 },
  sectionLabel: { ...type.sectionLabel, marginTop: 16, marginBottom: 2 },

  steady: {
    backgroundColor: color.sageSoft,
    borderRadius: radii.innerCard,
    paddingVertical: 14,
    paddingHorizontal: 16,
  },
  steadyText: { ...type.chip, color: color.ink2 },

  changeRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 8,
    paddingVertical: 12,
    paddingHorizontal: 14,
    borderRadius: radii.innerCard,
    borderWidth: 1.5,
    backgroundColor: color.white,
  },
  dot: { width: 9, height: 9, borderRadius: radii.chip, marginTop: 6 },
  changeText: { ...type.body, color: color.ink, flexShrink: 1 },
  changeKind: { fontFamily: type.chip.fontFamily },
  changeNote: { color: color.ink3 },

  card: {
    backgroundColor: color.white,
    borderRadius: radii.innerCard,
    borderWidth: 1.5,
    borderColor: color.line,
    paddingVertical: 12,
    paddingHorizontal: 16,
    gap: 3,
  },
  checklistHead: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
  checklistLabel: { ...type.chip, color: color.ink },
  checklistCount: { ...type.meta },
  checklistLine: { ...type.meta, color: color.ink2 },
  missedLine: { color: color.flag },

  note: { fontFamily: type.meta.fontFamily, fontSize: 14, color: color.ink2 },

  photoRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginTop: 4 },
  thumb: {
    width: sizes.photoButtonHeightAttached,
    height: sizes.photoButtonHeightAttached,
    borderRadius: radii.photoThumb,
    backgroundColor: color.paper2,
  },
  photoPill: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: radii.chip,
    backgroundColor: color.sageSoft,
  },
  photoPillText: { ...type.meta, color: color.ink2 },
  noPhoto: { ...type.meta, marginTop: 4 },

  footnote: { ...type.meta, color: color.ink4, marginTop: 12 },
});
