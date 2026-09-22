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

function withConfigFile(config) {
  return withDangerousMod(config, [
    'android',
    async (cfg) => {
      const dir = path.join(cfg.modRequest.platformProjectRoot, 'app/src/main/res/xml');
      fs.mkdirSync(dir, { recursive: true });
      fs.copyFileSync(
        path.join(cfg.modRequest.projectRoot, 'network-security', `${RESOURCE}.xml`),
        path.join(dir, `${RESOURCE}.xml`),
      );
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
