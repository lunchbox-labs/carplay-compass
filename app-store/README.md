# Listing metadata

Each locale directory contains the copy supplied to App Store Connect. Only files
that exist are considered; missing files leave the corresponding Apple fields
unchanged. A blank or overlong file fails validation instead of clearing a field.

| File | Destination | Limit |
| --- | --- | --- |
| `description.txt` | App Store version description and app-wide TestFlight description | 4,000 characters |
| `promotional-text.txt` | App Store version promotional text | 170 characters |
| `keywords.txt` | App Store version keywords | 100 UTF-8 bytes |
| `whats-new.txt` | App Store version release notes | 4,000 characters |
| `what-to-test.txt` | Exact uploaded TestFlight build's “What to Test” | 4,000 characters |

The last three files are optional. Release notes and testing instructions are
separate fields; one is never substituted for the other. The description affects
the app-wide TestFlight listing, including existing beta builds.

Sync resolves the exact app bundle ID, archived marketing version, build number
and locale. App Store copy is updated only for an existing iOS version in
`PREPARE_FOR_SUBMISSION`, `DEVELOPER_REJECTED`, `REJECTED` or `METADATA_REJECTED`.
The version is checked again before each listing update. A missing or noneditable
version, or a missing localization, produces an explicit `SKIP`; there is no
fallback to another version and no automatic version or localization creation.

If `what-to-test.txt` exists, sync waits for the exact uploaded build to finish
processing, checking at most 20 times, 30 seconds apart. It never selects the
latest build. No build polling is needed when this file is absent. A processing
timeout requires checking the accepted build in App Store Connect; uploading
another build is not necessary just to edit its testing instructions.

Only changed, supplied fields are patched. Repeating a sync with identical
contents makes no updates. API permission failures and other request errors fail
the sync; changes already accepted by Apple cannot be rolled back automatically.
The build upload remains accepted even if a later metadata update fails. Review
`UPDATED`, `UNCHANGED` and `SKIP` messages to determine which fields were synced.
The sync never submits for review, releases, distributes to testers, changes
groups or changes version states.

Combined listing and TestFlight editing requires an App Manager key with access
to the app. A Developer key that can upload builds is insufficient. Verify the
actual key's role before enabling sync; an upload succeeding does not prove
metadata permissions. No API keys, roles or App Store resources are configured
by these scripts.

Run the offline tests with:

```sh
python3 -m unittest discover -s scripts/tests -v
```

Apple references: [version fields and limits](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information),
[TestFlight information permissions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information),
[app information permissions](https://developer.apple.com/help/app-store-connect/create-an-app-record/view-and-edit-app-information),
and [build matching](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds).

## Publish configuration

The Publish workflow runs metadata sync in a separate `metadata` job only after
its upload job succeeds. It checks out the uploaded source commit and uses the
marketing version read from the accepted archive and that run's exact build
number. Both jobs accept manual main builds and published stable version tags.
An environment approval can delay metadata sync without changing the uploaded
build identity. Retrying only the metadata job uses the original upload outputs;
the identity guard accepts its original build attempt without selecting a newer
build. Re-running the entire workflow uploads a new build as usual.

Create the GitHub environment **`app-store-metadata`** and keep its API key IDs
as environment Variables alongside its private-key Secret:

| Kind | Name | Value |
| --- | --- | --- |
| Environment variable | `ASC_METADATA_API_KEY_ID` | Dedicated App Store Connect team API key ID |
| Environment variable | `ASC_METADATA_API_ISSUER_ID` | Its issuer UUID |
| Environment secret | `ASC_METADATA_API_PRIVATE_KEY_BASE64` | Base64-encoded contents of its `.p8` private key |

Use a dedicated App Manager team key. These credentials are passed only to the
metadata API step, with no fallback to the upload key. The step reads the IDs
through `vars` after the job selects `app-store-metadata`; they are not resolved
in workflow-level or job-level `env`. Configure the environment's
reviewers and branch/tag protections as appropriate before publishing. Existing
upload credentials and iPhone, Live Activity and Watch signing profiles are
unchanged. This PR does not create an environment or configure keys.

The private key is decoded into a restricted temporary file and removed on normal
completion, errors and ordinary termination. Logs omit credentials and Apple
response bodies. Offline checks use ephemeral test keys and a fake HTTP boundary;
actual Apple permissions and remote edits are verified only when Publish runs.
