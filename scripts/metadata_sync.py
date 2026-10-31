"""Update only supplied localization copy; never submit, distribute or create resources."""
import base64
import json
import os
import signal
import sys
import tempfile
from pathlib import Path
import plistlib
import re
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid

ORIGIN = 'https://api.appstoreconnect.apple.com'
FIELDS = {
    'appStoreVersionLocalizations': {'description', 'keywords', 'promotionalText', 'whatsNew'},
    'betaAppLocalizations': {'description'},
    'betaBuildLocalizations': {'whatsNew'},
}
FILES = {'description.txt': ('description', 4000),
         'promotional-text.txt': ('promotionalText', 170),
         'keywords.txt': ('keywords', 100),
         'whats-new.txt': ('whatsNew', 4000),
         'what-to-test.txt': ('whatToTest', 4000)}
EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED'}


class MetadataError(ValueError):
    """A fixed diagnostic safe to print; never carries response bodies or credentials."""


def require(condition, message):
    if not condition:
        raise MetadataError(message)


def identifier(value):
    require(isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9-]+', value),
            'Invalid metadata resource identity.')
    return value


def read_copy(root):
    """Missing files are untouched; a present blank file is an error, not an erase request."""
    root = Path(root)
    require(root.is_dir(), 'The repository metadata directory is missing.')
    result = {}
    for directory in sorted(root.iterdir()):
        if not directory.is_dir():
            continue
        locale = directory.name
        require(re.fullmatch(r'[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*', locale),
                'Invalid metadata locale directory.')
        fields = {}
        for filename, (field, maximum) in FILES.items():
            path = directory / filename
            if not path.exists():
                continue
            try:
                value = path.read_text(encoding='utf-8').strip()
            except (OSError, UnicodeError):
                raise MetadataError('Cannot read repository metadata text.') from None
            size = len(value.encode('utf-8')) if field == 'keywords' else len(value)
            require(value and size <= maximum and '\x00' not in value,
                    'Empty, invalid or overlong metadata file: ' + locale + '/' + filename)
            fields[field] = value
        if fields:
            result[locale] = fields
    return result


def uploaded_identity(archive, bundle_id, build_number):
    """Read the exact archived app rather than the project defaults or a latest-build lookup."""
    paths = list((Path(archive) / 'Products/Applications').glob('*.app/Info.plist'))
    require(len(paths) == 1, 'Expected one archived app for metadata identity.')
    try:
        info = plistlib.loads(paths[0].read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise MetadataError('Cannot read archived app metadata identity.') from None
    require(info.get('CFBundleIdentifier') == bundle_id
            and info.get('CFBundleVersion') == build_number,
            'Archived app does not match the uploaded bundle and build.')
    version = info.get('CFBundleShortVersionString')
    require(isinstance(version, str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version),
            'Archived marketing version is invalid.')
    return version


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=')


def raw_signature(der):
    # OpenSSL returns ASN.1 SEQUENCE(INTEGER r, INTEGER s); ES256 JWT requires 32-byte r || s.
    require(len(der) >= 6 and der[0] == 0x30 and der[1] == len(der) - 2,
            'Invalid metadata signing result.')
    offset, parts = 2, []
    for _ in range(2):
        require(offset + 2 <= len(der) and der[offset] == 0x02,
                'Invalid metadata signing result.')
        length = der[offset + 1]
        offset += 2
        value = der[offset:offset + length]
        require(0 < length <= 33 and len(value) == length and value[0] < 128,
                'Invalid metadata signing result.')
        value = value.lstrip(b'\x00')
        require(len(value) <= 32, 'Metadata signing requires a P-256 key.')
        parts.append(value.rjust(32, b'\x00'))
        offset += length
    require(offset == len(der), 'Invalid metadata signing result.')
    return b''.join(parts)


class Token:
    """Team-key JWT. Credentials are supplied by the caller and never logged."""
    def __init__(self, key_id, issuer, key_path, now=time.time):
        require(re.fullmatch(r'[A-Z0-9]+', key_id or ''), 'Metadata API key ID is missing or invalid.')
        try:
            uuid.UUID(issuer)
        except (ValueError, TypeError, AttributeError):
            raise MetadataError('Metadata API issuer ID is missing or invalid.') from None
        self.key_id, self.issuer, self.key_path = key_id, issuer, Path(key_path)
        self.now, self.expires, self.value = now, 0, None

    def __call__(self):
        now = int(self.now())
        if self.value and now < self.expires - 60:
            return self.value
        header = {'alg': 'ES256', 'kid': self.key_id, 'typ': 'JWT'}
        claims = {'iss': self.issuer, 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'}
        message = b'.'.join(b64url(json.dumps(v, separators=(',', ':')).encode()) for v in (header, claims))
        try:
            signed = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', str(self.key_path)],
                                    input=message, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise MetadataError('Metadata token signing could not complete.') from None
        require(signed.returncode == 0, 'Metadata token signing failed.')
        self.value = (message + b'.' + b64url(raw_signature(signed.stdout))).decode('ascii')
        self.expires = now + 600
        return self.value


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise MetadataError('Unexpected metadata API redirect; no credentials forwarded.')


class Client:
    def __init__(self, token, opener=None):
        self.token = token
        self.opener = opener or build_opener(NoRedirects())

    def request(self, method, path, params=None, payload=None):
        url = path if path.startswith('https://') else ORIGIN + path
        parsed = urlsplit(url)
        require(parsed.scheme == 'https' and parsed.netloc == 'api.appstoreconnect.apple.com'
                and parsed.path.startswith('/v1/') and not parsed.fragment,
                'Unexpected metadata API URL; no credentials forwarded.')
        if params:
            url += '?' + urlencode(params)
        request = Request(url, method=method,
                          headers={'Authorization': 'Bearer ' + self.token(),
                                   'Content-Type': 'application/json', 'Accept': 'application/json'},
                          data=json.dumps(payload).encode() if payload is not None else None)
        try:
            with self.opener.open(request, timeout=30) as response:
                data = response.read(2_000_001)
            require(len(data) <= 2_000_000, 'Metadata API response exceeded the size limit.')
            value = json.loads(data)
            require(isinstance(value, dict), 'Invalid metadata API response.')
            return value
        except HTTPError as error:
            if error.code in (401, 403):
                raise MetadataError('Metadata API HTTP ' + str(error.code)
                                    + ': verify the metadata key, App Manager role and app access.') from None
            raise MetadataError('Metadata API HTTP ' + str(error.code)
                                + '; earlier metadata changes may have succeeded.') from None
        except (URLError, TimeoutError, OSError, ValueError) as error:
            if isinstance(error, MetadataError):
                raise
            raise MetadataError('Metadata API request failed; earlier changes may have succeeded.') from None

    def collection(self, path, params=None):
        records, included, visited = [], [], set()
        for _ in range(20):
            require(path not in visited, 'Metadata API pagination repeated a page.')
            visited.add(path)
            value = self.request('GET', path, params=params)
            require(isinstance(value.get('data'), list), 'Invalid metadata collection response.')
            records.extend(value['data'])
            included.extend(value.get('included', []))
            path = value.get('links', {}).get('next')
            if not path:
                return records, included
            require(isinstance(path, str), 'Invalid metadata pagination link.')
            params = None
        raise MetadataError('Metadata API pagination exceeded the page limit.')

    def patch(self, kind, resource_id, attributes):
        require(kind in FIELDS and attributes and set(attributes) <= FIELDS[kind]
                and all(isinstance(v, str) and v.strip() for v in attributes.values()),
                'Refusing an unsupported or empty metadata update.')
        resource_id = identifier(resource_id)
        return self.request('PATCH', '/v1/' + kind + '/' + resource_id,
                            payload={'data': {'type': kind, 'id': resource_id,
                                              'attributes': attributes}})


def exact_one(records, predicate, label, optional=False):
    matches = [r for r in records if predicate(r)]
    require(len(matches) <= 1, 'Ambiguous ' + label + '; no automatic selection.')
    require(optional or matches, 'No exact ' + label + ' found.')
    return matches[0] if matches else None


def is_version(record, marketing_version):
    attributes = record.get('attributes', {})
    return (record.get('type') == 'appStoreVersions'
            and attributes.get('versionString') == marketing_version
            and attributes.get('platform') == 'IOS')


def editable(record):
    return record.get('attributes', {}).get('appVersionState') in EDITABLE


def processed_build(client, app_id, marketing_version, build_number, attempts, sleep):
    for attempt in range(attempts):
        builds, included = client.collection('/v1/builds', {
            'filter[app]': app_id, 'filter[version]': build_number,
            'filter[preReleaseVersion.version]': marketing_version,
            'include': 'preReleaseVersion,app', 'limit': 200})
        prereleases = {r['id']: r for r in included if r.get('type') == 'preReleaseVersions'}

        def matches(record):
            relationships = record.get('relationships', {})
            app = relationships.get('app', {}).get('data') or {}
            pre = relationships.get('preReleaseVersion', {}).get('data') or {}
            release = prereleases.get(pre.get('id'), {}).get('attributes', {})
            return (record.get('type') == 'builds' and app.get('id') == app_id
                    and record.get('attributes', {}).get('version') == build_number
                    and release.get('version') == marketing_version and release.get('platform') == 'IOS')

        build = exact_one(builds, matches, 'uploaded build', optional=True)
        if build:
            state = build.get('attributes', {}).get('processingState')
            if state == 'VALID':
                return identifier(build['id'])
            require(state == 'PROCESSING', 'The exact uploaded build failed processing or has an unknown state.')
        if attempt + 1 < attempts:
            sleep(30)
    raise MetadataError('The exact uploaded build is not processed yet. Upload remains accepted; metadata notes were not synced.')


def sync(client, copy, bundle_id, marketing_version, build_number, report=print,
         attempts=20, sleep=time.sleep):
    """Resolve all read targets before writing; PATCHes are idempotent but not transactional."""
    if not copy:
        report('SKIP metadata: no supplied repository fields.')
        return
    apps, _ = client.collection('/v1/apps', {'filter[bundleId]': bundle_id, 'limit': 200})
    app = exact_one(apps, lambda r: r.get('type') == 'apps'
                    and r.get('attributes', {}).get('bundleId') == bundle_id, 'app bundle ID')
    app_id = identifier(app['id'])
    plans = []

    def plan(kind, rows, locale, desired, label, version_id=None):
        target = exact_one(rows, lambda r: r.get('type') == kind
                           and r.get('attributes', {}).get('locale') == locale,
                           label + ' locale', optional=True)
        if not target:
            report('SKIP ' + label + ' ' + locale + ': locale is absent; create it in App Store Connect.')
            return
        changes = {k: v for k, v in desired.items() if target.get('attributes', {}).get(k) != v}
        if not changes:
            report('UNCHANGED ' + label + ' ' + locale)
            return
        plans.append((kind, identifier(target['id']), changes, label + ' ' + locale, version_id))

    if any('description' in fields for fields in copy.values()):
        rows, _ = client.collection('/v1/apps/' + app_id + '/betaAppLocalizations', {'limit': 200})
        for locale, fields in copy.items():
            if 'description' in fields:
                plan('betaAppLocalizations', rows, locale, {'description': fields['description']}, 'TestFlight app')

    if any(set(fields) & FIELDS['appStoreVersionLocalizations'] for fields in copy.values()):
        versions, _ = client.collection('/v1/apps/' + app_id + '/appStoreVersions', {
            'filter[platform]': 'IOS', 'filter[versionString]': marketing_version, 'limit': 200})
        version = exact_one(versions, lambda r: is_version(r, marketing_version),
                            'iOS marketing version', optional=True)
        if not version or not editable(version):
            report('SKIP App Store version ' + marketing_version + ': absent or not editable; no live-version fallback.')
        else:
            version_id = identifier(version['id'])
            rows, _ = client.collection('/v1/appStoreVersions/' + version_id + '/appStoreVersionLocalizations', {'limit': 200})
            for locale, fields in copy.items():
                desired = {k: v for k, v in fields.items() if k in FIELDS['appStoreVersionLocalizations']}
                if desired:
                    plan('appStoreVersionLocalizations', rows, locale, desired, 'App Store version', version_id)

    if any('whatToTest' in fields for fields in copy.values()):
        build_id = processed_build(client, app_id, marketing_version, build_number, attempts, sleep)
        rows, _ = client.collection('/v1/builds/' + build_id + '/betaBuildLocalizations', {'limit': 200})
        for locale, fields in copy.items():
            if 'whatToTest' in fields:
                plan('betaBuildLocalizations', rows, locale, {'whatsNew': fields['whatToTest']}, 'TestFlight build')
    else:
        report('SKIP TestFlight build notes: no what-to-test.txt supplied.')

    for kind, resource_id, changes, label, version_id in plans:
        if version_id:
            version = client.request('GET', '/v1/appStoreVersions/' + version_id).get('data', {})
            if not is_version(version, marketing_version) or not editable(version):
                report('SKIP ' + label + ': version is no longer editable or no longer matches.')
                continue
        client.patch(kind, resource_id, changes)
        report('UPDATED ' + label + ': ' + ', '.join(sorted(changes)))
    report('Metadata sync finished. Review explicit SKIP messages; no submission or distribution was requested.')


ROOT = Path(__file__).resolve().parents[1]


def workflow_identity():
    """Fail closed before reading credentials unless this is the accepted upload's checkout."""
    env = os.environ
    require(env.get('GITHUB_ACTIONS') == 'true', 'Run metadata sync in GitHub Actions.')
    version = env.get('METADATA_MARKETING_VERSION', '')
    build = env.get('METADATA_BUILD_NUMBER', '')
    sha = env.get('METADATA_SOURCE_SHA', '')
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version),
            'Missing or invalid accepted archive marketing version.')
    require(re.fullmatch(r'[1-9][0-9]{0,3}\.[1-9][0-9]?', build)
            and build.split('.')[0] == env.get('GITHUB_RUN_NUMBER')
            and int(build.split('.')[1]) <= int(env.get('GITHUB_RUN_ATTEMPT', '0')),
            'Metadata build does not match an accepted attempt of this upload run.')
    require(re.fullmatch(r'[a-f0-9]{40}', sha) and sha == env.get('GITHUB_SHA'),
            'Metadata source does not match this upload run.')
    checkout = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True,
                              timeout=10, check=False)
    require(checkout.returncode == 0 and checkout.stdout.decode().strip() == sha,
            'Metadata checkout does not match the uploaded source.')
    if env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch':
        require(env.get('GITHUB_REF') == 'refs/heads/main', 'Manual metadata sync requires main.')
    elif env.get('GITHUB_EVENT_NAME') == 'release':
        event = json.loads(Path(env['GITHUB_EVENT_PATH']).read_text())
        release = event.get('release', {})
        tag = release.get('tag_name', '')
        match = re.fullmatch(r'v?((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))', tag)
        require(event.get('action') == 'published' and release.get('draft') is False
                and release.get('prerelease') is False and match
                and env.get('GITHUB_REF') == 'refs/tags/' + tag and match.group(1) == version,
                'Metadata release must match the published stable tag and archived version.')
    else:
        raise MetadataError('Only manual main builds or published stable releases can sync metadata.')
    return version, build


def main():
    # Convert ordinary termination into unwinding so the private tempfile is removed.
    def interrupted(*_):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        version, build = workflow_identity()
        copy = read_copy(ROOT / 'app-store')
        require(bool(copy), 'No repository metadata fields supplied.')
        encoded = os.environ.pop('ASC_METADATA_API_PRIVATE_KEY_BASE64', '')
        require(bool(encoded), 'Missing ASC_METADATA_API_PRIVATE_KEY_BASE64 in app-store-metadata.')
        private = base64.b64decode(''.join(encoded.split()), validate=True)
        require(private.startswith(b'-----BEGIN PRIVATE KEY-----'), 'Invalid metadata private key encoding.')
        with tempfile.TemporaryDirectory(prefix='compass-metadata-') as temporary:
            path = Path(temporary) / 'AuthKey.p8'
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(private)
            token = Token(os.environ.get('ASC_METADATA_API_KEY_ID'),
                          os.environ.get('ASC_API_ISSUER_ID'), path)
            sync(Client(token), copy, 'dev.lunchbox-labs.carplay-compass', version, build)
        return 0
    except (Exception, KeyboardInterrupt) as error:
        detail = str(error) if isinstance(error, MetadataError) else 'Check metadata inputs and configuration.'
        print('Metadata sync failed: ' + detail
              + ' The build upload remains accepted; earlier metadata updates may have succeeded.', file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    sys.exit(main())
