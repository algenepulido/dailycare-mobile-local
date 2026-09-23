/**
 * Signing in.
 *
 * A sheet rather than a screen, like the other two, because signing in is something a
 * caregiver does on top of what they were already doing — most often after a session
 * expired while the phone sat in a pocket, with a half-written day underneath that should
 * still be there when the sheet closes.
 */

import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button, Field, Sheet } from '@/components';
import { ApiError } from '@/data/api';
import { useSession } from '@/state/session';
import { color, type as typeScale } from '@/theme/tokens';

interface SignInSheetProps {
  open: boolean;
  onClose: () => void;
}

export function SignInSheet({ open, onClose }: SignInSheetProps) {
  const { signIn, redeem, signingIn } = useSession();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [problem, setProblem] = useState<string | null>(null);

  /**
   * An invitation is the same sheet with different fields.
   *
   * A caregiver whose account is new opens this one, finds their password does not work
   * because they have not got one yet, and the way out is here rather than somewhere they
   * would have to be told about. The same path accepts a reset link, because a reset is
   * the same act: a link, and a password they choose.
   */
  const [invited, setInvited] = useState(false);
  const [link, setLink] = useState('');

  const submit = async () => {
    setProblem(null);
    try {
      if (invited) {
        await redeem(link, password);
      } else {
        await signIn(email, password);
      }
      setEmail('');
      setPassword('');
      setLink('');
      setInvited(false);
      onClose();
    } catch (error) {
      // The server's sentence, which is deliberately the same for a wrong password and an
      // address nobody has. Anything else is shown as a connection problem rather than as
      // whatever the network threw, because "TypeError: Network request failed" tells a
      // caregiver nothing they can act on.
      setProblem(
        error instanceof ApiError
          ? error.message
          : 'Could not reach DailyCare. The day you have filed is still on this phone.',
      );
    }
  };

  const ready = invited
    ? link.trim().length > 0 && password.length > 0 && !signingIn
    : email.trim().length > 0 && password.length > 0 && !signingIn;

  return (
    <Sheet
      open={open}
      onClose={onClose}
      // The default. 0.6 looked right with the keyboard down and was wrong with it up:
      // Sheet subtracts the keyboard from its own maximum, so a short sheet ends up
      // shorter than its contents and the footer lands on top of the fields. Found by
      // typing into it on an emulator, where the second tap went into the first field.
      footer={
        <Button
          label={invited ? 'Set my password' : 'Sign in'}
          onPress={submit}
          disabled={!ready}
          busy={signingIn}
        />
      }
    >
      <View style={styles.body}>
        <Text style={styles.title}>{invited ? 'Set your password' : 'Sign in'}</Text>
        <Text style={styles.note}>
          {invited
            ? 'Paste the invitation you were given. It works once, and the password you choose is yours — nobody else sees it.'
            : 'You can keep filing days without signing in. Signing in is what lets them reach the rest of your team.'}
        </Text>

        {invited ? (
          <Field
            value={link}
            onChangeText={setLink}
            placeholder="Your invitation"
            accessibilityLabel="Invitation"
            sheet
            autoCapitalize="none"
            autoCorrect={false}
          />
        ) : (
          <Field
            value={email}
            onChangeText={setEmail}
            placeholder="you@example.com"
            accessibilityLabel="Email"
            sheet
            autoCapitalize="none"
            keyboardType="email-address"
            autoComplete="email"
          />
        )}
        <Field
          value={password}
          onChangeText={setPassword}
          placeholder={invited ? 'Choose a password' : 'Password'}
          accessibilityLabel={invited ? 'New password' : 'Password'}
          sheet
          secureTextEntry
          autoCapitalize="none"
          autoComplete={invited ? 'new-password' : 'current-password'}
        />

        {problem ? (
          <Text style={styles.problem} accessibilityLiveRegion="polite">
            {problem}
          </Text>
        ) : null}

        <Pressable
          onPress={() => {
            setInvited(!invited);
            setProblem(null);
          }}
          accessibilityRole="button"
          accessibilityLabel={invited ? 'I already have a password' : 'I have an invitation'}
          style={({ pressed }) => [styles.switcher, pressed && styles.pressed]}
        >
          <Text style={styles.switcherText}>
            {invited ? 'I already have a password' : 'I have an invitation'}
          </Text>
        </Pressable>
      </View>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  body: { gap: 14 },
  switcher: { paddingVertical: 8, alignSelf: 'flex-start' },
  pressed: { opacity: 0.6 },
  switcherText: { ...typeScale.body, color: color.clay, fontWeight: '600' },
  title: { ...typeScale.sectionHeading, color: color.ink },
  note: { ...typeScale.body, color: color.ink3 },
  // The one place this sheet uses a colour with a meaning: flag is what the report uses
  // for something that needs attention, and a refused sign-in is that.
  problem: { ...typeScale.body, color: color.flag },
});
