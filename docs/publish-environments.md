# Publish environments

The build-upload job uses **`app-store-publish`**. The metadata-sync change in
PR #109 adds a separate **`app-store-metadata`** job after an accepted upload.
Configure both environments before running the workflow; this repository change
does not create environments, set protection rules, copy credentials or run Publish.

## Keep API key IDs with their environments

Add each nonsecret key ID as an environment **Variable**, alongside its
private-key **Secret**:

| Environment | Variables |
| --- | --- |
| `app-store-publish` | `ASC_DEVELOPER_API_KEY_ID` |
| `app-store-metadata` | `ASC_METADATA_API_KEY_ID` |

Both team keys belong to the same App Store Connect account, so keep one shared
`ASC_API_ISSUER_ID` as a repository Actions variable. Do not duplicate it in either
environment. Sharing the issuer does not share private keys or key permissions.
Other nonsecret configuration, including `APPLE_TEAM_ID`, can also stay in repository
Actions variables.

The upload and metadata steps read their key IDs and the shared issuer through
`vars` after their jobs select the matching environments. These values are not
resolved in workflow-level or job-level `env`. Keep each key ID matched to its
private key. Retain existing repository key-ID copies until the environment-selecting
workflow is in use and its key-ID variables are configured; then remove obsolete
key-ID copies to avoid ambiguity. Keep the shared repository issuer variable.

The distinct metadata key-ID and private-key names prevent accidental fallback to
the upload key.

## Move secret values in stages

The upload job uses these **six** secret names:

| Environment | Secret | Contents |
| --- | --- | --- |
| `app-store-publish` | `ASC_DEVELOPER_API_PRIVATE_KEY_BASE64` | Base64-encoded upload API `.p8` key |
| `app-store-publish` | `IOS_DISTRIBUTION_P12_BASE64` | Base64-encoded distribution certificate/private-key `.p12` |
| `app-store-publish` | `IOS_DISTRIBUTION_P12_PASSWORD` | Password for that `.p12` |
| `app-store-publish` | `IOS_APP_PROFILE_BASE64` | Base64-encoded iPhone distribution profile |
| `app-store-publish` | `IOS_ACTIVITY_PROFILE_BASE64` | Base64-encoded Live Activity distribution profile |
| `app-store-publish` | `WATCH_APP_PROFILE_BASE64` | Base64-encoded Watch distribution profile |
| `app-store-metadata` | `ASC_METADATA_API_PRIVATE_KEY_BASE64` | Base64-encoded dedicated App Manager team API `.p8` key |

There are seven secret names across both jobs. Do not put the metadata key under
`ASC_DEVELOPER_API_PRIVATE_KEY_BASE64`; the metadata job uses only its dedicated name.

1. Create the environments in repository Settings. Configure any desired reviewers
   and deployment branch/tag rules, allowing the intended manual `main` and stable
   release-tag runs. Environment rules can require approval or block a job.
2. Configure `ASC_DEVELOPER_API_KEY_ID` and `ASC_DEVELOPER_API_PRIVATE_KEY_BASE64`
   in `app-store-publish` before using this workflow revision. The former
   `ASC_API_KEY_ID` and `ASC_API_PRIVATE_KEY_BASE64` names are no longer read; the
   renamed API credential has no fallback to those old names. Reuse the existing
   Developer key's retained values if appropriate.
   Keep the existing non-API signing repository secrets while copying whichever
   values are available into the environment under the same names. For those
   signing secrets, an environment value takes precedence and a missing name
   continues to resolve to its repository value.
3. Add the dedicated metadata private key and matching key-ID Variable to
   `app-store-metadata`. Both jobs use the shared repository issuer variable. Do not create a repository-level fallback with
   the metadata secret name if environment-only storage is intended.
4. After the intended environment values are installed and a deliberately initiated
   workflow run validates them, remove the superseded repository upload secrets.
   Do not delete a fallback until that secret has been migrated. Non-API signing secret names are unchanged, so those values can move in stages.

GitHub cannot show the saved value of an existing secret. Reuse the current upload
API key if its original `.p8` file is available and it remains valid; moving it to
an environment does not require recreating it. Apple permits downloading that
private key only once. If its `.p8` is unavailable, leave the existing secret in
place until a replacement key is prepared. Update the matching key ID and private key together; the issuer stays shared for
the same account. Validate the replacement, then revoke the old key when appropriate.
Do not revoke the working key just to move its GitHub storage location.

The dedicated metadata key needs App Manager permissions. Environment-only isolation
is incomplete while repository upload-secret copies remain available to other
workflows. After those copies are removed, upload signing secrets and metadata
credentials reside in their separate job environments. Neither job configures or
changes API-key permissions.

References: [GitHub secret precedence](https://docs.github.com/en/actions/reference/security/secrets),
[GitHub environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
and [Apple API-key downloads](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api).
