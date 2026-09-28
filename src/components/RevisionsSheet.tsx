import { StyleSheet, Text, View } from 'react-native';

import type { FiledSummary } from '@/data/wire';
import { MEAL_AMOUNT_LABEL } from '@/domain/types';
import { color, radii, type } from '@/theme/tokens';

import { Button } from './Button';
import { Sheet } from './Sheet';

interface RevisionsSheetProps {
  open: boolean;
  onClose: () => void;
  /** Oldest first, the way the server returns them. The last one is what stands. */
  revisions: FiledSummary[];
  dateLabel: string;
  /** The day being looked at, as 2026-09-25. Decides whether a stamp needs its date. */
  careDate: string;
}

/**
 * A time, with the date in front of it when it is not the day being looked at.
 *
 * Without the date this read "Filed 2:17 PM, replaced 1:19 PM" for a day filed on the
 * Friday and corrected on the Monday - which looks like time running backwards, and a
 * record that appears to contradict itself is worse than one that is simply long. Most
 * corrections happen on the same day and stay short; the ones that do not say so.
 */
function at(iso: string, careDate: string): string {
  const d = new Date(iso);
  const time = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  const sameDay =
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` ===
    careDate;
  if (sameDay) return time;
  return `${d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}, ${time}`;
}

function eaten(summary: FiledSummary): string {
  const had = summary.meals.filter((m) => m.happened);
  if (had.length === 0) return 'No meals recorded';
  return had
    .map((m) => {
      const label = m.slot.charAt(0).toUpperCase() + m.slot.slice(1);
      return m.amount ? `${label} (${MEAL_AMOUNT_LABEL[m.amount].toLowerCase()})` : label;
    })
    .join(', ');
}

/**
 * What a day has been, in the order it was.
 *
 * A record is amended rather than overwritten, which is only worth anything if the thing
 * it was amended from can still be read. So the older versions are here in full, not as a
 * note saying one existed - and the one that stands is marked rather than assumed to be
 * the one on top, because a list read quickly is a list read from the top.
 */
export function RevisionsSheet({ open, onClose, revisions, dateLabel, careDate }: RevisionsSheetProps) {
  const single = revisions.length === 1;
  return (
    <Sheet open={open} onClose={onClose} footer={<Button label="Done" onPress={onClose} />}>
      <Text style={styles.title}>{dateLabel}</Text>
      <Text style={styles.blurb}>
        {single
          ? 'Filed once, and not corrected since.'
          : `Corrected ${revisions.length - 1 === 1 ? 'once' : `${revisions.length - 1} times`}. Every version is kept.`}
      </Text>

      {revisions.map((revision, i) => {
        const stands = revision.supersededAt === null;
        return (
          <View key={`${revision.filedAt}-${i}`} style={[styles.row, stands && styles.rowStands]}>
            <View style={styles.rowHead}>
              <Text style={styles.when}>Filed {at(revision.filedAt, careDate)}</Text>
              <Text style={stands ? styles.badgeStands : styles.badgeReplaced}>
                {stands ? 'This is what stands' : `Replaced ${at(revision.supersededAt!, careDate)}`}
              </Text>
            </View>
            <Text style={styles.detail}>{eaten(revision)}</Text>
            <Text style={styles.detail}>
              {[revision.shower ? 'Shower' : null, revision.grooming ? 'Grooming' : null]
                .filter(Boolean)
                .join(', ') || 'No hygiene recorded'}
            </Text>
            {revision.note ? <Text style={styles.note}>{revision.note}</Text> : null}
          </View>
        );
      })}

      <Text style={styles.footnote}>
        Medication is recorded on the phone that took it and is not part of this record.
      </Text>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  title: { ...type.sheetTitle, color: color.ink, marginBottom: 4 },
  blurb: { ...type.blurb, marginBottom: 18 },
  row: {
    borderWidth: 1,
    borderColor: color.frame,
    borderRadius: radii.innerCard,
    padding: 14,
    marginBottom: 10,
    backgroundColor: color.white,
  },
  rowStands: { borderColor: color.sage, backgroundColor: color.sageSoft },
  rowHead: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 },
  when: { ...type.chip, color: color.ink2 },
  badgeStands: { ...type.meta, color: color.ink2 },
  badgeReplaced: { ...type.meta, color: color.ink4 },
  detail: { ...type.body, color: color.ink2 },
  note: { ...type.body, color: color.ink3, marginTop: 6, fontStyle: 'italic' },
  footnote: { ...type.hint, marginTop: 8 },
});
