"""Artifact contract regressions; execution belongs to the validation chat/CI."""

import unittest
import xml.etree.ElementTree as ET

from verify_release import ANDROID, EXPECTED_SIGNER, check_aab_signer, check_apk_signer, check_manifest


MANIFEST = '''<manifest xmlns:android="http://schemas.android.com/apk/res/android"
  package="org.zorofin.tv" android:versionCode="155" android:versionName="1.4.0">
  <uses-feature android:name="android.software.leanback" android:required="true"/>
  <uses-feature android:name="android.hardware.touchscreen" android:required="false"/>
  <application android:allowBackup="false" android:banner="@drawable/tv_banner">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>'''


class ManifestTests(unittest.TestCase):
    def test_play_bundle_is_tv_only(self):
        result = check_manifest(MANIFEST, 155, "google-play-tv")
        self.assertTrue(result["leanbackRequired"])
        self.assertFalse(result["touchscreenRequired"])

    def test_fire_apk_keeps_optional_leanback(self):
        xml = MANIFEST.replace('android:required="true"', 'android:required="false"')
        self.assertFalse(check_manifest(xml, 155, "universal-tv")["leanbackRequired"])
        with self.assertRaisesRegex(ValueError, "leanback must explicitly require=true"):
            check_manifest(xml, 155, "google-play-tv")
        with self.assertRaisesRegex(ValueError, "leanback must explicitly require=false"):
            check_manifest(MANIFEST, 155, "universal-tv")

    def test_missing_duplicate_or_implicit_features_do_not_pass(self):
        for mutation in ("missing", "duplicate", "implicit", "touchscreen"):
            with self.subTest(mutation=mutation):
                root = ET.fromstring(MANIFEST)
                feature = root.find("uses-feature")
                if mutation == "missing":
                    root.remove(feature)
                elif mutation == "duplicate":
                    root.append(ET.fromstring(ET.tostring(feature)))
                elif mutation == "implicit":
                    del feature.attrib[ANDROID + "required"]
                else:
                    root.findall("uses-feature")[1].set(ANDROID + "required", "true")
                with self.assertRaises(ValueError):
                    check_manifest(ET.tostring(root), 155, "google-play-tv")

    def test_identity_and_release_flags_are_enforced(self):
        for attribute, value in (("package", "org.example.phone"),
                                 (ANDROID + "versionCode", "150"),
                                 (ANDROID + "versionName", "9.9")):
            with self.subTest(attribute=attribute):
                root = ET.fromstring(MANIFEST)
                root.set(attribute, value)
                with self.assertRaises(ValueError):
                    check_manifest(ET.tostring(root), 155, "google-play-tv")
        for attribute, value in (("debuggable", "true"), ("allowBackup", "true"), ("banner", "")):
            with self.subTest(attribute=attribute):
                root = ET.fromstring(MANIFEST)
                root.find("application").set(ANDROID + attribute, value)
                with self.assertRaises(ValueError):
                    check_manifest(ET.tostring(root), 155, "google-play-tv")

    def test_launcher_must_be_exported_with_main_in_same_filter(self):
        for old, new in (('android:exported="true"', 'android:exported="false"'),
                         ("android.intent.category.LEANBACK_LAUNCHER", "android.intent.category.LAUNCHER"),
                         ("android.intent.action.MAIN", "android.intent.action.VIEW"),
                         ('<category ', '</intent-filter><intent-filter><category ')):
            with self.subTest(old=old), self.assertRaisesRegex(ValueError, "LEANBACK_LAUNCHER"):
                check_manifest(MANIFEST.replace(old, new), 155, "google-play-tv")

    def test_phone_bundle_keeps_leanback_optional_and_needs_launcher(self):
        phone = MANIFEST.replace('android:required="true"', 'android:required="false"').replace(
            '<category android:name="android.intent.category.LEANBACK_LAUNCHER"/>',
            '<category android:name="android.intent.category.LAUNCHER"/>\n'
            '        <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>')
        result = check_manifest(phone, 155, "google-play-mobile")
        self.assertFalse(result["leanbackRequired"])
        with self.assertRaisesRegex(ValueError, "leanback must explicitly require=false"):
            check_manifest(MANIFEST.replace("LEANBACK_LAUNCHER",
                                            'LAUNCHER"/><category android:name="android.intent.category.LEANBACK_LAUNCHER'),
                           155, "google-play-mobile")
        without_phone_launcher = MANIFEST.replace('android:required="true"', 'android:required="false"')
        with self.assertRaisesRegex(ValueError, "MAIN/LAUNCHER"):
            check_manifest(without_phone_launcher, 155, "google-play-mobile")

    def test_invalid_profile_is_rejected(self):
        with self.assertRaises(ValueError):
            check_manifest(MANIFEST, 155, "google-play-tvv")


class SignatureTests(unittest.TestCase):
    def test_old_and_new_apksigner_formats(self):
        for label in ("Signer #1", "V2 Signer:", "V3.1 Signer:"):
            with self.subTest(label=label):
                check_apk_signer(f"Number of signers: 1\n{label} certificate SHA-256 digest: {EXPECTED_SIGNER.lower()}\n")

    def test_source_stamp_public_key_or_wrong_signer_is_not_certificate(self):
        for line in (f"Source Stamp Signer certificate SHA-256 digest: {EXPECTED_SIGNER}",
                     f"Signer #1 public key SHA-256 digest: {EXPECTED_SIGNER}",
                     f"Signer #1 certificate SHA-256 digest: {'0' * 64}", ""):
            with self.subTest(line=line), self.assertRaises(ValueError):
                check_apk_signer(f"Number of signers: 1\n{line}\n")
        with self.assertRaises(ValueError):
            check_apk_signer(f"Number of signers: 2\nSigner #1 certificate SHA-256 digest: {EXPECTED_SIGNER}\n")

    def test_aab_requires_positive_integrity_and_exact_certificate(self):
        cert = "SHA256: " + ":".join(EXPECTED_SIGNER[i:i + 2] for i in range(0, 64, 2)) + "\n"
        check_aab_signer("jar verified.\n", cert)
        for verification, certificates in (("jar is unsigned.\n", cert),
                                             ("jar verified.\nThis jar contains unsigned entries.\n", cert),
                                             ("jar verified.\n", ""),
                                             ("jar verified.\n", cert + cert)):
            with self.subTest(verification=verification, certificates=certificates):
                with self.assertRaises(ValueError):
                    check_aab_signer(verification, certificates)


if __name__ == "__main__":
    unittest.main()
