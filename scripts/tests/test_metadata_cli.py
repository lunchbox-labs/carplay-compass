"""Execute the real CLI boundary with an offline HTTP transport and ephemeral key."""
import base64
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import metadata_sync as metadata
from test_metadata_sync import FakeApple


class MetadataCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        locale = self.root / 'app-store/en-US'
        locale.mkdir(parents=True)
        (locale / 'description.txt').write_text('New description')
        key = self.root / 'fixture.p8'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt',
                        'ec_paramgen_curve:P-256', '-out', str(key)], check=True, capture_output=True)
        self.private = key.read_bytes()
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        subprocess.run(['git', '-C', str(self.root), '-c', 'user.name=Test', '-c',
                        'user.email=test@example.invalid', 'commit', '--allow-empty', '-qm', 'fixture'], check=True)
        self.sha = subprocess.check_output(['git', '-C', str(self.root), 'rev-parse', 'HEAD']).decode().strip()
        self.env = {
            'GITHUB_ACTIONS': 'true', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
            'GITHUB_REF': 'refs/heads/main', 'GITHUB_SHA': self.sha,
            'GITHUB_RUN_NUMBER': '17', 'GITHUB_RUN_ATTEMPT': '2',
            'METADATA_SOURCE_SHA': self.sha, 'METADATA_BUILD_NUMBER': '17.2',
            'METADATA_MARKETING_VERSION': '1.2.3',
            'ASC_METADATA_API_KEY_ID': 'TEST123',
            'ASC_METADATA_API_ISSUER_ID': '11111111-1111-4111-8111-111111111111',
            'ASC_METADATA_API_PRIVATE_KEY_BASE64': base64.b64encode(self.private).decode(),
        }
        self.apple = FakeApple()
        self.apple.app['attributes']['bundleId'] = 'dev.lunchbox-labs.carplay-compass'
        self.paths = []
        original = metadata.Token
        def token(key_id, issuer, key_path):
            self.paths.append(Path(key_path))
            self.assertEqual(Path(key_path).stat().st_mode & 0o777, 0o600)
            return original(key_id, issuer, key_path)
        self.token = token

    def run_cli(self):
        output = io.StringIO()
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(metadata, 'ROOT', self.root), \
                patch.object(metadata, 'Token', side_effect=self.token), \
                patch.object(metadata, 'build_opener', return_value=self.apple), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            result = metadata.main()
        self.assertTrue(all(not p.exists() for p in self.paths))
        self.assertNotIn(self.private.decode(), output.getvalue())
        self.assertNotIn(self.env.get('ASC_METADATA_API_PRIVATE_KEY_BASE64', 'SECRET'), output.getvalue())
        return result, output.getvalue()

    def test_manual_upload_identity_syncs_and_repeat_is_unchanged(self):
        result, output = self.run_cli()
        self.assertEqual(result, 0)
        self.assertEqual(self.apple.beta['attributes']['description'], 'New description')
        self.assertIn('UPDATED', output)
        self.apple.patches.clear()
        result, output = self.run_cli()
        self.assertEqual(result, 0)
        self.assertEqual(self.apple.patches, [])
        self.assertIn('UNCHANGED', output)

    def test_dedicated_key_is_required_without_upload_key_fallback(self):
        self.env['ASC_API_PRIVATE_KEY_BASE64'] = self.env.pop('ASC_METADATA_API_PRIVATE_KEY_BASE64')
        result, output = self.run_cli()
        self.assertEqual(result, 1)
        self.assertIn('ASC_METADATA_API_PRIVATE_KEY_BASE64', output)
        self.assertEqual(self.apple.calls, [])

    def test_wrong_event_build_or_checkout_fails_before_any_api_call(self):
        for field, value in [('GITHUB_EVENT_NAME', 'pull_request'), ('GITHUB_REF', 'refs/heads/feature'),
                             ('METADATA_BUILD_NUMBER', '18.1'), ('METADATA_SOURCE_SHA', 'a' * 40),
                             ('GITHUB_SHA', 'b' * 40)]:
            with self.subTest(field=field):
                saved = self.env[field]
                self.env[field] = value
                self.assertEqual(self.run_cli()[0], 1)
                self.env[field] = saved
                self.assertEqual(self.apple.calls, [])

    def test_stable_release_tag_must_match_archived_version(self):
        event = self.root / 'event.json'
        event.write_text(json.dumps({'action': 'published', 'release': {
            'draft': False, 'prerelease': False, 'tag_name': 'v1.2.3'}}))
        self.env.update(GITHUB_EVENT_NAME='release', GITHUB_REF='refs/tags/v1.2.3', GITHUB_EVENT_PATH=str(event))
        self.assertEqual(self.run_cli()[0], 0)
        self.apple.calls.clear()
        self.env['METADATA_MARKETING_VERSION'] = '1.2.4'
        self.assertEqual(self.run_cli()[0], 1)
        self.assertEqual(self.apple.calls, [])

    def test_key_is_removed_on_http_failure_and_private_error_not_printed(self):
        from urllib.error import HTTPError
        self.apple.overrides['/v1/apps'] = HTTPError('https://api.appstoreconnect.apple.com/v1/apps',
                                                  403, 'PRIVATE_ERROR', {}, io.BytesIO(b'PRIVATE_BODY'))
        result, output = self.run_cli()
        self.assertEqual(result, 1)
        self.assertIn('403', output)
        self.assertNotIn('PRIVATE_', output)
        self.assertTrue(self.paths)

    def test_actual_checkout_is_checked_even_when_run_and_output_sha_agree(self):
        self.env['GITHUB_SHA'] = self.env['METADATA_SOURCE_SHA'] = 'a' * 40
        self.assertEqual(self.run_cli()[0], 1)
        self.assertEqual(self.apple.calls, [])

    def test_noneditable_version_and_missing_beta_locale_are_explicit_skips(self):
        self.apple.version['attributes']['appVersionState'] = 'READY_FOR_DISTRIBUTION'
        self.apple.beta['attributes']['locale'] = 'fr-FR'
        result, output = self.run_cli()
        self.assertEqual(result, 0)
        self.assertEqual(self.apple.patches, [])
        self.assertIn('SKIP TestFlight app en-US', output)
        self.assertIn('SKIP App Store version 1.2.3', output)

    def test_termination_unwinds_and_removes_private_key(self):
        with patch.object(self.apple, 'open', side_effect=KeyboardInterrupt):
            self.assertEqual(self.run_cli()[0], 1)
        self.assertTrue(self.paths)

    def test_bad_private_key_is_sanitized_before_network(self):
        self.env['ASC_METADATA_API_PRIVATE_KEY_BASE64'] = 'INVALID-SECRET'
        result, output = self.run_cli()
        self.assertEqual(result, 1)
        self.assertEqual(self.apple.calls, [])
        self.assertNotIn('INVALID-SECRET', output)

    def test_metadata_only_retry_keeps_original_accepted_build_identity(self):
        self.env['GITHUB_RUN_ATTEMPT'] = '3'
        self.assertEqual(self.run_cli()[0], 0)
