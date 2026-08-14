import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "android_artifacts",
    ROOT / "apps/android/scripts/validate-debug-artifacts.py",
)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)

ANDROID_XMLNS = "http://schemas.android.com/apk/res/android"
DOMAINS = (
    "root", "file", "database", "sharedpref", "external", "device_root",
    "device_file", "device_database", "device_sharedpref",
)


class AndroidArtifactValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.manifest = self.root / "AndroidManifest.xml"
        self.legacy = self.root / "backup_rules.xml"
        self.modern = self.root / "data_extraction_rules.xml"
        self.write_valid_inputs()

    def tearDown(self):
        self.temporary.cleanup()

    def write_valid_inputs(self):
        self.manifest.write_text(f'''<manifest xmlns:android="{ANDROID_XMLNS}" package="md.vox.android">
  <permission android:name="md.vox.android.INTERNAL" android:protectionLevel="signature" />
  <uses-permission android:name="md.vox.android.INTERNAL" />
  <application android:allowBackup="false" android:fullBackupContent="@xml/backup_rules" android:dataExtractionRules="@xml/data_extraction_rules">
    <activity android:name="md.vox.android.MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
      </intent-filter>
    </activity>
  </application>
</manifest>''')
        exclusions = "\n".join(f'  <exclude domain="{domain}" path="." />' for domain in DOMAINS)
        self.legacy.write_text(f"<full-backup-content>\n{exclusions}\n</full-backup-content>\n")
        nested = "\n".join(f'    <exclude domain="{domain}" path="." />' for domain in DOMAINS)
        self.modern.write_text(
            f"<data-extraction-rules>\n  <cloud-backup>\n{nested}\n  </cloud-backup>\n"
            f"  <device-transfer>\n{nested}\n  </device-transfer>\n</data-extraction-rules>\n"
        )

    def validate(self):
        VALIDATOR.validate_merged_manifest(self.manifest)
        VALIDATOR.validate_backup_rules(self.legacy, self.modern)

    def test_valid_generated_signature_permission_is_allowed(self):
        self.validate()

    def test_platform_permission_is_rejected(self):
        text = self.manifest.read_text().replace(
            "<application",
            '<uses-permission android:name="android.permission.INTERNET" />\n  <application',
        )
        self.manifest.write_text(text)
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "platform permission"):
            self.validate()

    def test_unpermissioned_exported_transitive_component_is_rejected(self):
        text = self.manifest.read_text().replace(
            "</application>",
            '<service android:name="third.party.Exported" android:exported="true" />\n  </application>',
        )
        self.manifest.write_text(text)
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "unpermissioned exported"):
            self.validate()

    def test_workmanager_initializer_is_rejected(self):
        text = self.manifest.read_text().replace(
            "</application>",
            '<provider android:name="androidx.startup.InitializationProvider" android:exported="false">'
            '<meta-data android:name="androidx.work.WorkManagerInitializer" '
            'android:value="androidx.startup" /></provider></application>',
        )
        self.manifest.write_text(text)
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "WorkManager initializer"):
            self.validate()

    def test_incomplete_transfer_exclusions_are_rejected(self):
        self.modern.write_text(self.modern.read_text().replace(
            '    <exclude domain="device_sharedpref" path="." />', "", 1,
        ))
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "cloud-backup exclusions"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
