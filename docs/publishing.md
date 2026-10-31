# Publishing

For maintainers preparing App Store and TestFlight builds. Publish runs manually
from `main` or when a stable release is published; merging a PR does not run it.
Configure the environments and their branch/tag restrictions and approvals before
running Publish. The workflow does not configure credentials or permissions.

## Credentials and signing

Keep these key IDs as environment Variables and private keys as environment Secrets:

| Environment | Variable | Secret | Apple role |
| --- | --- | --- | --- |
| `app-store-publish` | `ASC_DEVELOPER_API_KEY_ID` | `ASC_DEVELOPER_API_PRIVATE_KEY_BASE64` | Developer for uploads |
| `app-store-metadata` | `ASC_METADATA_API_KEY_ID` | `ASC_METADATA_API_PRIVATE_KEY_BASE64` | App Manager for listing and TestFlight edits |

Private-key secrets contain base64-encoded `.p8` contents. Both team keys share
repository Variable `ASC_API_ISSUER_ID`; keep `APPLE_TEAM_ID` as a repository
Variable too. Match each key ID to its private key. Metadata has no fallback to
the upload key, and the upload script does not read the former `ASC_API_KEY_ID`
or `ASC_API_PRIVATE_KEY_BASE64` names. Verify the metadata key's actual role and
app access: successful build upload does not prove permission to edit listings.

The upload environment also needs these signing Secrets:

| Secret | Contents |
| --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | Base64 distribution certificate and private-key `.p12` |
| `IOS_DISTRIBUTION_P12_PASSWORD` | Password for that `.p12` |
| `IOS_APP_PROFILE_BASE64` | Base64 iPhone distribution profile |
| `IOS_ACTIVITY_PROFILE_BASE64` | Base64 Live Activity distribution profile |
| `WATCH_APP_PROFILE_BASE64` | Base64 Watch distribution profile |

Profiles must match the app's identifiers, entitlements and signing certificate,
including Apple's approved CarPlay capability. Never commit credential values.
GitHub uses a same-named repository secret if an environment secret is absent;
environment-only isolation therefore requires removing repository duplicates after
validating their replacements. Do not create a repository fallback for the metadata
private key. Environment restrictions must allow the intended `main` and release tags.

Keep original private keys securely: GitHub cannot reveal stored secret values and
Apple permits downloading a `.p8` only once. Moving storage does not require key
rotation. When replacing a key, validate its matching ID and secret before revoking
the old key.

## Release copy

Edit `app-store/<locale>/` before uploading the build that should use the copy.
The metadata job uses the uploaded commit, not newer edits on `main`.

| File | Destination | Limit |
| --- | --- | --- |
| `description.txt` | App Store description and app-wide TestFlight description | 4,000 characters |
| `promotional-text.txt` | App Store promotional text | 170 characters |
| `keywords.txt` | App Store keywords | 100 UTF-8 bytes |
| `whats-new.txt` | App Store release notes | 4,000 characters |
| `what-to-test.txt` | Uploaded TestFlight build's testing instructions | 4,000 characters |

Missing files leave fields unchanged; blank or overlong files fail validation.
The TestFlight description also affects existing beta builds. Release notes and
testing instructions are separate fields, never substituted for each other.

After upload, sync updates only supplied, changed fields in existing localizations.
App Store edits require an existing editable iOS version matching the archive's
marketing version. Review `UPDATED`, `UNCHANGED` and `SKIP` messages: missing or
noneditable versions and missing locales are skipped. Create any needed version
or locale in App Store Connect. Sync does not create resources, submit for review
or distribute builds.

When testing instructions are supplied, sync waits up to about ten minutes for
the exact uploaded build to finish processing. A metadata failure does not undo
the accepted upload or earlier metadata edits. Check App Store Connect and the
job log before retrying. Re-run only the metadata job to retry the original build
and copy; re-running the entire workflow uploads another build.
