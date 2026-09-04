/**
 * Photo capture and storage.
 *
 * The picker hands back a file in a cache the system is free to clear, so anything kept
 * is copied into the app's document directory first.
 *
 * Originals are stored, never a display-sized copy. Downsizing here would be cheap now
 * and impossible to undo later, when the family is offered a real download of the photo
 * their caregiver took.
 */

import { Directory, File, Paths } from 'expo-file-system';
import * as ImagePicker from 'expo-image-picker';
import { Alert, Linking } from 'react-native';

import { newId } from './ids';

const PHOTO_DIRECTORY = 'photos';

/** Full quality, and no editing step, so what is stored is what the camera produced. */
const PICKER_OPTIONS: ImagePicker.ImagePickerOptions = {
  mediaTypes: ['images'],
  allowsEditing: false,
  quality: 1,
  exif: false,
};

export type PhotoSource = 'camera' | 'library';

export interface PickResult {
  uri: string | null;
  /** True when a file was chosen but could not be read. */
  failed: boolean;
}

/** Exact copy from product-spec § 3.6. */
export const PHOTO_READ_ERROR =
  'Couldn\u2019t read that photo. Try a different one, or take a screenshot of it and attach the screenshot.';

const SOURCE_LABEL: Record<PhotoSource, string> = {
  camera: 'the camera',
  library: 'your photos',
};

function photoDirectory(): Directory {
  const directory = new Directory(Paths.document, PHOTO_DIRECTORY);
  if (!directory.exists) {
    directory.create({ intermediates: true });
  }
  return directory;
}

function extensionFor(uri: string): string {
  const match = /\.([A-Za-z0-9]+)(?:\?.*)?$/.exec(uri);
  return match ? match[1].toLowerCase() : 'jpg';
}

/**
 * Copies a picked asset into permanent storage and returns its URI.
 * The name is a generated ID, so two photos taken in the same second cannot collide.
 */
function persist(sourceUri: string): string {
  const source = new File(sourceUri);
  const destination = new File(photoDirectory(), `${newId()}.${extensionFor(sourceUri)}`);
  source.copy(destination);
  return destination.uri;
}

/**
 * Explains a permanent refusal instead of leaving the caregiver tapping a button that
 * does nothing.
 *
 * Android stops showing its own prompt once someone has denied with "don't ask again",
 * and every later request returns denied straight away. Without this, the photo buttons
 * simply stop responding and there is nothing on screen to say why.
 */
function explainRefusal(source: PhotoSource) {
  Alert.alert(
    `DailyCare can't reach ${SOURCE_LABEL[source]}`,
    `Permission was turned off, so this has to be switched back on in Settings before a photo can be added.`,
    [
      { text: 'Not now', style: 'cancel' },
      { text: 'Open settings', onPress: () => void Linking.openSettings() },
    ],
  );
}

/**
 * Asks for the permission this source needs.
 *
 * `canAskAgain` is the difference between "they said no this time" and "the system will
 * never ask again", and only the second one needs explaining.
 */
async function ensurePermission(source: PhotoSource): Promise<boolean> {
  const result =
    source === 'camera'
      ? await ImagePicker.requestCameraPermissionsAsync()
      : await ImagePicker.requestMediaLibraryPermissionsAsync();

  if (result.granted) return true;
  if (!result.canAskAgain) explainRefusal(source);
  return false;
}

/** Null URI means cancelled or refused; `failed` means a file was picked but unreadable. */
export async function pickPhoto(source: PhotoSource): Promise<PickResult> {
  if (!(await ensurePermission(source))) return { uri: null, failed: false };

  try {
    const result =
      source === 'camera'
        ? await ImagePicker.launchCameraAsync(PICKER_OPTIONS)
        : await ImagePicker.launchImageLibraryAsync(PICKER_OPTIONS);

    if (result.canceled || result.assets.length === 0) return { uri: null, failed: false };

    return { uri: persist(result.assets[0].uri), failed: false };
  } catch {
    // A device with no camera, or a picker the system refused to open. Saying so beats
    // a button that looks broken.
    Alert.alert(
      `DailyCare couldn't open ${SOURCE_LABEL[source]}`,
      source === 'camera'
        ? 'This device may not have a camera available. A photo can still be chosen from the gallery.'
        : 'The gallery could not be opened on this device.',
    );
    return { uri: null, failed: true };
  }
}

/** Removes a stored photo. Missing files are ignored — the record is what matters. */
export function deletePhoto(uri: string): void {
  const file = new File(uri);
  if (file.exists) {
    file.delete();
  }
}
