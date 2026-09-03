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
 * Asks for the permission this source needs. Returns false when the caregiver declines,
 * so the caller can leave the screen as it was rather than failing silently.
 */
async function ensurePermission(source: PhotoSource): Promise<boolean> {
  const result =
    source === 'camera'
      ? await ImagePicker.requestCameraPermissionsAsync()
      : await ImagePicker.requestMediaLibraryPermissionsAsync();
  return result.granted;
}

/** Returns the stored URI, or null when the caregiver cancelled or declined access. */
export async function pickPhoto(source: PhotoSource): Promise<string | null> {
  if (!(await ensurePermission(source))) return null;

  const result =
    source === 'camera'
      ? await ImagePicker.launchCameraAsync(PICKER_OPTIONS)
      : await ImagePicker.launchImageLibraryAsync(PICKER_OPTIONS);

  if (result.canceled || result.assets.length === 0) return null;

  return persist(result.assets[0].uri);
}

/** Removes a stored photo. Missing files are ignored — the record is what matters. */
export function deletePhoto(uri: string): void {
  const file = new File(uri);
  if (file.exists) {
    file.delete();
  }
}
