import copy
import io
import json
import base64
import plistlib
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import metadata_sync as metadata


def resource(kind, identifier, **attributes):
    return {'type': kind, 'id': identifier, 'attributes': attributes}


class FakeApple:
    """An HTTP boundary fake; assertions inspect actual JSON requests from the client."""
    def __init__(self):
        self.app = resource('apps', 'app1', bundleId='dev.example.compass')
        self.version = resource('appStoreVersions', 'version1', versionString='1.2.3',
                                platform='IOS', appVersionState='PREPARE_FOR_SUBMISSION')
        self.beta = resource('betaAppLocalizations', 'beta1', locale='en-US', description='Old beta')
        self.store = resource('appStoreVersionLocalizations', 'store1', locale='en-US',
                              description='Old store', promotionalText='Old promo', keywords='keep me')
        self.notes = resource('betaBuildLocalizations', 'notes1', locale='en-US', whatsNew='Old notes')
        self.build = resource('builds', 'build1', version='17.2', processingState='VALID')
        self.build['relationships'] = {
            'app': {'data': {'type': 'apps', 'id': 'app1'}},
            'preReleaseVersion': {'data': {'type': 'preReleaseVersions', 'id': 'pre1'}}}
        self.pre = resource('preReleaseVersions', 'pre1', version='1.2.3', platform='IOS')
        self.calls = []
        self.patches = []
        self.overrides = {}

    def open(self, request, timeout):
        path = urlsplit(request.full_url).path
        query = parse_qs(urlsplit(request.full_url).query)
        self.calls.append((request.method, path, query))
        if path in self.overrides:
            value = self.overrides[path]
            if isinstance(value, Exception):
                raise value
            if callable(value):
                value = value()
            return io.BytesIO(json.dumps(value).encode())
        if request.method == 'PATCH':
            payload = json.loads(request.data)['data']
            self.patches.append((path, copy.deepcopy(payload)))
            target = {'beta1': self.beta, 'store1': self.store, 'notes1': self.notes}[payload['id']]
            target['attributes'].update(payload['attributes'])
            return io.BytesIO(json.dumps({'data': target}).encode())
        values = {
            '/v1/apps': [self.app],
            '/v1/apps/app1/betaAppLocalizations': [self.beta],
            '/v1/apps/app1/appStoreVersions': [self.version],
            '/v1/appStoreVersions/version1': self.version,
            '/v1/appStoreVersions/version1/appStoreVersionLocalizations': [self.store],
            '/v1/builds/build1/betaBuildLocalizations': [self.notes],
        }
        if path == '/v1/builds':
            build = copy.deepcopy(self.build)
            if 'app' not in query.get('include', [''])[0].split(','):
                build['relationships']['app'] = {'links': {'related': '/v1/builds/build1/app'}}
            return io.BytesIO(json.dumps({'data': [build], 'included': [self.pre]}).encode())
        if path not in values:
            raise AssertionError('Unexpected API request: ' + path)
        return io.BytesIO(json.dumps({'data': values[path]}).encode())


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.locale = self.root / 'en-US'
        self.locale.mkdir()
        (self.locale / 'description.txt').write_text('New description\n')
        (self.locale / 'promotional-text.txt').write_text('New promo\n')
        self.apple = FakeApple()
        self.client = metadata.Client(lambda: 'fake-token', opener=self.apple)
        self.messages = []

    def sync(self, **kwargs):
        return metadata.sync(self.client, metadata.read_copy(self.root),
                             'dev.example.compass', '1.2.3', '17.2',
                             report=self.messages.append, attempts=2, sleep=lambda _: None, **kwargs)

    def test_supplied_fields_patch_only_their_scopes_and_repeat_is_noop(self):
        self.sync()
        self.assertEqual([p[0] for p in self.apple.patches],
                         ['/v1/betaAppLocalizations/beta1', '/v1/appStoreVersionLocalizations/store1'])
        self.assertEqual(self.apple.patches[0][1]['attributes'], {'description': 'New description'})
        self.assertEqual(self.apple.patches[1][1]['attributes'],
                         {'description': 'New description', 'promotionalText': 'New promo'})
        self.assertEqual(self.apple.store['attributes']['keywords'], 'keep me')
        self.assertFalse(any(path == '/v1/builds' for _, path, _ in self.apple.calls))
        self.apple.patches.clear()
        self.sync()
        self.assertEqual(self.apple.patches, [])

    def test_notes_bind_exact_processed_build_and_do_not_use_store_release_notes(self):
        (self.locale / 'what-to-test.txt').write_text('Test these changes')
        (self.locale / 'whats-new.txt').write_text('Release changes')
        self.sync()
        notes = next(p for p in self.apple.patches if p[0].startswith('/v1/betaBuildLocalizations/'))
        self.assertEqual(notes[1]['attributes'], {'whatsNew': 'Test these changes'})
        self.assertEqual(self.apple.store['attributes']['whatsNew'], 'Release changes')
        query = next(q for _, p, q in self.apple.calls if p == '/v1/builds')
        self.assertEqual(query['filter[app]'], ['app1'])
        self.assertEqual(query['filter[version]'], ['17.2'])
        self.assertEqual(query['filter[preReleaseVersion.version]'], ['1.2.3'])

    def test_wrong_build_or_app_or_marketing_version_never_receives_notes(self):
        (self.locale / 'what-to-test.txt').write_text('Only this build')
        for change in ('build', 'app', 'version', 'platform'):
            with self.subTest(change=change):
                self.apple = FakeApple()
                self.client = metadata.Client(lambda: 'fake-token', opener=self.apple)
                if change == 'build': self.apple.build['attributes']['version'] = '18.1'
                if change == 'app': self.apple.build['relationships']['app']['data']['id'] = 'other'
                if change == 'version': self.apple.pre['attributes']['version'] = '9.9.9'
                if change == 'platform': self.apple.pre['attributes']['platform'] = 'MAC_OS'
                with self.assertRaises(metadata.MetadataError): self.sync()
                self.assertEqual(self.apple.patches, [])

    def test_processing_is_bounded_and_failed_build_is_not_updated(self):
        (self.locale / 'what-to-test.txt').write_text('Only this build')
        for state in ('PROCESSING', 'FAILED', 'INVALID'):
            with self.subTest(state=state):
                self.apple.build['attributes']['processingState'] = state
                with self.assertRaises(metadata.MetadataError): self.sync()
                self.assertEqual(self.apple.patches, [])

    def test_missing_locale_and_noneditable_version_skip_without_creating_or_live_fallback(self):
        self.apple.beta['attributes']['locale'] = 'fr-FR'
        self.apple.version['attributes']['appVersionState'] = 'READY_FOR_DISTRIBUTION'
        self.sync()
        self.assertEqual(self.apple.patches, [])
        self.assertTrue(any('SKIP' in m and 'en-US' in m for m in self.messages))
        self.assertTrue(any('SKIP' in m and 'version' in m for m in self.messages))
        self.assertTrue(all(method == 'GET' for method, _, _ in self.apple.calls))

    def test_missing_version_and_missing_build_locale_are_explicit_skips(self):
        (self.locale / 'what-to-test.txt').write_text('Test this build')
        self.apple.overrides['/v1/apps/app1/appStoreVersions'] = {'data': []}
        self.apple.notes['attributes']['locale'] = 'fr-FR'
        self.sync()
        self.assertEqual([p[0] for p in self.apple.patches], ['/v1/betaAppLocalizations/beta1'])
        self.assertTrue(any('SKIP' in m and 'version' in m for m in self.messages))
        self.assertTrue(any('SKIP' in m and 'build' in m for m in self.messages))

    def test_permission_failure_does_not_leak_body_or_patch_after_failed_planning(self):
        for status in (401, 403):
            self.apple.overrides['/v1/apps/app1/appStoreVersions'] = HTTPError(
                'https://api.appstoreconnect.apple.com/v1/apps/app1/appStoreVersions',
                status, 'private diagnostic', {}, io.BytesIO(b'sensitive response'))
            with self.assertRaisesRegex(metadata.MetadataError, str(status)) as raised: self.sync()
            self.assertNotIn('sensitive', str(raised.exception))
            self.assertNotIn('private', str(raised.exception))
            self.assertEqual(self.apple.patches, [])

    def test_version_becoming_noneditable_before_patch_does_not_get_listing_update(self):
        changed = copy.deepcopy(self.apple.version)
        changed['attributes']['appVersionState'] = 'READY_FOR_DISTRIBUTION'
        self.apple.overrides['/v1/appStoreVersions/version1'] = {'data': changed}
        self.sync()
        self.assertEqual([p[0] for p in self.apple.patches], ['/v1/betaAppLocalizations/beta1'])

    def test_absent_fields_and_locales_are_not_cleared_and_empty_files_fail(self):
        (self.locale / 'description.txt').unlink()
        self.sync()
        self.assertEqual([p[0] for p in self.apple.patches], ['/v1/appStoreVersionLocalizations/store1'])
        self.assertEqual(self.apple.patches[0][1]['attributes'], {'promotionalText': 'New promo'})
        (self.locale / 'promotional-text.txt').write_text(' \n')
        with self.assertRaises(metadata.MetadataError): metadata.read_copy(self.root)

    def test_wrong_app_and_duplicate_exact_version_fail_before_mutations(self):
        self.apple.app['attributes']['bundleId'] = 'other.app'
        with self.assertRaises(metadata.MetadataError): self.sync()
        self.assertEqual(self.apple.patches, [])
        self.apple.app['attributes']['bundleId'] = 'dev.example.compass'
        self.apple.overrides['/v1/apps/app1/appStoreVersions'] = {
            'data': [self.apple.version, self.apple.version]}
        with self.assertRaises(metadata.MetadataError): self.sync()
        self.assertEqual(self.apple.patches, [])

    def test_client_rejects_external_pagination_and_nonmetadata_patches(self):
        self.apple.overrides['/v1/apps'] = {
            'data': [self.apple.app], 'links': {'next': 'https://attacker.invalid/v1/apps'}}
        with self.assertRaises(metadata.MetadataError): self.sync()
        self.assertEqual(len(self.apple.calls), 1)
        with self.assertRaises(metadata.MetadataError):
            self.client.patch('appStoreVersions', 'version1', {'appVersionState': 'READY_FOR_REVIEW'})
        with self.assertRaises(metadata.MetadataError):
            self.client.patch('betaAppLocalizations', 'beta1', {'description': ''})

    def test_missing_build_relationship_fails_closed(self):
        (self.locale / 'what-to-test.txt').write_text('Test this build')
        self.apple.build['relationships']['app'] = {'links': {'related': '/v1/builds/build1/app'}}
        with self.assertRaises(metadata.MetadataError): self.sync()
        self.assertEqual(self.apple.patches, [])

    def test_processing_build_can_become_valid_before_notes_are_written(self):
        self.apple.build['attributes']['processingState'] = 'PROCESSING'
        sleeps = []
        def advance(seconds):
            sleeps.append(seconds)
            self.assertEqual(self.apple.patches, [])
            self.apple.build['attributes']['processingState'] = 'VALID'
        result = metadata.processed_build(self.client, 'app1', '1.2.3', '17.2', 2, advance)
        self.assertEqual(result, 'build1')
        self.assertEqual(sleeps, [30])

    def test_patch_failure_keeps_prior_changes_and_does_not_report_completion(self):
        self.apple.overrides['/v1/appStoreVersionLocalizations/store1'] = HTTPError(
            'https://api.appstoreconnect.apple.com/v1/appStoreVersionLocalizations/store1',
            403, 'private diagnostic', {}, io.BytesIO(b'sensitive response'))
        with self.assertRaisesRegex(metadata.MetadataError, '403'): self.sync()
        self.assertEqual(self.apple.beta['attributes']['description'], 'New description')
        self.assertEqual(self.apple.store['attributes']['description'], 'Old store')
        self.assertFalse(any('finished' in message for message in self.messages))

    def test_keyword_limit_counts_utf8_bytes_and_other_limits_count_characters(self):
        (self.locale / 'keywords.txt').write_text('é' * 50, encoding='utf-8')
        (self.locale / 'promotional-text.txt').write_text('é' * 170, encoding='utf-8')
        self.assertEqual(metadata.read_copy(self.root)['en-US']['keywords'], 'é' * 50)
        (self.locale / 'keywords.txt').write_text('é' * 51, encoding='utf-8')
        with self.assertRaises(metadata.MetadataError): metadata.read_copy(self.root)


class IdentityAndAuthenticationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_archive_identity_must_match_upload(self):
        info = self.root / 'Products/Applications/Compass.app/Info.plist'
        info.parent.mkdir(parents=True)
        data = {'CFBundleIdentifier': 'dev.example.compass', 'CFBundleVersion': '17.2',
                'CFBundleShortVersionString': '1.2.3'}
        info.write_bytes(plistlib.dumps(data))
        self.assertEqual(metadata.uploaded_identity(self.root, 'dev.example.compass', '17.2'), '1.2.3')
        for bundle, build in [('other.app', '17.2'), ('dev.example.compass', '18.1')]:
            with self.assertRaises(metadata.MetadataError):
                metadata.uploaded_identity(self.root, bundle, build)
        data['CFBundleShortVersionString'] = 'invalid-version'
        info.write_bytes(plistlib.dumps(data))
        with self.assertRaises(metadata.MetadataError):
            metadata.uploaded_identity(self.root, 'dev.example.compass', '17.2')

    def test_jwt_signature_verifies_offline_and_refreshes_before_expiry(self):
        # Ephemeral local fixture only: never an App Store Connect credential.
        private, public = self.root / 'fixture.pem', self.root / 'fixture.pub'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt',
                        'ec_paramgen_curve:P-256', '-out', str(private)],
                       check=True, capture_output=True)
        subprocess.run(['openssl', 'pkey', '-in', str(private), '-pubout', '-out', str(public)],
                       check=True, capture_output=True)
        now = [1_000_000]
        issuer = '11111111-1111-4111-8111-111111111111'
        token = metadata.Token('TEST123', issuer, private, now=lambda: now[0])
        value = token()
        header, claims, signature = value.split('.')
        decode = lambda part: base64.urlsafe_b64decode(part + '=' * (-len(part) % 4))
        self.assertEqual(json.loads(decode(header)), {'alg': 'ES256', 'kid': 'TEST123', 'typ': 'JWT'})
        self.assertEqual(json.loads(decode(claims)),
                         {'iss': issuer, 'iat': now[0], 'exp': now[0] + 600, 'aud': 'appstoreconnect-v1'})
        raw = decode(signature)
        self.assertEqual(len(raw), 64)
        integers = []
        for part in (raw[:32], raw[32:]):
            part = part.lstrip(b'\x00') or b'\x00'
            if part[0] >= 128: part = b'\x00' + part
            integers.append(b'\x02' + bytes([len(part)]) + part)
        sequence = b''.join(integers)
        signature_path = self.root / 'signature.der'
        signature_path.write_bytes(b'\x30' + bytes([len(sequence)]) + sequence)
        result = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public),
                                 '-signature', str(signature_path)],
                                input=(header + '.' + claims).encode(), capture_output=True)
        self.assertEqual(result.returncode, 0)
        now[0] += 539
        self.assertEqual(token(), value)
        now[0] += 1
        refreshed = json.loads(decode(token().split('.')[1]))
        self.assertEqual(refreshed['iat'], now[0])

    def test_signing_and_redirect_failures_do_not_include_private_diagnostics(self):
        token = metadata.Token('TEST123', '11111111-1111-4111-8111-111111111111',
                               self.root / 'sensitive-name-missing-key')
        with self.assertRaises(metadata.MetadataError) as raised: token()
        self.assertNotIn('sensitive', str(raised.exception))
        with self.assertRaises(metadata.MetadataError):
            metadata.NoRedirects().redirect_request(None, None, 302, '', {}, 'https://other.invalid')
        for signature in (b'', b'\x30\x00', b'\x30\x06\x02\x01\xff\x02\x01\x01'):
            with self.assertRaises(metadata.MetadataError): metadata.raw_signature(signature)


if __name__ == '__main__':
    unittest.main()
