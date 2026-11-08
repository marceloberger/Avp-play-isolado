#!/usr/bin/env python3
"""Copy validated Core/Surreal resources into an existing staging Contents directory."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
from pathlib import PurePosixPath

CORE = Path(__file__).resolve().parents[1]
BUNDLE = "AVPPlay_AVPPlayCore.bundle"
CONTRACT = json.loads((CORE / "tools/packaging-resources.json").read_text())


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else digest_stream(stream)


def digest_stream(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(8 << 20), b''):
        digest.update(block)
    return digest.hexdigest()


def validate_bundle(bundle):
    resources = bundle / 'Contents/Resources'
    if not resources.is_dir():
        resources = bundle
    validate_files(resources, CONTRACT['core'])
    overlay = json.loads((resources / 'tls168-overlay.json').read_text())
    for entry in overlay['files']:
        if sha(resources / entry['resource']) != entry['correctedSHA256']:
            raise ValueError('TLS168 payload hash mismatch: ' + entry['resource'])


def sdk_hash():
    source = (CORE / 'Sources/AVPPlayCore/Runtime850.swift').read_text()
    return re.search(r'sdkArchiveSHA256 = "([a-f0-9]{64})"', source)[1]


def validate_files(root, files):
    # Check every required path first, so a removed input cannot silently shrink an inventory.
    for name in files:
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise ValueError('Missing or redirected resource: ' + name)
    for name, expected in files.items():
        if sha(root / name) != expected:
            raise ValueError('Resource SHA-256 mismatch: ' + name)


def archive_inventory(archive):
    result = {}
    with tarfile.open(archive) as stream:
        for member in stream:
            path = PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or member.issym() or member.islnk():
                raise ValueError('Unsafe archive member: ' + member.name)
            if not member.isfile() or any(p.startswith('._') or p in ['__MACOSX', '.DS_Store'] for p in path.parts):
                continue
            name = str(path)
            if name in result:
                raise ValueError('Duplicate archive member: ' + name)
            result[name] = digest_stream(stream.extractfile(member))
    return result


def validate_runtime(runtime):
    validate_files(runtime, CONTRACT['runtime'])
    code = (CORE / 'Sources/AVPPlayCore/Runtime850.swift').read_text()
    archive = re.search(r'archiveName = "([^"]+)"', code)[1]
    expected_hash = re.search(r'archiveSHA256 = "([a-f0-9]{64})"', code)[1]
    if sha(runtime / archive) != expected_hash or sha(runtime / 'surreal-sdk.tar.gz') != sdk_hash():
        raise ValueError('Pinned runtime/SDK hash mismatch')
    manifest = json.loads((runtime / (archive + '.json')).read_text())
    if (manifest['commit'], manifest['version'], manifest['sha256'], manifest['size']) != ('cc2856c', 850, expected_hash, (runtime / archive).stat().st_size):
        raise ValueError('850 archive sidecar mismatch')
    actual = archive_inventory(runtime / archive)
    sdk = archive_inventory(runtime / 'surreal-sdk.tar.gz')
    commit = re.search(r'sdkCommit = "([^"]+)"', code)[1]
    framework = re.search(r'sdkName = "([^"]+)"', code)[1] + '.xcframework'
    prefix = 'SwiftSDKBinary-' + commit + '/'
    destination = 'visionos/Frameworks/' + framework + '/'
    for name, digest in sdk.items():
        if name.startswith(prefix + framework + '/'):
            actual[destination + name[len(prefix + framework + '/'):]] = digest
    # These two files are created exactly this way by OptionalRuntime850.install.
    actual[destination + 'LICENSE'] = sdk[prefix + 'LICENSE']
    actual[destination + '.klepton-fetched-' + commit] = hashlib.sha256(b'').hexdigest()
    expected = json.loads((CORE / 'Sources/AVPPlayCore/Resources/runtime177-source850.json').read_text())
    if len(expected) != 2116 or actual != expected:
        raise ValueError('850/SDK payload differs from the pinned 2116-file manifest')
    return len(expected)


def validate_references():
    resources = CONTRACT['core']
    for source in (CORE / 'Sources').rglob('*.swift'):
        for name in re.findall(r'Bundle\.main\.resourceURL\?\.appendingPathComponent\("([^"]+)"', source.read_text()):
            if name not in CONTRACT['main_resource_references']:
                raise ValueError('Unclassified main bundle reference: ' + name)
        for name, ext in re.findall(r'Bundle\.module\.url\(forResource: "([^"]+)", withExtension: "([^"]+)"', source.read_text()):
            if name + '.' + ext not in resources:
                raise ValueError('Unclassified Bundle.module reference: ' + name)
    for overlay in ['tls168-overlay.json', 'tls170-overlay.json']:
        for entry in json.loads((CORE / 'Sources/AVPPlayCore/Resources' / overlay).read_text())['files']:
            if entry['resource'] not in resources or resources[entry['resource']] != entry['correctedSHA256']:
                raise ValueError('Unclassified or corrupt TLS payload: ' + entry['resource'])
    features = json.loads((CORE.parent / 'provenance/features23.json').read_text())
    if [f['id'] for f in features] != CONTRACT['features'] or len(features) != 23:
        raise ValueError('Feature inventory differs from packaging contract')


def validate_inputs(bundle, runtime, support):
    validate_references()
    if bundle is not None:
        validate_bundle(bundle)
    validate_files(CORE / 'Sources/AVPPlayCore/Resources', CONTRACT['core'])
    validate_files(CORE.parent / 'recipes', CONTRACT['recipes'])
    validate_runtime(runtime)
    validate_files(support, CONTRACT['support'])
    checksum = (support / 'optional-remote/source.sha256').read_text().split()[0]
    if checksum != sha(support / 'optional-remote/source.tar.gz'):
        raise ValueError('Remote source checksum mismatch')


def packaged_files():
    files = {'Resources/optional-runtime/' + p: h for p, h in CONTRACT['runtime'].items()}
    files.update({'Resources/' + p: h for p, h in CONTRACT['support'].items()})
    files.update({'Resources/recipes/' + p: h for p, h in CONTRACT['recipes'].items()})
    return files


def validate_packaged(contents):
    validate_files(contents, packaged_files())
    for location in ['Resources', 'Helpers']:
        validate_bundle(contents / location / BUNDLE)
    validate_runtime(contents / 'Resources/optional-runtime')


def install(bundle, runtime, contents, support):
    validate_inputs(bundle, runtime, support)
    destinations = [contents / 'Resources' / BUNDLE, contents / 'Helpers' / BUNDLE]
    files = packaged_files()
    if any(path.exists() or path.is_symlink() for path in destinations + [contents / p for p in files]):
        raise ValueError('Refusing to replace existing packaged resources')
    for destination in destinations:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(bundle, destination, symlinks=False)
    for source, inventory, prefix in [
        (runtime, CONTRACT['runtime'], 'Resources/optional-runtime'),
        (support, CONTRACT['support'], 'Resources'),
        (CORE.parent / 'recipes', CONTRACT['recipes'], 'Resources/recipes')]:
        for name in inventory:
            destination = contents / prefix / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, destination)
    validate_packaged(contents)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-archive', type=Path)
    parser.add_argument('--preflight', action='store_true')
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--runtime-resources', type=Path)
    parser.add_argument('--support-resources', type=Path)
    parser.add_argument('--contents', type=Path)
    args = parser.parse_args()
    if args.preflight:
        if args.runtime_resources is None or args.support_resources is None:
            parser.error('runtime-resources and support-resources are required')
        validate_inputs(None, args.runtime_resources, args.support_resources)
    elif args.check_archive:
        name = 'klepton-toolchain-850-cc2856c.tar.gz'
        validate_files(args.check_archive.parent, {
            args.check_archive.name: CONTRACT['runtime'][name],
            args.check_archive.name + '.json': CONTRACT['runtime'][name + '.json']})
    else:
        if any(value is None for value in [args.bundle, args.runtime_resources, args.contents, args.support_resources]):
            parser.error('bundle, runtime-resources, support-resources and contents are required')
        install(args.bundle, args.runtime_resources, args.contents, args.support_resources)
