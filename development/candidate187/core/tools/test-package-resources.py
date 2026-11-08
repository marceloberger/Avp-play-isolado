#!/usr/bin/env python3
"""Resource-only tests: never create an app or compile application sources."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('packaging_resources', TOOLS / 'package-resources.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ResourcePackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bundle = Path(os.environ['AVPPLAY_TEST_CORE_BUNDLE'])
        cls.runtime = Path(os.environ['AVPPLAY_TEST_OPTIONAL_RUNTIME'])
        cls.support = Path(os.environ['AVPPLAY_TEST_SUPPORT_RESOURCES'])
        cls.accessor = Path(os.environ['AVPPLAY_TEST_RESOURCE_ACCESSOR'])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='avp-resource-test-')
        self.root = Path(self.temp.name)
        self.contents = self.root / 'staging/Contents'

    def tearDown(self):
        self.temp.cleanup()

    def test_copies_exact_resources_for_gui_and_cli_and_pinned_sdk(self):
        module.install(self.bundle, self.runtime, self.contents, self.support)
        for location in ['Resources', 'Helpers']:
            copied = self.contents / location / module.BUNDLE
            module.validate_bundle(copied)
            for source in self.bundle.rglob('*'):
                if source.is_file():
                    self.assertEqual(module.sha(source), module.sha(copied / source.relative_to(self.bundle)))
        self.assertEqual(module.sha(self.contents / 'Resources/optional-runtime/surreal-sdk.tar.gz'), module.sdk_hash())

    def test_rejects_missing_core_resource_before_writing(self):
        altered = self.root / module.BUNDLE
        shutil.copytree(self.bundle, altered)
        resources = altered / 'Contents/Resources'
        if not resources.is_dir():
            resources = altered
        (resources / 'tls168-overlay.json').unlink()
        with self.assertRaises(ValueError):
            module.install(altered, self.runtime, self.contents, self.support)
        self.assertFalse(self.contents.exists())

    def test_rejects_corrupt_tls_payload(self):
        altered = self.root / module.BUNDLE
        shutil.copytree(self.bundle, altered)
        resources = altered / 'Contents/Resources'
        if not resources.is_dir():
            resources = altered
        (resources / 'tls168-kl_x18.c.txt').write_bytes(b'corrupt fixture')
        with self.assertRaises(ValueError):
            module.install(altered, self.runtime, self.contents, self.support)
        self.assertFalse(self.contents.exists())

    def test_rejects_missing_or_corrupt_sdk_before_writing(self):
        runtime = self.root / 'runtime'
        runtime.mkdir()
        for data in [None, b'corrupt fixture']:
            if data:
                (runtime / 'surreal-sdk.tar.gz').write_bytes(data)
            with self.assertRaises(ValueError):
                module.install(self.bundle, runtime, self.contents, self.support)
            self.assertFalse(self.contents.exists())

    def test_refuses_overwriting_resources(self):
        module.install(self.bundle, self.runtime, self.contents, self.support)
        with self.assertRaises(ValueError):
            module.install(self.bundle, self.runtime, self.contents, self.support)

    def test_recipe_fingerprints_are_static_reference_metadata(self):
        import json
        references = json.loads((self.support / 'recipes/fingerprints/verified.json').read_text())
        self.assertEqual(len(references), 46)
        for entry in references:
            self.assertEqual(set(entry), {'id', 'title', 'features', 'imported', 'extensions'})
        self.assertEqual(len(module.CONTRACT['features']), 23)

    def test_850_archive_and_all_2116_payload_hashes(self):
        self.assertEqual(module.validate_runtime(self.runtime), 2116)

    def test_every_required_packaged_file_is_mandatory(self):
        module.install(self.bundle, self.runtime, self.contents, self.support)
        for name in module.packaged_files():
            path = self.contents / name
            held = path.with_name(path.name + '.held')
            path.rename(held)
            try:
                with self.assertRaises(ValueError, msg=name):
                    module.validate_packaged(self.contents)
            finally:
                held.rename(path)
        for location in ['Resources', 'Helpers']:
            bundle = self.contents / location / module.BUNDLE
            resources = bundle / 'Contents/Resources'
            if not resources.is_dir():
                resources = bundle
            for name in module.CONTRACT['core']:
                path = resources / name
                held = path.with_name(path.name + '.held')
                path.rename(held)
                try:
                    with self.assertRaises(ValueError, msg=location + '/' + name):
                        module.validate_bundle(bundle)
                finally:
                    held.rename(path)

    def test_rejects_corrupt_850_archive_or_sidecar(self):
        for name in ['klepton-toolchain-850-cc2856c.tar.gz', 'klepton-toolchain-850-cc2856c.tar.gz.json']:
            runtime = self.root / name.replace('.', '_')
            shutil.copytree(self.runtime, runtime)
            (runtime / name).write_bytes(b'corrupt fixture')
            with self.assertRaises(ValueError):
                module.validate_runtime(runtime)

    def test_rejects_corrupt_remote_and_recipe(self):
        module.install(self.bundle, self.runtime, self.contents, self.support)
        for name in ['Resources/optional-remote/source.tar.gz', 'Resources/recipes/' + next(iter(module.CONTRACT['recipes']))]:
            path = self.contents / name
            original = path.read_bytes()
            path.write_bytes(b'corrupt fixture')
            try:
                with self.assertRaises(ValueError):
                    module.validate_packaged(self.contents)
            finally:
                path.write_bytes(original)

    def test_new_module_reference_requires_explicit_contract(self):
        from unittest.mock import patch
        contract = dict(module.CONTRACT)
        contract['core'] = dict(contract['core'])
        del contract['core']['tls168-overlay.json']
        with patch.object(module, 'CONTRACT', contract):
            with self.assertRaises(ValueError):
                module.validate_references()

    def test_real_generated_bundle_module_accessor_without_build_tree_fallback(self):
        module.install(self.bundle, self.runtime, self.contents, self.support)
        # Compile only the existing Swift-generated accessor plus a standalone probe.
        # No application code, executable app bundle or provision/install operation.
        probe = self.root / 'main.swift'
        probe.write_text('''import Foundation
import CryptoKit
guard Bundle.module.bundleURL.deletingLastPathComponent().lastPathComponent == "Helpers" else { fatalError("build tree fallback") }
let gui = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
for name in CommandLine.arguments.dropFirst(2) {
    for bundle in [Bundle.module, gui] {
        guard let url = bundle.url(forResource: name, withExtension: nil) else { fatalError(name) }
        let bytes = try Data(contentsOf: url)
        print(name + " " + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
''')
        executable = self.contents / 'Helpers/resource-probe'
        subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(self.root / 'module-cache'), str(self.accessor), str(probe), '-o', str(executable)], check=True, capture_output=True, text=True)
        names = [p.name for p in (module.CORE / 'Sources/AVPPlayCore/Resources').iterdir() if p.is_file()]
        result = subprocess.run([str(executable), str(self.contents / 'Resources' / module.BUNDLE)] + names,
                                env={k:v for k,v in os.environ.items() if not k.startswith('PACKAGE_RESOURCE_BUNDLE_')}, check=True, capture_output=True, text=True)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 2 * len(names))
        for line in lines:
            name, digest = line.split()
            self.assertEqual(digest, module.sha(module.CORE / 'Sources/AVPPlayCore/Resources' / name))


if __name__ == '__main__':
    unittest.main(verbosity=2)
