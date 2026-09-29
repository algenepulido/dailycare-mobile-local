import { StyleSheet, Text, View } from 'react-native';

import type { TrailEntry } from '@/data/api';
import { color, radii, type } from '@/theme/tokens';

import { Button } from './Button';
import { Sheet } from './Sheet';

interface TrailSheetProps {
  open: boolean;
  onClose: () => void;
  /** Most recent first, as the server returns them. */
  entries: TrailEntry[];
  who: string;
}

/** Table names are not sentences. This is the sentence. */
const SAID: Record<string, string> = {
  'care_days.read': 'opened the day',
  'care_days.insert': 'filed a day',
  'care_days.update': 'retired a day it replaced',
  'care_day_meals.insert': 'recorded meals',
  'care_day_concerns.insert': 'recorded a concern',
  'media_objects.read': 'opened a photograph',
  'media_objects.insert': 'attached a photograph',
  'residents.insert': 'admitted this resident',
  'residents.update': 'changed this resident',
  'audit_events.read': 'read this log',
};

function when(iso: string): string {
  const d = new Date(iso);
  return `${d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}, ${d.toLocaleTimeString(
    [],
    { hour: 'numeric', minute: '2-digit' },
  )}`;
}

/**
 * Who has opened this resident's record.
 *
 * A care manager's question about their own building, so the rows name people rather than
 * identifiers and say what happened rather than which table moved. An unmapped action
 * falls back to its own name: a row nobody has written a sentence for is still a row that
 * happened, and hiding it would make this list quietly incomplete.
 *
 * Reading this list is itself in the list. That is not a curiosity - an audit trail one
 * person can read without leaving a mark is a trail with a hole exactly where somebody
 * would want one.
 */
export function TrailSheet({ open, onClose, entries, who }: TrailSheetProps) {
  return (
    <Sheet open={open} onClose={onClose} footer={<Button label="Done" onPress={onClose} />}>
      <Text style={styles.title}>Who has opened this record</Text>
      <Text style={styles.blurb}>
        {entries.length === 0
          ? `Nobody has opened ${who}'s record in the last three months.`
          : `${who}, most recent first. Opening this list is recorded in it.`}
      </Text>

      {entries.map((entry, i) => (
        <View key={`${entry.at}-${i}`} style={styles.row}>
          <View style={styles.rowText}>
            <Text style={styles.actor}>{entry.actor ?? 'A scheduled job'}</Text>
            <Text style={styles.did}>{SAID[entry.action] ?? entry.action}</Text>
          </View>
          <Text style={styles.at}>{when(entry.at)}</Text>
        </View>
      ))}
    </Sheet>
  );
}

const styles = StyleSheet.create({
  title: { ...type.sheetTitle, color: color.ink, marginBottom: 4 },
  blurb: { ...type.blurb, marginBottom: 16 },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderWidth: 1,
    borderColor: color.frame,
    borderRadius: radii.innerCard,
    paddingVertical: 12,
    paddingHorizontal: 14,
    marginBottom: 8,
    backgroundColor: color.white,
  },
  rowText: { flex: 1, paddingRight: 10 },
  actor: { ...type.checklistItem, color: color.ink, fontSize: 16 },
  did: { ...type.meta, marginTop: 2 },
  at: { ...type.meta, color: color.ink4 },
});
