import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { Appetite, Baseline, Mood, Sleep } from '@/domain/types';
import { sharedNames } from '@/domain/people';
import { APPETITES, MOODS, SLEEPS } from '@/domain/types';
import { color, radii, type } from '@/theme/tokens';

import { Button } from './Button';
import { Chip } from './Chip';
import { Field } from './Field';
import { Sheet } from './Sheet';

interface SetupSheetProps {
  open: boolean;
  caregiverName: string;
  residentName: string;
  baseline: Baseline;
  /**
   * `remoteId` is set when the resident was picked from the list rather than typed. It is
   * the only thing that tells two people with one name apart, so it travels with the
   * name rather than being worked out again from it later.
   */
  onSave: (
    caregiverName: string,
    residentName: string,
    baseline: Baseline,
    remoteId?: string,
  ) => void;
  onClose: () => void;
  /** First run introduces the app; every later visit is an edit to what is stored. */
  firstRun?: boolean;
  /**
   * Offered on a first run only: this is a phone belonging to somebody who was invited
   * rather than somebody setting up a round.
   *
   * Without it a family member could not sign in at all. The first-run sheet cannot be
   * dismissed - correctly, there is nothing behind it - and the sign-in sheet lives inside
   * the day screen, so the only route to it was to invent a caregiver and a resident first.
   * A daughter was being asked to name her mother and describe her normal day before she
   * could type the invitation she had been sent.
   */
  onSignIn?: () => void;
  /**
   * The phone is matched to a resident the building holds, so what is usual for them is
   * the building's record rather than this phone's.
   *
   * Shown rather than hidden, and read-only rather than editable. A care manager typed it
   * when she admitted them, the family's screen is compared against it, and a copy edited
   * here would only put this phone out of step with what the family is actually told.
   */
  usualIsTheirRecord?: boolean;
  /**
   * Take everything this phone holds off it.
   *
   * Offered because signing out deliberately does not. Signing out is the end of a shift;
   * this is a ward tablet being handed on or a phone being given back, and until now there
   * was no way to say so - the records, the photographs and the day in progress stayed
   * where the next person to open the app would find them.
   */
  onForget?: () => void;
  /**
   * A way off this sheet for somebody who is signed in and should not be looking at it.
   *
   * The first-run sheet cannot be dismissed, correctly - there is nothing behind it. But
   * a care manager's phone renders it for as long as the app does not yet know she manages
   * a building, and it does not know until /v1/me answers. On a slow connection that is a
   * moment; with no connection it never answers, and she is asked to name a caregiver and
   * a resident with no way out. Seen on a device, opening the app offline.
   */
  onSignOut?: () => void;
  /**
   * The residents this account is allowed to file for, where there is an account.
   *
   * Offered instead of a name to type, because the name has to match the building's
   * record exactly for the phone to be matched to it and the field asked for a first
   * name. A caregiver invited to look after Marisol Reyes, typing "Marisol" as the label
   * above the box asks her to, got a phone that linked to nobody - and the review sheet
   * then told her to go and ask for an assignment she already had. Picking cannot miss.
   */
  choices?: { id: string; displayName: string; baseline: Baseline }[];
  /** There is an account on this phone, so an empty list of choices means something. */
  signedIn?: boolean;
}

/**
 * Who is logging, who they are logging for, and what a normal day looks like for them.
 *
 * The baseline lives here rather than in the check-in because it is a fact about the
 * resident, not about today: it decides what counts as news, so it has to be set before
 * the first day is filed and stay editable when the resident's normal shifts.
 */
export function SetupSheet({
  open,
  caregiverName,
  residentName,
  baseline,
  onSave,
  onClose,
  firstRun = false,
  onSignIn,
  usualIsTheirRecord = false,
  choices,
  signedIn = false,
  onForget,
  onSignOut,
}: SetupSheetProps) {
  const [caregiver, setCaregiver] = useState(caregiverName);
  const [resident, setResident] = useState(residentName);
  const [usual, setUsual] = useState<Baseline>(baseline);
  const [picked, setPicked] = useState<string | null>(null);
  const [forgetting, setForgetting] = useState(false);

  // Reopening shows what is stored now, not what was typed and abandoned last time.
  useEffect(() => {
    if (!open) return;
    setCaregiver(caregiverName);
    setResident(residentName);
    setPicked(null);
    setForgetting(false);
    setUsual(baseline);
  }, [open, caregiverName, residentName, baseline]);

  // Where the account has a list, the resident comes off it and the "usual" comes with
  // them: picked from the building's record, it is the building's record, and the family's
  // screen is compared against the same one.
  const offered = choices ?? [];
  const picking = offered.length > 0;
  // Signed in with nothing to pick is not a form to fill in. It used to fall through to a
  // name to type, which could not match anything and produced a phone that filed days
  // nowhere.
  const nothingToFileFor = signedIn && offered.length === 0 && firstRun;
  const fromRecord = usualIsTheirRecord || (picking && offered.some((c) => c.displayName === resident));
  // Two residents with one name is rarer than two staff with one name and has no address
  // to tell them apart - a resident has a name and nothing else a caregiver would
  // recognise. Picking either one is safe, because what travels is the id and not the
  // name. What is not safe is a person choosing between two identical buttons and
  // believing they chose. So it says so.
  const twoAlike = picking && sharedNames(offered).size > 0;
  const complete = caregiver.trim().length > 0 && resident.trim().length > 0 && !nothingToFileFor;

  return (
    <Sheet
      open={open}
      onClose={firstRun ? () => {} : onClose}
      footer={
        <View style={styles.footer}>
          <Button
            // What is still missing, rather than a count of what a form wants. It said
            // "add your name and pick who" to somebody who had already picked.
            label={
              nothingToFileFor
                ? 'Nobody to file for yet'
                : complete
                  ? firstRun
                    ? 'Start daily care'
                    : 'Save changes'
                  : caregiver.trim() === '' && resident.trim() === ''
                    ? picking
                      ? 'Add your name and pick who'
                      : 'Add both names to continue'
                    : caregiver.trim() === ''
                      ? 'Add your name'
                      : picking
                        ? 'Pick who you are caring for'
                        : 'Add their name'
            }
            disabled={!complete}
            disabledAppearance="muted"
            onPress={() => onSave(caregiver.trim(), resident.trim(), usual, picked ?? undefined)}
          />
          {firstRun && onSignIn && !signedIn ? (
            <Pressable
              onPress={onSignIn}
              accessibilityRole="button"
              accessibilityLabel="I was sent an invitation"
              style={({ pressed }) => [styles.invited, pressed && styles.invitedPressed]}
            >
              <Text style={styles.invitedText}>I was sent an invitation</Text>
            </Pressable>
          ) : null}
          {firstRun && signedIn && onSignOut ? (
            <Pressable
              onPress={onSignOut}
              accessibilityRole="button"
              accessibilityLabel="This is not my account"
              style={({ pressed }) => [styles.invited, pressed && styles.invitedPressed]}
            >
              <Text style={styles.invitedText}>This is not my account</Text>
            </Pressable>
          ) : null}
        </View>
      }
    >
        <Text style={styles.title}>Let&rsquo;s set up daily care</Text>
        <Text style={styles.blurb}>
          Two names and what a normal day looks like. You can change these later.
        </Text>

        <Text style={styles.label}>Your name</Text>
        <Field
          value={caregiver}
          onChangeText={setCaregiver}
          placeholder="The caregiver reporting"
          accessibilityLabel="Your name"
          autoCapitalize="words"
          sheet
        />

        <View style={styles.gap} />

        <Text style={styles.label}>Who you&rsquo;re caring for</Text>
        {nothingToFileFor ? (
          <Text style={styles.hint}>
            The care home has not put this account in front of anybody yet. Ask them to
            assign you, then sign in again.
          </Text>
        ) : picking ? (
          <>
            {twoAlike ? (
              <Text style={styles.hint}>
                Two of these have the same name. Ask the care manager which one this phone
                is for before you choose.
              </Text>
            ) : null}
          <View style={styles.chips}>
            {offered.map((person) => (
              <Chip
                key={person.id}
                label={person.displayName}
                selected={resident === person.displayName}
                onPress={() => {
                  setResident(person.displayName);
                  setUsual(person.baseline);
                  setPicked(person.id);
                }}
              />
            ))}
          </View>
          </>
        ) : (
          <Field
            value={resident}
            onChangeText={setResident}
            placeholder="Their first name"
            accessibilityLabel="Who you're caring for"
            autoCapitalize="words"
            sheet
          />
        )}

        {nothingToFileFor ? null : (
          <>
        <Text style={styles.sectionLabel}>What&rsquo;s usual for them</Text>
        <Text style={styles.hint}>
          {fromRecord
            ? 'Each day is compared against this, so the family only hears about what changed. It is their record at the care home, and it is changed there.'
            : 'Each day is compared against this, so the family only hears about what changed.'}
        </Text>

        <View style={styles.card}>
          <UsualRow
            label="Usual mood"
            options={MOODS}
            value={usual.mood}
            onChange={(mood: Mood) => setUsual((current) => ({ ...current, mood }))}
            fixed={fromRecord}
          />
          <UsualRow
            label="Usual appetite"
            options={APPETITES}
            value={usual.appetite}
            onChange={(appetite: Appetite) => setUsual((current) => ({ ...current, appetite }))}
            fixed={fromRecord}
          />
          <UsualRow
            label="Usual sleep"
            options={SLEEPS}
            value={usual.sleep}
            onChange={(sleep: Sleep) => setUsual((current) => ({ ...current, sleep }))}
            last
            fixed={fromRecord}
          />
        </View>
          </>
        )}

        {/* Two taps, and the second is on a row that has already changed to ask - the same
          * shape as ending a membership, because this is the same kind of act. */}
        {onForget && !firstRun ? (
          <>
            <Text style={styles.sectionLabel}>This phone</Text>
            <Text style={styles.hint}>
              Everything filed from here that reached the care home stays there. What goes
              is this phone&rsquo;s own copy: the names above, the photographs taken on it,
              and anything filed here that has not reached the care home yet.
            </Text>
            <Pressable
              style={[styles.forget, forgetting && styles.forgetAsking]}
              onPress={() => {
                if (!forgetting) {
                  setForgetting(true);
                  return;
                }
                setForgetting(false);
                onForget();
              }}
              accessibilityRole="button"
              accessibilityLabel={
                forgetting
                  ? "Confirm removing this device's data"
                  : "Remove this device's data"
              }
            >
              <Text style={styles.forgetText}>
                {forgetting ? 'Tap again to remove it' : "Remove this device's data"}
              </Text>
            </Pressable>
          </>
        ) : null}
    </Sheet>
  );
}

/**
 * One baseline choice. Deliberately not ObservationRow: that row exists to say whether
 * today differs from the usual, and here the usual is the thing being set.
 */
function UsualRow<T extends string>({
  label,
  options,
  value,
  onChange,
  last = false,
  fixed = false,
}: {
  label: string;
  options: readonly T[];
  value: NoInfer<T>;
  onChange: (value: NoInfer<T>) => void;
  last?: boolean;
  /** Set somewhere else, so shown and not offered. */
  fixed?: boolean;
}) {
  return (
    <View style={last ? styles.usualLast : styles.usual}>
      <Text style={styles.label}>{label}</Text>
      <View style={styles.chips}>
        {/* Only the answer, when it is not this phone's to change. A row of greyed-out
          * alternatives invites a tap that does nothing, and the one that matters is
          * harder to find among four that are refused. */}
        {(fixed ? options.filter((option) => option === value) : options).map((option) => (
          <Chip
            key={option}
            label={option}
            selected={value === option}
            disabled={fixed}
            onPress={() => onChange(option)}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  footer: { gap: 4 },
  invited: { alignItems: 'center', paddingVertical: 12, minHeight: 44, justifyContent: 'center' },
  invitedPressed: { opacity: 0.6 },
  invitedText: { ...type.body, color: color.clay, textDecorationLine: 'underline' },

  title: { ...type.setupTitle, color: color.ink },
  blurb: { ...type.blurb, marginTop: 6, marginBottom: 20 },
  label: { ...type.fieldLabel, marginBottom: 8 },
  gap: { height: 16 },

  forget: {
    marginTop: 4,
    paddingVertical: 14,
    alignItems: 'center',
    borderRadius: radii.setupCard,
    borderWidth: 1,
    borderColor: color.line,
    backgroundColor: color.white,
  },
  forgetAsking: { borderColor: color.flag, backgroundColor: color.flagSoft },
  forgetText: { ...type.body, color: color.flag },

  sectionLabel: { ...type.sectionLabel, marginTop: 24 },
  hint: { ...type.hint, marginTop: 6, marginBottom: 12 },

  card: {
    backgroundColor: color.white,
    borderRadius: radii.setupCard,
    borderWidth: 1,
    borderColor: color.line,
    paddingTop: 14,
    paddingHorizontal: 16,
    paddingBottom: 14,
    marginBottom: 8,
  },
  usual: { marginBottom: 16 },
  usualLast: { marginBottom: 0 },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
});
