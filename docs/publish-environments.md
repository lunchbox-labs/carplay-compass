# Publish environments

The build-upload job uses **`app-store-publish`**. The metadata-sync change in
PR #109 adds a separate **`app-store-metadata`** job after an accepted upload.
Configure both environments before running the workflow; this repository change
does not create environments, set protection rules, copy credentials or run Publish.

## Keep IDs in repository Actions variables

These identifiers do not need to move into an environment:

- `APPLE_TEAM_ID`
- `ASC_API_KEY_ID`
- `ASC_API_ISSUER_ID`
- `ASC_METADATA_API_KEY_ID` (metadata job)
- `ASC_METADATA_API_ISSUER_ID` (metadata job)

Keep the distinct metadata names so that the metadata job cannot accidentally use
the upload key's ID or issuer. Avoid defining duplicate variable names at different
scopes when the repository value is the intended source.

## Move secret values in stages

The upload job retains these **six** secret names:

| Environment | Secret | Contents |
| --- | --- | --- |
| `app-store-publish` | `ASC_API_PRIVATE_KEY_BASE64` | Base64-encoded upload API `.p8` key |
| `app-store-publish` | `IOS_DISTRIBUTION_P12_BASE64` | Base64-encoded distribution certificate/private-key `.p12` |
| `app-store-publish` | `IOS_DISTRIBUTION_P12_PASSWORD` | Password for that `.p12` |
| `app-store-publish` | `IOS_APP_PROFILE_BASE64` | Base64-encoded iPhone distribution profile |
| `app-store-publish` | `IOS_ACTIVITY_PROFILE_BASE64` | Base64-encoded Live Activity distribution profile |
| `app-store-publish` | `WATCH_APP_PROFILE_BASE64` | Base64-encoded Watch distribution profile |
| `app-store-metadata` | `ASC_METADATA_API_PRIVATE_KEY_BASE64` | Base64-encoded dedicated App Manager team API `.p8` key |

There are seven secret names across both jobs. Do not put the metadata key under
`ASC_API_PRIVATE_KEY_BASE64`; the metadata job uses only its dedicated name.

1. Create the environments in repository Settings. Configure any desired reviewers
   and deployment branch/tag rules, allowing the intended manual `main` and stable
   release-tag runs. Environment rules can require approval or block a job.
2. Keep the existing upload repository secrets while adding whichever retained
   values are available to `app-store-publish`. The matching environment secret
   takes precedence; a missing name continues to resolve to the repository secret.
3. Add the dedicated metadata private key to `app-store-metadata` and its IDs to
   repository Actions variables. Do not create a repository-level fallback with
   the metadata secret name if environment-only storage is intended.
4. After the intended environment values are installed and a deliberately initiated
   workflow run validates them, remove the superseded repository upload secrets.
   Do not delete a fallback until that secret has been migrated. Secret names are
   unchanged, so copying only some values does not require workflow edits.

GitHub cannot show the saved value of an existing secret. Reuse the current upload
API key if its original `.p8` file is available and it remains valid; moving it to
an environment does not require recreating it. Apple permits downloading that
private key only once. If its `.p8` is unavailable, leave the existing secret in
place until a replacement key is prepared. Update the matching ID/issuer and key
together, validate the replacement, then revoke the old key when appropriate.
Do not revoke the working key just to move its GitHub storage location.

The dedicated metadata key needs App Manager permissions. Upload signing secrets
and metadata credentials remain in separate job environments; neither job configures
or changes API-key permissions.

References: [GitHub secret precedence](https://docs.github.com/en/actions/reference/security/secrets),
[GitHub environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
and [Apple API-key downloads](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api).
