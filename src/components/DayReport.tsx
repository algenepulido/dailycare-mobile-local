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
 * A day as the caregiver confirms it: what changed, the care checklist, the note, the photo.
 *
 * The family's screen rendered this too for a while, on the reasoning that the review sheet
 * had called itself "what the family would receive" since milestone one. The reasoning was
 * half right. The family must see the same day the caregiver confirmed - that part stands,
 * and the single filed record is what holds it - but this block is an account of the form:
 * counts, flags, what is missing, in the order the form asks for it. That is the right shape
 * for the person filling it in and the wrong one for a daughter, who is not reviewing a care
 * record. domain/familyDay is where her half lives now, and this is the caregiver's again.
 *
 * Sections, order and copy come from the web prototype's summary and are not re-decided here.
 * The photograph is a slot rather than a prop because the two callers hold different things.
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
      {/* Not recorded, not not done, because the sheet around this says it is what the
          family sees and the family's own screen says not recorded. Two words for one
          state, on the one line that promises the two agree - the same way the baseline
          went wrong, where this is what the family sees sat above a sentence computed
          from a different normal.

          The flag stays. For a caregiver about to send, a mark against the row that is
          still blank is a last look before it goes, which is a different job from the
          claim the words make. */}
      {missed ? (
        <View style={styles.line}>
          <Icon name="flag" size={14} color={color.flag} />
          <Text style={styles.lineMuted}>Not recorded: {group.missedItems.join(', ')}</Text>
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
