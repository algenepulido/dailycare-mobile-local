import { useCallback, useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button } from './Button';
import { Chip } from './Chip';
import { Field } from './Field';
import { Sheet } from './Sheet';
import {
  ApiError,
  assign,
  endAssignment,
  grantAccess,
  listContacts,
  recordDeparture,
  restoreAccess,
  withdrawAccess,
} from '@/data/api';
import type { RemoteAssignment, RemoteContact, RemoteMember, RemoteResident } from '@/data/api';
import { color, radii, sizes, type } from '@/theme/tokens';

interface ResidentSheetProps {
  open: boolean;
  resident: RemoteResident | null;
  facilityId: string;
  members: RemoteMember[];
  assignments: RemoteAssignment[];
  onClose: () => void;
  onDone: () => void;
}

/**
 * One resident, and the two lists that decide who may read about them.
 *
 * Both are disclosures and the screen says which kind each is. A caregiver is assigned
 * because they are working with this person; a family member is granted access because
 * somebody decided their daughter should be able to see how she is. The second is the one
 * that leaves the building, so it is the one that shows who granted it and when it was
 * taken back.
 */
export function ResidentSheet({
  open,
  resident,
  facilityId,
  members,
  assignments,
  onClose,
  onDone,
}: ResidentSheetProps) {
  const [contacts, setContacts] = useState<RemoteContact[] | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const [granting, setGranting] = useState(false);
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [relation, setRelation] = useState('child');
  const [link, setLink] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!resident) return;
    try {
      setContacts(await listContacts(resident.id));
      setProblem(null);
    } catch (error) {
      setProblem(error instanceof ApiError ? error.message : 'That could not be read just now.');
    }
  }, [resident]);

  useEffect(() => {
    if (open) void load();
  }, [open, load]);

  const close = () => {
    setGranting(false);
    setEmail('');
    setName('');
    setRelation('child');
    setLink(null);
    setProblem(null);
    setConfirming(null);
    onClose();
  };

  const run = async (what: () => Promise<void>) => {
    setBusy(true);
    setProblem(null);
    try {
      await what();
      await load();
      onDone();
    } catch (error) {
      setProblem(error instanceof ApiError ? error.message : 'That could not be done just now.');
    } finally {
      setBusy(false);
    }
  };

  if (!resident) return null;

  const theirs = assignments.filter((a) => a.residentId === resident.id && !a.endedAt);
  const unassigned = members.filter(
    (m) => m.role === 'caregiver' && !theirs.some((a) => a.memberId === m.id),
  );
  const reading = contacts ?? [];

  if (link !== null) {
    return (
      <Sheet open={open} onClose={() => setLink(null)} footer={<Button label="Done" onPress={() => setLink(null)} />}>
        <Text style={styles.title}>{name || 'They'} can come in now</Text>
        <Text style={styles.blurb}>
          Give them this. It is the only time it is shown — only a fingerprint of it is kept,
          so it cannot be looked up again. If it is lost, grant the access again.
        </Text>
        <View style={styles.linkBox}>
          <Text selectable style={styles.link}>
            {link}
          </Text>
        </View>
        <Text style={styles.note}>It stops working in seven days, or once they use it.</Text>
      </Sheet>
    );
  }

  return (
    <Sheet open={open} onClose={close} maxHeightRatio={0.9} footer={<Button label="Done" variant="secondary" onPress={close} />}>
      <Text style={styles.title}>{resident.displayName}</Text>
      <Text style={styles.blurb}>Who looks after them, and who may read how they are.</Text>

      {problem ? (
        <Text style={styles.problem} accessibilityLiveRegion="polite">
          {problem}
        </Text>
      ) : null}

      <Text style={styles.heading}>Caregivers</Text>
      {theirs.length === 0 ? (
        <Text style={styles.empty}>Nobody is assigned to them.</Text>
      ) : (
        theirs.map((a) => (
          <Pressable
            key={a.id}
            style={[styles.row, confirming === a.id && styles.rowAsking]}
            disabled={busy}
            onPress={() => {
              if (confirming !== a.id) {
                setConfirming(a.id);
                return;
              }
              setConfirming(null);
              void run(() => endAssignment(a.id));
            }}
            accessibilityRole="button"
            accessibilityLabel={
              confirming === a.id ? `Confirm taking ${a.displayName} off` : `${a.displayName}, take off`
            }
          >
            <Text style={[styles.rowName, styles.grow]}>{a.displayName}</Text>
            <Text style={styles.action}>{confirming === a.id ? 'Tap again' : 'Take off'}</Text>
          </Pressable>
        ))
      )}
      {unassigned.length > 0 ? (
        <View style={styles.chips}>
          {unassigned.map((m) => (
            <Chip
              key={m.id}
              label={`Assign ${m.displayName}`}
              selected={false}
              disabled={busy}
              onPress={() => void run(async () => {
                await assign(facilityId, resident.id, m.id);
              })}
            />
          ))}
        </View>
      ) : null}

      <Text style={styles.heading}>Family who may read it</Text>
      {reading.length === 0 ? (
        <Text style={styles.empty}>Nobody outside the building can see their days.</Text>
      ) : (
        reading.map((k) => (
          <Pressable
            key={k.id}
            style={[
              styles.row,
              k.state === 'revoked' && styles.rowGone,
              confirming === k.id && styles.rowAsking,
            ]}
            disabled={busy}
            onPress={() => {
              // Offering access again is not a destructive act, so it does not ask twice.
              // Taking it away is, and does.
              if (k.state === 'revoked') {
                void run(() => restoreAccess(resident.id, k.id));
                return;
              }
              if (confirming !== k.id) {
                setConfirming(k.id);
                return;
              }
              setConfirming(null);
              void run(() => withdrawAccess(resident.id, k.id));
            }}
            accessibilityRole="button"
            accessibilityLabel={
              k.state === 'revoked'
                ? `${k.displayName}, offer access again`
                : confirming === k.id
                  ? `Confirm withdrawing ${k.displayName}`
                  : `${k.displayName}, withdraw access`
            }
          >
            <View style={styles.rowText}>
              <Text style={styles.rowName}>{k.displayName}</Text>
              <Text style={styles.rowUnder}>
                {k.relation}
                {k.state === 'invited' ? ' — invited, not reading yet' : ''}
                {k.state === 'revoked' && k.revokedAt
                  ? ` — withdrawn ${new Date(k.revokedAt).toLocaleDateString()}`
                  : ''}
                {k.state === 'invited' && k.revokedAt ? ' — offered again, waiting' : ''}
              </Text>
            </View>
            <Text style={styles.action}>
              {k.state === 'revoked'
                ? 'Offer again'
                : confirming === k.id
                  ? 'Tap again'
                  : 'Withdraw'}
            </Text>
          </Pressable>
        ))
      )}

      {granting ? (
        <>
          <Text style={styles.label}>Their name</Text>
          <Field
            value={name}
            onChangeText={setName}
            placeholder="Anna Alvarez"
            accessibilityLabel="Their name"
            sheet
            autoCapitalize="words"
          />
          <Text style={styles.label}>Their email</Text>
          <Field
            value={email}
            onChangeText={setEmail}
            placeholder="anna@example.com"
            accessibilityLabel="Their email"
            sheet
            autoCapitalize="none"
            keyboardType="email-address"
          />
          <Text style={styles.label}>How they are related</Text>
          <View style={styles.chips}>
            {['child', 'spouse', 'sibling', 'parent', 'other'].map((r) => (
              <Chip key={r} label={r} selected={relation === r} onPress={() => setRelation(r)} />
            ))}
          </View>
          <Button
            label={busy ? 'Granting…' : 'Grant access'}
            disabled={busy || email.trim() === '' || name.trim() === ''}
            onPress={() => void run(async () => {
              const got = await grantAccess(resident.id, email.trim(), name.trim(), relation);
              setGranting(false);
              setEmail('');
              if (got.link) setLink(got.link);
            })}
          />
        </>
      ) : (
        <Button label="Let somebody read it" variant="secondary" onPress={() => setGranting(true)} />
      )}

      <Text style={styles.heading}>If they move out</Text>
      <Text style={styles.note}>
        A departure is a date, not a deletion. Everything filed about them stays readable and
        the retention policy is what removes it, years from now.
      </Text>
      <Pressable
        style={[styles.row, confirming === 'depart' && styles.rowAsking]}
        disabled={busy}
        onPress={() => {
          if (confirming !== 'depart') {
            setConfirming('depart');
            return;
          }
          setConfirming(null);
          void run(async () => {
            await recordDeparture(resident.id, new Date().toISOString().slice(0, 10));
            close();
          });
        }}
        accessibilityRole="button"
        accessibilityLabel={
          confirming === 'depart' ? 'Confirm recording the departure' : 'Record that they have moved out'
        }
      >
        <Text style={[styles.rowName, styles.grow]}>
          {confirming === 'depart' ? 'Tap again to record it' : 'They have moved out'}
        </Text>
      </Pressable>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  title: { ...type.sheetTitle, color: color.ink },
  blurb: { ...type.blurb, marginTop: 6, marginBottom: sizes.sectionGap },
  heading: { ...type.fieldLabel, marginTop: sizes.sectionGap, marginBottom: sizes.cardGap },
  label: { ...type.fieldLabel, marginTop: sizes.cardGap, marginBottom: 6 },
  note: { ...type.hint, marginTop: 6, marginBottom: sizes.cardGap },
  empty: { ...type.body, color: color.ink3, marginBottom: sizes.cardGap },
  chips: { flexDirection: 'row', gap: sizes.cardGap, flexWrap: 'wrap', marginTop: sizes.cardGap },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: sizes.cardGap,
    backgroundColor: color.white,
    borderRadius: radii.innerCard,
    borderWidth: 1,
    borderColor: color.frame,
    padding: 14,
    marginBottom: sizes.cardGap,
  },
  rowAsking: { borderColor: color.clay, backgroundColor: color.claySoft },
  rowGone: { backgroundColor: color.paper2, borderColor: color.line },
  rowText: { flex: 1, gap: 2 },
  // No flex here. It had one, copied from the caregiver row above where the name is a direct
  // child of the row and flex is what pushes the action to the right - but in the family row
  // the name sits inside a column, where flex makes it share the height with the line under
  // it and collapse to nothing. The manager's screen showed "child - withdrawn 6 Oct" with
  // no name against it, which only a device showed: the dump had the same gap and read as
  // ordinary, and the server had been returning the name all along.
  rowName: { ...type.cardTitle, color: color.ink },
  grow: { flex: 1 },
  rowUnder: { ...type.meta },
  action: { ...type.chip, color: color.clay },
  problem: {
    ...type.body,
    color: color.ink,
    backgroundColor: color.flagSoft,
    borderRadius: radii.innerCard,
    padding: 14,
    marginBottom: sizes.cardGap,
  },
  linkBox: {
    backgroundColor: color.paper2,
    borderRadius: radii.innerCard,
    borderWidth: 1,
    borderColor: color.frame,
    padding: 14,
  },
  link: { ...type.body, color: color.ink },
});
