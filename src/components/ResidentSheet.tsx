import { useCallback, useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button } from './Button';
import { Chip } from './Chip';
import { Face } from './Face';
import { Field } from './Field';
import { Sheet } from './Sheet';
import {
  ApiError,
  assign,
  fetchResidentPhoto,
  uploadPhoto,
  endAssignment,
  grantAccess,
  listContacts,
  recordDeparture,
  restoreAccess,
  withdrawAccess,
} from '@/data/api';
import type { DayPhoto, RemoteAssignment, RemoteContact, RemoteMember, RemoteResident } from '@/data/api';
import { PHOTO_READ_ERROR, pickPhoto } from '@/data/photos';
import { addressFor } from '@/domain/people';
import { color, radii, sizes, type } from '@/theme/tokens';

interface ResidentSheetProps {
  open: boolean;
  resident: RemoteResident | null;
  facilityId: string;
  members: RemoteMember[];
  assignments: RemoteAssignment[];
  /** Worked out by the building, not here, so a name is qualified on every list or on none. */
  sharedNames: Set<string>;
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
  sharedNames,
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
  const [photo, setPhoto] = useState<DayPhoto | null>(null);
  const [photoBusy, setPhotoBusy] = useState(false);

  const load = useCallback(async () => {
    if (!resident) return;
    try {
      setContacts(await listContacts(resident.id));
      // Not awaited into the same answer. A link that could not be signed is a missing
      // face, not a sheet that failed to open.
      void fetchResidentPhoto(resident.id).then(setPhoto).catch(() => setPhoto(null));
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
    setPhoto(null);
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

  // Replacing one is adding another, because the application cannot delete a photograph -
  // that is the retention handshake's and deliberately out of reach here. The newest that
  // actually arrived is the one that shows, which the model decides rather than this.
  async function addPhoto(source: 'camera' | 'library') {
    if (!resident) return;
    setPhotoBusy(true);
    setProblem(null);
    try {
      const picked = await pickPhoto(source);
      if (picked.failed) setProblem(PHOTO_READ_ERROR);
      if (!picked.uri) return;
      await uploadPhoto(resident.id, picked.uri);
      setPhoto(await fetchResidentPhoto(resident.id));
    } catch (error) {
      // The message, not a sentence about one. A photograph failing to attach has three
      // or four different causes and a single "could not be added" makes them one thing
      // nobody can act on - including me, looking at it on a device.
      const said = error instanceof Error ? error.message : String(error);
      setProblem(said || 'That photograph could not be added.');
    } finally {
      setPhotoBusy(false);
    }
  }

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
      {/* The sheet's body shrinks to fit and does not scroll on its own, so content taller
        * than it overflows underneath the pinned footer rather than becoming reachable.
        * This had no scroller, and a resident with a few caregivers and the grant form open
        * put "Grant access" behind "Done" - a black button with a sliver showing, and a tap
        * meant for it closing the sheet instead. Seen on a device while recording; the
        * accessibility dump reported the button present and gave the position it would have
        * had, which is how it went unnoticed in every check that reads the tree. */}
      {/* The face first, because it is who the rest of this sheet is about. A resident
        * without one shows the first letter of their name rather than a grey silhouette:
        * most will not have a photograph for a while, and the app should not look like it
        * is missing something for all of them. */}
      <View style={styles.who}>
        <Face name={resident.displayName} url={photo?.url} size={56} />
        <View style={styles.whoText}>
          <Text style={styles.title}>{resident.displayName}</Text>
          <Text style={styles.blurb}>Who looks after them, and who may read how they are.</Text>
        </View>
      </View>

      <View style={styles.chips}>
        <Chip
          label={photoBusy ? 'Adding…' : photo ? 'Take another' : 'Take a photograph'}
          selected={false}
          disabled={photoBusy || busy}
          onPress={() => void addPhoto('camera')}
        />
        <Chip
          label={photo ? 'Choose another' : 'Choose a photograph'}
          selected={false}
          disabled={photoBusy || busy}
          onPress={() => void addPhoto('library')}
        />
      </View>

      {problem ? (
        <Text style={styles.problem} accessibilityLiveRegion="polite">
          {problem}
        </Text>
      ) : null}

      {/* One list, not two controls. Putting somebody on a resident used to be a row of
        * pills reading "Assign <name>", which fails twice over: a pill is one clipped line,
        * so the address that tells two Maria Santoses apart cannot fit in it, and forty
        * staff is a wall of them. A row carries the address on its own line exactly as the
        * row above it does, and the two halves of this section now differ only in what
        * their action says. */}
      <Text style={styles.heading}>Caregivers</Text>
      {theirs.length === 0 ? (
        <Text style={styles.empty}>Nobody is assigned to them.</Text>
      ) : (
        theirs.map((a) => {
          const address = addressFor(
            a.displayName,
            members.find((m) => m.id === a.memberId)?.email,
            sharedNames,
          );
          return (
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
              // The address out loud as well as on screen. These rows showed it and did
              // not say it, so two people with one name were two buttons a screen reader
              // read identically - and the driver that walks this app by those labels hit
              // the same ambiguity, which is how it was noticed.
              accessibilityLabel={
                confirming === a.id
                  ? `Confirm taking ${spoken(a.displayName, address)} off`
                  : `${spoken(a.displayName, address)}, take off`
              }
            >
              <View style={styles.rowText}>
                <Text style={styles.rowName}>{a.displayName}</Text>
                {address !== null ? <Text style={styles.rowUnder}>{address}</Text> : null}
              </View>
              <Text style={styles.action}>{confirming === a.id ? 'Tap again' : 'Take off'}</Text>
            </Pressable>
          );
        })
      )}
      {unassigned.length > 0 ? (
        <>
          <Text style={styles.note}>Anybody else who works here</Text>
          {unassigned.map((m) => {
            const address = addressFor(m.displayName, m.email, sharedNames);
            return (
              <Pressable
                key={m.id}
                style={[styles.row, styles.rowOffered]}
                disabled={busy}
                // Putting somebody on a resident is not a destructive act, so it does not
                // ask twice. Taking them off is, and does.
                onPress={() => void run(async () => {
                  await assign(facilityId, resident.id, m.id);
                })}
                accessibilityRole="button"
                accessibilityLabel={`${spoken(m.displayName, address)}, assign to ${resident.displayName}`}
              >
                <View style={styles.rowText}>
                  <Text style={styles.rowName}>{m.displayName}</Text>
                  {address !== null ? <Text style={styles.rowUnder}>{address}</Text> : null}
                </View>
                <Text style={styles.action}>Assign</Text>
              </Pressable>
            );
          })}
        </>
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

/** A name said out loud, with the address when the name alone names two people. */
function spoken(name: string, address: string | null): string {
  return address === null ? name : `${name}, ${address}`;
}

const styles = StyleSheet.create({
  who: { flexDirection: 'row', alignItems: 'center', gap: sizes.cardGap },
  whoText: { flex: 1 },
  title: { ...type.sheetTitle, color: color.ink },
  blurb: { ...type.blurb, marginTop: 6 },
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
  // Quieter than an assigned row, so the list reads as "on them" above "could be".
  rowOffered: { backgroundColor: color.paper2, borderColor: color.line },
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
