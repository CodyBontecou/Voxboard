import importlib.util
import tempfile
import unittest
from pathlib import Path
import zipfile

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
        self.apk = self.root / "app-debug.apk"
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
        with zipfile.ZipFile(self.apk, "w") as archive:
            for abi, (elf_class, machine) in VALIDATOR.VOX_ELF_TARGETS.items():
                header = bytearray(64)
                header[:6] = b"\x7fELF" + bytes((elf_class, 1))
                header[16:18] = (3).to_bytes(2, "little")
                header[18:20] = machine.to_bytes(2, "little")
                archive.writestr(f"lib/{abi}/{VALIDATOR.VOX_LIBRARY}", header)
                archive.writestr(f"lib/{abi}/{VALIDATOR.JNA_LIBRARY}", header)

    def validate(self):
        VALIDATOR.validate_merged_manifest(self.manifest)
        VALIDATOR.validate_backup_rules(self.legacy, self.modern)
        VALIDATOR.validate_vox_native_libraries(self.apk)

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

    def test_non_literal_or_resource_exported_value_is_rejected(self):
        for value in ("@bool/provider_exported", "TRUE", "1"):
            with self.subTest(value=value):
                self.write_valid_inputs()
                text = self.manifest.read_text().replace(
                    "</application>",
                    f'<provider android:name="third.party.Provider" android:exported="{value}" />\n  </application>',
                )
                self.manifest.write_text(text)
                with self.assertRaisesRegex(VALIDATOR.ValidationError, "non-literal android:exported"):
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

    def test_missing_vox_abi_is_rejected(self):
        with zipfile.ZipFile(self.apk, "w") as archive:
            archive.writestr("lib/arm64-v8a/libvox_core_uniffi.so", b"\x7fELF" + bytes(60))
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "ABI set differs"):
            self.validate()

    def test_missing_jna_runtime_abi_is_rejected(self):
        with zipfile.ZipFile(self.apk) as archive:
            entries = {name: archive.read(name) for name in archive.namelist() if name != "lib/x86/libjnidispatch.so"}
        self.apk.unlink()
        with zipfile.ZipFile(self.apk, "w") as archive:
            for name, contents in entries.items():
                archive.writestr(name, contents)
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "JNA native ABI set differs"):
            self.validate()

    def test_wrong_vox_elf_machine_is_rejected(self):
        self.write_valid_inputs()
        with zipfile.ZipFile(self.apk, "a") as archive:
            # Rebuilding avoids duplicate-entry ambiguity while mutating only x86's machine.
            entries = {name: archive.read(name) for name in archive.namelist()}
        self.apk.unlink()
        data = bytearray(entries["lib/x86/libvox_core_uniffi.so"])
        data[18:20] = (62).to_bytes(2, "little")
        entries["lib/x86/libvox_core_uniffi.so"] = data
        with zipfile.ZipFile(self.apk, "w") as archive:
            for name, contents in entries.items():
                archive.writestr(name, contents)
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "x86 Vox ELF machine differs"):
            self.validate()

    def test_incomplete_transfer_exclusions_are_rejected(self):
        self.modern.write_text(self.modern.read_text().replace(
            '    <exclude domain="device_sharedpref" path="." />', "", 1,
        ))
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "cloud-backup exclusions"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
