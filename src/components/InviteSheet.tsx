import { useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button } from './Button';
import { Chip } from './Chip';
import { Field } from './Field';
import { Sheet } from './Sheet';
import { ApiError, inviteMember } from '@/data/api';
import { color, radii, sizes, type } from '@/theme/tokens';

interface InviteSheetProps {
  open: boolean;
  facilityId: string;
  onClose: () => void;
  onDone: () => void;
}

/**
 * Inviting somebody into the building, and the one moment their link exists.
 *
 * Only a digest of it is stored, so there is no asking for it again - and the sheet says
 * that where the link is rather than in a help page nobody opens. Shown as text to read out
 * or copy by hand on purpose: a care manager and a new caregiver are usually standing next
 * to each other, and anything cleverer needs an email service this does not have.
 */
export function InviteSheet({ open, facilityId, onClose, onDone }: InviteSheetProps) {
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [role, setRole] = useState<'caregiver' | 'care_manager'>('caregiver');
  const [sending, setSending] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const [link, setLink] = useState<string | null>(null);
  const [already, setAlready] = useState(false);

  const close = () => {
    setEmail('');
    setName('');
    setRole('caregiver');
    setProblem(null);
    setLink(null);
    setAlready(false);
    onClose();
  };

  const send = async () => {
    setSending(true);
    setProblem(null);
    try {
      const invited = await inviteMember(facilityId, email.trim(), name.trim(), role);
      if (invited.link) {
        setLink(invited.link);
      } else {
        // Not a failure. They have a password or an invitation already outstanding, and
        // issuing a second one would be a second way into the same account.
        setAlready(true);
      }
      onDone();
    } catch (error) {
      setProblem(error instanceof ApiError ? error.message : 'That could not be done just now.');
    } finally {
      setSending(false);
    }
  };

  if (link !== null || already) {
    return (
      <Sheet open={open} onClose={close} footer={<Button label="Done" onPress={close} />}>
        <Text style={styles.title}>{name || 'They'} can come in now</Text>
        {link !== null ? (
          <>
            <Text style={styles.blurb}>
              Give them this. It is the only time it is shown — only a fingerprint of it is
              kept, so it cannot be looked up again. If it is lost, invite them again.
            </Text>
            <View style={styles.linkBox}>
              <Text selectable style={styles.link}>
                {link}
              </Text>
            </View>
            <Text style={styles.note}>It stops working in seven days, or once they use it.</Text>
          </>
        ) : (
          <Text style={styles.blurb}>
            They already have a way in, so there is no new link. Their invitation to this
            building is waiting for them the next time they sign in.
          </Text>
        )}
      </Sheet>
    );
  }

  return (
    <Sheet
      open={open}
      onClose={close}
      footer={
        <Button
          label={sending ? 'Inviting…' : 'Invite'}
          onPress={() => void send()}
          disabled={sending || email.trim() === '' || name.trim() === ''}
        />
      }
    >
      <Text style={styles.title}>Invite somebody</Text>
      <Text style={styles.blurb}>
        They will set their own password. Nobody here ever sees it.
      </Text>

      {problem ? <Text style={styles.problem}>{problem}</Text> : null}

      <Text style={styles.label}>Their name</Text>
      <Field
        value={name}
        onChangeText={setName}
        placeholder="Tomas Reyes"
        accessibilityLabel="Their name"
        sheet
        autoCapitalize="words"
      />
      <Text style={styles.label}>Their email</Text>
      <Field
        value={email}
        onChangeText={setEmail}
        placeholder="tomas@example.com"
        accessibilityLabel="Their email"
        sheet
        autoCapitalize="none"
        keyboardType="email-address"
      />
      <Text style={styles.label}>What they do here</Text>
      <View style={styles.chips}>
        <Chip
          label="Caregiver"
          selected={role === 'caregiver'}
          onPress={() => setRole('caregiver')}
        />
        <Chip
          label="Care manager"
          selected={role === 'care_manager'}
          onPress={() => setRole('care_manager')}
        />
      </View>
      <Text style={styles.note}>
        A caregiver files days for the residents they are assigned to. A care manager runs
        the building and sees everybody in it.
      </Text>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  title: { ...type.sheetTitle, color: color.ink },
  blurb: { ...type.blurb, marginTop: 6, marginBottom: sizes.sectionGap },
  label: { ...type.fieldLabel, marginTop: sizes.sectionGap, marginBottom: sizes.cardGap },
  note: { ...type.hint, marginTop: sizes.cardGap },
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
  chips: { flexDirection: 'row', gap: sizes.cardGap, flexWrap: 'wrap' },
});
