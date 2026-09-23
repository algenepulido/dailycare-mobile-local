/**
 * Puts network_security_config.xml into the Android build and points the manifest at it.
 *
 * Without this the file sits in the repository doing nothing, which is worse than not
 * having it: a security control nobody wired up still reads like one.
 *
 * The alternative is `usesCleartextTraffic: true` from expo-build-properties, which is one
 * line and turns plain HTTP on for every host the app will ever talk to. This is more
 * setup for a narrower hole - see README.md beside this file.
 */

const { withAndroidManifest, withDangerousMod } = require('expo/config-plugins');
const fs = require('fs');
const path = require('path');

const RESOURCE = 'network_security_config';

/**
 * Two files, one name, and the build type decides which one is in the APK.
 *
 * src/main holds the configuration that ships: cleartext off everywhere. src/debug holds
 * the one with the emulator exception. The Android resource merger prefers the build
 * type's copy, so a debug build gets the exception and a release build has no way to -
 * there is no flag to set and nothing to remember.
 *
 * The exception used to be in the single shared file, so it shipped. It named 10.0.2.2,
 * which is the emulator's alias for its host and is also an ordinary private address that
 * a care home's network can really have.
 */
function withConfigFile(config) {
  return withDangerousMod(config, [
    'android',
    async (cfg) => {
      const from = path.join(cfg.modRequest.projectRoot, 'network-security');
      const into = cfg.modRequest.platformProjectRoot;

      for (const [source, variant] of [
        [`${RESOURCE}.xml`, 'main'],
        [`${RESOURCE}.debug.xml`, 'debug'],
      ]) {
        const dir = path.join(into, `app/src/${variant}/res/xml`);
        fs.mkdirSync(dir, { recursive: true });
        fs.copyFileSync(path.join(from, source), path.join(dir, `${RESOURCE}.xml`));
      }
      return cfg;
    },
  ]);
}

function withManifestReference(config) {
  return withAndroidManifest(config, (cfg) => {
    const application = cfg.modResults.manifest.application?.[0];
    if (!application) throw new Error('no <application> in the manifest to point at the config');
    application.$['android:networkSecurityConfig'] = `@xml/${RESOURCE}`;
    return cfg;
  });
}

module.exports = (config) => withManifestReference(withConfigFile(config));
