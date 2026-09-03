import { Image } from 'expo-image';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { useEffect, useState } from 'react';
import { ActivityIndicator, StyleSheet, Text, View } from 'react-native';

import { Button, Card, Screen, SectionLabel } from '@/components';
import { repository } from '@/data/repository';
import { longLabel } from '@/domain/dates';
import { buildChanges, buildChecklist } from '@/domain/rules';
import type { Change, ChecklistGroup } from '@/domain/rules';
import type { CheckIn } from '@/domain/types';
import { useSession } from '@/state/session';
import { color, radius, space, type } from '@/theme/tokens';

/**
 * What the family would receive, built from the entry that was just filed.
 *
 * Content matches the daily email — what changed, the care checklist, the note and the
 * photo. It is not a copy of that email's layout: the visual direction is decided after
 * this build is in Trevor's hands.
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
   * Pop back to the check-in rather than pushing a second copy of it.
   *
   * router.replace here left the original check-in screen mounted underneath and put a
   * fresh one on top, so every entry a caregiver filed added another dead screen still
   * holding its own form state. Falls back to replace only when there is nothing to pop,
   * which is the case if someone opens this route directly.
   */
  const backToCheckIn = () => {
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
      <Screen footer={<Button label="Back to the check-in" onPress={backToCheckIn} />}>
        <Text style={styles.title}>Nothing to show</Text>
        <Text style={styles.lede}>That entry is no longer on this device.</Text>
      </Screen>
    );
  }

  const changes = buildChanges(checkIn, resident.baseline);
  const checklist = buildChecklist(checkIn);

  return (
    <Screen footer={<Button label="Back to the check-in" onPress={backToCheckIn} />}>
      <Text style={styles.eyebrow}>Daily care summary</Text>
      <Text style={styles.title}>{resident.displayName}</Text>
      <Text style={styles.lede}>
        {longLabel(checkIn.careDate)} · from {caregiver.displayName}
      </Text>

      <Card>
        <SectionLabel>What changed today</SectionLabel>
        {changes.length === 0 ? (
          <Text style={styles.quiet}>A day like their usual. Nothing stood out.</Text>
        ) : (
          changes.map((change) => <ChangeRow key={`${change.kind}-${change.value}`} change={change} />)
        )}
      </Card>

      <Card>
        <SectionLabel>Care checklist</SectionLabel>
        {checklist.map((group) => (
          <ChecklistRow key={group.label} group={group} />
        ))}
      </Card>

      {checkIn.note ? (
        <Card>
          <SectionLabel>{`Note from ${caregiver.displayName}`}</SectionLabel>
          <Text style={styles.note}>{checkIn.note}</Text>
        </Card>
      ) : null}

      {checkIn.photoUri ? (
        <Card>
          <SectionLabel>Photo from today</SectionLabel>
          <Image source={{ uri: checkIn.photoUri }} style={styles.photo} contentFit="cover" />
        </Card>
      ) : null}

      <Text style={styles.footnote}>
        Preview only. Nothing is sent, and every resident here is made up.
      </Text>
    </Screen>
  );
}

function ChangeRow({ change }: { change: Change }) {
  return (
    <View style={[styles.changeRow, change.alert && styles.changeRowAlert]}>
      <View style={[styles.dot, change.alert ? styles.dotAlert : styles.dotNotice]} />
      <Text style={styles.changeText}>
        <Text style={styles.changeKind}>{change.kind}: </Text>
        {change.value}
        {change.baselineNote ? <Text style={styles.changeNote}> · {change.baselineNote}</Text> : null}
      </Text>
    </View>
  );
}

function ChecklistRow({ group }: { group: ChecklistGroup }) {
  const summary = group.items.length > 0 ? group.items.join(', ') : 'Nothing recorded';
  return (
    <View style={styles.checklistRow}>
      <View style={styles.checklistHead}>
        <Text style={styles.checklistLabel}>{group.label}</Text>
        <Text style={styles.checklistCount}>{`${group.done}/${group.total} done`}</Text>
      </View>
      <Text style={styles.checklistItems}>{summary}</Text>
      {group.extra ? <Text style={styles.checklistExtra}>{`Also: ${group.extra}`}</Text> : null}
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
  eyebrow: { ...type.label, color: color.clay },
  title: { ...type.display, color: color.ink, marginTop: -space.sm },
  lede: { ...type.bodySmall, color: color.inkSoft, marginTop: -space.sm },
  quiet: { ...type.body, color: color.inkSoft },

  changeRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: space.sm,
    paddingVertical: space.sm,
    paddingHorizontal: space.md,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: color.warnSoft,
    backgroundColor: color.warnSoft,
  },
  changeRowAlert: { borderColor: color.alert, backgroundColor: color.alertSoft },
  dot: { width: 7, height: 7, borderRadius: radius.pill, marginTop: 7 },
  dotNotice: { backgroundColor: color.warn },
  dotAlert: { backgroundColor: color.alert },
  changeText: { ...type.bodySmall, color: color.ink, flexShrink: 1 },
  changeKind: { fontWeight: '700' },
  changeNote: { color: color.inkSoft },

  checklistRow: { gap: space.xs },
  checklistHead: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
  checklistLabel: { ...type.heading, color: color.ink },
  checklistCount: { ...type.caption, color: color.inkFaint },
  checklistItems: { ...type.bodySmall, color: color.inkMuted },
  checklistExtra: { ...type.caption, color: color.inkSoft },

  note: { ...type.body, color: color.inkMuted },
  photo: { width: '100%', aspectRatio: 4 / 3, borderRadius: radius.md, backgroundColor: color.paperDeep },
  footnote: { ...type.caption, color: color.inkFaint },
});
