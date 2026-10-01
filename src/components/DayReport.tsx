import { StyleSheet, Text, View } from 'react-native';
import type { ReactNode } from 'react';

import type { Change, ChecklistGroup } from '@/domain/rules';
import { color, radii, type } from '@/theme/tokens';

import { Icon } from './Icon';

interface DayReportProps {
  changes: Change[];
  checklist: ChecklistGroup[];
  note: string;
  /** The photograph, which is the caller's because the two callers hold different things:
   *  a file on this phone, or a link the server signed for a few minutes. */
  children?: ReactNode;
}

/**
 * A day, as a family reads it: what changed, the care checklist, the note, the photograph.
 *
 * One component rather than two, because the caregiver's review sheet has described itself
 * as "what the family would receive" since milestone one and now there is a family
 * receiving it. Two copies of this block would let the sentence stop being true quietly -
 * a wording changed on one screen, a section reordered on the other, and a caregiver
 * confirming something slightly different from what a daughter is shown.
 *
 * Sections, order and copy come from the web prototype's summary and are not re-decided
 * here. The photograph is a slot rather than a prop for the reason above it.
 */
export function DayReport({ changes, checklist, note, children }: DayReportProps) {
  return (
    <>
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

      {children}
    </>
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
});
