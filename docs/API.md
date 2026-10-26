# FX Vault - gh, git, ssh and az commands, and provider endpoints

FX Vault has no server API. Every GitHub operation is a child process: the GitHub CLI (`gh`),
`/usr/bin/git` or `/usr/bin/ssh`. This catalog is the implemented form of plan §8 and lives in
`Packages/FXVaultKit/Sources/GitHubKit`. Operation ids (`A1`, `B3`, `C5`, ...) are the raw
values of `GHOperation`; each builder's `logTemplate` (shown below) is the only form of a command
that is ever logged. Since v0.8.0 the runtime destinations (Azure Key Vault; Supabase and Vercel
until 1.0) are reached over HTTPS by `Packages/FXVaultKit/Sources/DestinationKit`, with Key Vault tokens
from `az` (section G).

## Conventions

- **Who runs it.** `GHCommandService.execute` runs one attempt through `CommandRunning`
  (`ProcessRunner` in the app, `FakeCommandRunner` in tests and previews). `GHCommandScheduler`
  (an actor, one per account) adds serialization, write throttling and retries on top.
- **Commands are closed.** `GHCommand` has an internal initializer: only the builders below can
  create one, so no caller can run arbitrary gh arguments or an arbitrary `gh api` path. Every
  command passes `GHArgumentPolicy`, which forbids `--body`/`-b`, `-f`/`-F`/`--field`/`--raw-field`,
  `--env-file`, `--no-store`, `--verbose`, `--show-token`, `--cache` and `--clone` (also in the
  `--flag=value` and attached short forms).
- **Names are validated first.** Owner, repository, environment and item names go through the
  VaultCore validators (`OwnerLoginValidator`, `RepoNameValidator`, `EnvironmentNameValidator`,
  `GitHubNameValidator`, `PathSegmentValidator`) before any argv exists. User-derived flag values
  use the `--flag=value` form: `--repo=<O>/<R>`, `--env=<E>`.
- **Values only on stdin.** Secret values, variable values and JSON bodies travel as a
  `StdinPayload` that the runner wipes after writing. A value never appears in argv or in the
  child's environment (property-tested over 200 random values).
- **One write per item, serial.** At most one command runs per account at a time. Writes are
  throttled to `Limits.writesPerMinute` (60) and `Limits.writesPerHour` (450), with
  `Timeouts.writeBatchGap` between writes once a batch exceeds `Limits.writeBatchGapThreshold`.
  A variable update costs `Limits.variableUpdateWriteCost` (2: gh POSTs, then PATCHes on 409).
  An hourly budget that would need more than a minute's wait throws `.writeBudgetExhausted`.
- **Success is exit code 0.** Native commands expose no HTTP status; stdout is parsed only on
  success and failures are classified from stderr plus the exit code (section E).
- **`gh api`** (written `API` below) is used only for the organization role (A6), environments,
  deployment branch policies and the repositories of a `selected` organization item (B14/B15),
  which no native command lists. It always sends `-H "Accept: application/vnd.github+json"`,
  `-H "X-GitHub-Api-Version: 2026-03-10"` and an explicit `-X <METHOD>`. `GitHubPath`
  percent-encodes each segment (ASCII unreserved set; `a/b c` becomes `a%2Fb%20c`) and throws on
  dot segments and their encoded forms. List reads use `--paginate --slurp`; single-object reads
  and writes add `-i` and are parsed by `APIResponseParser` (status line, kept headers, body).
  Bodies are sent with `--input -`.
- **Timeouts** (`Timeouts`): A4 `ghAuthToken` 60 s, A7 `ghAuthRefresh` 900 s (the device code's
  life; no code within `ghDeviceCodeWait` 20 s stops it), B1 `ghRepoList` 120 s, everything else
  `ghDefault` 30 s. On timeout the process group gets SIGTERM, then SIGKILL after
  `processKillGrace` (2 s).
- **Output caps:** stdout `Limits.maxStdoutBytes` (32 MiB), stderr `Limits.maxStderrBytes`
  (1 MiB). A truncated stdout is `.outputTooLarge`.

### Child process rules (`ProcessRunner`)

- `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` (the child inherits no descriptors), its own
  process group and reset signal masks. Exit is detected with `waitid(WNOWAIT)` before reaping,
  so signals can never reach a recycled pid.
- Working directory: `<Caches>/io.fractalx.fxvault/empty-cwd` (mode 0700, `EmptyWorkingDirectory`),
  so no repository-local configuration is picked up.
- stdin is written on its own thread with `F_SETNOSIGPIPE`; stdout is collected into a
  `SecretBytes` buffer that is zeroed whenever it grows. Callers wipe stdout after decoding.

### Child environments (`ProcessEnvironmentBuilder`)

Each child gets an exact allowlist, never the app's own environment.

| Child | Keys |
|---|---|
| gh | `HOME USER LOGNAME TMPDIR PATH LANG GH_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME GH_HOST GH_PROMPT_DISABLED GH_NO_UPDATE_NOTIFIER GH_NO_EXTENSION_UPDATE_NOTIFIER GH_PAGER PAGER NO_COLOR CLICOLOR GH_SPINNER_DISABLED GH_TELEMETRY DO_NOT_TRACK GH_TOKEN` (token only for operations that need it) |
| git | `HOME USER PATH SSH_AUTH_SOCK LANG GIT_TERMINAL_PROMPT GIT_CONFIG_NOSYSTEM GIT_SSH_COMMAND` (`/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15`) |
| ssh | `HOME USER PATH SSH_AUTH_SOCK LANG` |
| az (v0.8.0) | `HOME PATH LANG TMPDIR AZURE_CONFIG_DIR AZURE_CORE_COLLECT_TELEMETRY AZURE_CORE_NO_COLOR AZURE_CORE_ONLY_SHOW_ERRORS`, built by `AzureCLIRunner.environment`: PATH is the login shell's, `LANG=en_US.UTF-8`, telemetry `no`, color off, only errors shown; TMPDIR when known; `AZURE_CONFIG_DIR` only when one is configured (the app passes none, so `az` uses `~/.azure`) |

Never passed, even when set in the app's environment: `GH_DEBUG DEBUG GITHUB_TOKEN
GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO GH_FORCE_TTY CLICOLOR_FORCE GH_EDITOR
GH_BROWSER`.

## A. Discovery and auth

| Op | argv (`logTemplate`) | Builder | Notes |
|---|---|---|---|
| A1 version | `gh --version` | `GHLocator.versionCommand()` | `^gh version (\d+)\.(\d+)\.(\d+)`. Below `GHVersion.minimum` (2.97.0) is `.versionTooOld`. No token. Runs only on a trusted candidate: the decisive one, or every trusted one for diagnostics. |
| A2 shell probe | `<login shell> -i -l -c '<script>'`, then `-l -c`; csh/tcsh get `-i -c`, then `-c` (v0.3.1: interactive first) | `ShellEnvironmentResolver` | One shell-agnostic script made of absolute `/usr/bin/printf` and `/usr/bin/printenv` calls and one `/bin/sh -c '<report>'`, separated by `;`, between the markers `__FXV_B__` and `__FXV_E__`. Captures only `PATH GH_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME SSH_AUTH_SOCK`; PATH keeps absolute directories only, the others must be absolute paths. The report prints `FXV_GH=` + `command -v gh` (kept only as an absolute path ending in `/gh`) and `FXV_SET=<NAME>` for each of `GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR XDG_CONFIG_HOME GH_HOST` that is set and non-empty (sh's `[ -n ]` builtin: never a value). The second attempt runs on a timeout or missing markers. Environment `FXVAULT_RESOLVING_ENV=1`, `TERM=dumb`, empty stdin, 5 s per attempt. Records `probeMode` (`interactive`, `login`, `failed`) and the shell path; a failure captures nothing. Observed on macOS 27: `tcsh -i -c` does not set `prompt`, so `if ($?prompt)` blocks in `~/.tcshrc` stay unread (tcsh reads the rest of the file in both attempts). |
| A3 accounts | `gh auth status --hostname github.com --json hosts` | `GHAuthService.statusCommand()` | No token. `state` `success` is ok, `timeout` is offline; `error` is offline for network fragments, re-login for `HTTP 401`/`Bad credentials`, otherwise unexpected. `scopes` is split on `,` and trimmed; an absent or empty value is `.unknown`. `tokenSource` is kept (`keyring`, `oauth_token`, or a variable name). Logins must pass `OwnerLoginValidator`, which accepts Enterprise Managed User logins (`handle_shortcode`); any other entry is returned as a `GHUnusableAccountModel` with its `NameRule`, never dropped silently (v0.3.1). |
| A4 token | `gh auth token --hostname github.com --user={login}` | `GHAuthService.tokenCommand(login:)` | No token. Trimmed and cached in `GHTokenCache` (memory only, `purge()` on lock). |
| A7 refresh (1.0 B4b) | `gh auth refresh -h github.com -s {scopes}` | `GHAuthService.refreshCommand(scopes:)` / `approve(scopes:codeWait:onDeviceCode:)` | No token. Scopes from `GHApprovalScope` only, in its order. gh's active account only (`GitHubEnvironmentRepository.approveScopes`). stderr is watched for `one-time code: XXXX-XXXX` (ANSI stripped, TTY or not); exit 0 is approved, a timeout is `.timedOut`, a non-zero exit is `.failed` after a code and `.unrecognizedOutput` before one. Never logged beyond the template. |
| A5 orgs | `gh org list --limit 300` | `GHOrgsCommands.list()` | One login per line; each validated. Needs `read:org`, otherwise the list can be silently incomplete. |
| A6 org role (1.0) | `gh api -H … -X GET user/memberships/orgs/{org}` (`api GET user/memberships/orgs/{o}`) | `GHOrgsCommands.membership(organization:)` / `decodeMembership` | `state` and `role`; only an `active` `admin` manages organization secrets. `OrgAccessChecker` combines it with the account's scopes: the role first (a member gets "needs an org admin", which no scope fixes), then `admin:org`; SAML → `ssoRequired(url)`; a fine-grained token (no scopes) → `unknown`. A token, network or gh failure stops the read (`GHError.stopsAccountReads`); any other failure only affects that organization. |

`GHLocator.locate(overridePath:shell:trustedBinary:)` picks the binary
(`inspect(...)` returns the full `GHLocatorReportModel`): the override alone when set; otherwise
the gh the shell finds (`command -v gh` from A2, the gh Terminal runs), then Homebrew
(`/opt/homebrew/bin`, `/usr/local/bin`), the shell PATH, MacPorts, Nix and `~/.local/bin`. **The
first candidate that exists decides** (v0.3.1): it is used when it passes the trust check and the
version floor, otherwise detection fails with its reason; FX Vault never falls back to a gh behind
it. A candidate must be a regular executable file, owned by root or the user, not world-writable,
in a directory that is not world-writable. Group write is accepted only for the `wheel` and
`admin` groups (Homebrew's `/opt/homebrew/bin` is `drwxrwxr-x root:admin`). When one other
non-root user owns the file or its folders and nothing else is wrong, the user may trust it:
`GHTrustedBinaryModel{path, ownerUID}` (Settings, UserDefaults) makes that exact path acceptable
while every foreign owner is that uid. Symlinks are resolved;
`GHInstallationModel.hasChanged(fromResolvedPath:)` detects a changed binary.

## B. Read

| Op | argv (`logTemplate`) | Builder / decoder | Notes |
|---|---|---|---|
| B1 repos | `gh repo list {o} --limit 1000 --json <B1 fields>` | `GHReposCommands.list(owner:)` / `decodeList` | Fields: `id,name,nameWithOwner,owner,isPrivate,visibility,isArchived,isFork,viewerPermission,viewerCanAdminister,defaultBranchRef,sshUrl,createdAt`. Invalid names are skipped. `GHRepoDTO.makeRepoModel` maps to `RepoModel`. |
| B2 repo | `gh repo view {o}/{r} --json <B1 fields>` | `.view(_:)` / `decodeView` | Add by name, availability check, C1 follow-up. |
| B3 environments | `gh api -X GET repos/{o}/{r}/environments --paginate --slurp` | `GHEnvironmentsAPI.list(repo:)` / `decodeList` | `GHEnvironmentDTO`: policy kind, `foreignRulesJSON` (canonical JSON of protection rules other than branch policy). |
| B4 environment | `gh api -X GET -i repos/{o}/{r}/environments/{e}` | `.get(repo:environment:)` / `decodeEnvironment` | 404 means absent: `GHCommandScheduler.environment(_:named:)` returns nil. |
| B5 patterns | `gh api -X GET repos/{o}/{r}/environments/{e}/deployment-branch-policies --paginate --slurp` | `.listBranchPolicies` / `decodeBranchPolicies` | `GHBranchPolicyDTO`; a missing `type` means branch. |
| B6/B7 secrets | `gh secret list --repo={o}/{r} [--env={e}] --json name,updatedAt` | `GHSecretsCommands.list` / `decodeList` | gh follows every page. |
| B8/B9 variables | `gh variable list --repo={o}/{r} [--env={e}] --json name,value,updatedAt,createdAt` | `GHVariablesCommands.list` / `decodeList` | Values become `SecretBytes` (`GHVariableListingModel`); stdout is wiped. The JSON decoder's transient `String` copies cannot be wiped. `FXVAULT_SPACE`, the marker 0.9's shared spaces wrote, is dropped from every listing (`droppingSpaceMarker`; 1.0 never writes it, so a leftover marker never shows as a variable). |
| B12/B13 organization (1.0) | `gh secret list --org={o} --json name,updatedAt,visibility,numSelectedRepos`; the variable list with `--org={o}` and `name,value,updatedAt,createdAt,visibility,numSelectedRepos` | `GHSecretsCommands.list(organization:)`, `GHVariablesCommands.list(organization:)` / the same decoders | `visibility` is `all`, `private` (private and internal repositories) or `selected` (`OrgVisibility`); any other value is `malformedOutput`. Repository listings leave it nil. Needs `admin:org` (B4). |
| B14/B15 selected repositories (1.0) | `gh api -X GET orgs/{o}/actions/secrets/{n}/repositories --paginate --slurp` (`?per_page=100`); variables at `orgs/{o}/actions/variables/{n}/repositories` | `GHSecretsCommands.selectedRepositories(name:organization:)`, `GHVariablesCommands.selectedRepositories(name:organization:)` / `GHSecretsCommands.decodeSelectedRepositories` | Repository names, every page. A count other than `total_count` or an invalid name is `malformedOutput`: a C10/C12 built from a partial list would revoke the missing repositories. Only `selected` items have a list (GitHub answers 409 otherwise). |
| B10g / B10l | `gh repo gitignore list`, `gh repo license list` | `GHTemplatesCommands` | Plain text by line; license key column first. |

## C. Write

All writes are `isWrite`, journaled by the caller before they start, and never run twice in
parallel. Values and JSON bodies are on stdin.

| Op | argv (`logTemplate`) | Builder | Success and special cases |
|---|---|---|---|
| C1 create repo | `gh repo create {o}/{n} --private\|--public\|--internal [--description={d}] [--add-readme] [--gitignore={t}] [--license={l}]` | `GHReposCommands.create(_:)` / `decodeCreated` | Never `--clone`, **never retried**. stdout is one line, the new repo URL, which gives the normalized name. A `users/<owner>` 404 is `.validation`; "already exists" is `.validation`; org policy text is `.orgPolicyForbidsCreate`. |
| C2 env upsert | `gh api -X PUT -i repos/{o}/{r}/environments/{e} --input -` | `GHEnvironmentsAPI.upsert` | Body `{"deployment_branch_policy": null \| {"protected_branches":true,"custom_branch_policies":false} \| {false,true}}`. Never sends reviewers, wait timer or prevent-self-review, so preflight blocks it for an existing environment with such rules until Q6 is verified. |
| C3 pattern add | `gh api -X POST -i repos/{o}/{r}/environments/{e}/deployment-branch-policies --input -` | `.addBranchPolicy` | Body `{"name","type"}`. 200 returns the policy; a bare 303 (gh exits 1 with `gh: HTTP 303`) also counts as success and returns nil (the caller re-lists with B5). |
| C4 pattern delete | `gh api -X DELETE -i repos/{o}/{r}/environments/{e}/deployment-branch-policies/{id}` | `.deleteBranchPolicy` | 204; a 404 counts as done. |
| C5 secret set | `gh secret set {n} --repo={o}/{r} [--env={e}]` | `GHSecretsCommands.set` | Value on stdin (the builder copies it). Verified by the caller through B6/B7 `updatedAt`. |
| C6 secret delete | `gh secret delete {n} --repo={o}/{r} [--env={e}]` | `.delete` | A 404 is thrown as `.notFound`; the caller treats it as done only after a successful re-list of the same scope. |
| C7 variable set | `gh variable set {n} --repo={o}/{r} [--env={e}]` | `GHVariablesCommands.set(…isUpdate:)` | Upsert; write cost 2 when `isUpdate`. Empty values are rejected before argv. The reserved name `FXVAULT_SPACE` is refused here. |
| C8 variable delete | `gh variable delete {n} --repo={o}/{r} [--env={e}]` | `.delete` | As C6. |
| C10 org secret set (1.0) | `gh secret set {n} --org={o} --visibility=all\|private` or `--visibility=selected --repos={repos}` | `GHSecretsCommands.set(name:organization:access:value:)` | Value on stdin. `GHOrgRepositoryAccess` always sends the visibility (gh's default is `private`); `selected` needs a `GHSelectedRepositories`, which throws for an empty list, an invalid name or a duplicate. gh replaces GitHub's repository list with `--repos`, so it is always the complete synced list. Repository names stay out of the log. |
| C11 org secret delete (1.0) | `gh secret delete {n} --org={o}` | `GHSecretsCommands.delete(name:organization:)` | As C6, confirmed by B12. |
| C12 org variable set (1.0) | `gh variable set {n} --org={o} --visibility=…` as C10 | `GHVariablesCommands.set(name:organization:access:value:isUpdate:)` | Value on stdin, upsert and write cost as C7, visibility and repositories as C10. |
| C13 org variable delete (1.0) | `gh variable delete {n} --org={o}` | `GHVariablesCommands.delete(name:organization:)` | As C8, confirmed by B13. |
| C9 env delete | `gh api -X DELETE -i repos/{o}/{r}/environments/{e}` | `GHEnvironmentsAPI.delete` | 204; a 404 is `.notFound` until a B3 re-list confirms it. |

### Retries (`GHCommandScheduler.run`)

| Failure | Behaviour |
|---|---|
| `.tokenRevoked` | Refresh the token (A4) once; retry once only if the token changed. |
| `.rateLimited` | Wait `Timeouts.rateLimitBackoff` (60 s), at most `Limits.rateLimitRetries` (2) times. |
| `.serverError`, `.network`, `.timeout`, `.indeterminate` | Idempotent commands only: wait `Timeouts.idempotentRetryBackoff` (2 s), at most `Limits.idempotentRetries` (2) times. C1 is never retried. |
| anything else | Thrown to the caller. |

The command's stdin copy is wiped when `run` returns or throws.

## D. git and ssh

Every git call starts with the hardened prefix
`/usr/bin/git -c core.fsmonitor= -c core.hooksPath=/dev/null -c protocol.allow=never -c protocol.ssh.allow=always -C <dir>`.

| Op | argv | API | Notes |
|---|---|---|---|
| D1 resolve alias | `/usr/bin/ssh -G -- <alias>` | `SSHAliasResolver.resolveHostName(alias:)` | Reads `hostname`; `requireGitHubAlias` accepts only github.com. |
| D2 verify alias | `/usr/bin/ssh -T -o BatchMode=yes -o ConnectTimeout=10 -- git@<alias>` | `.verify(alias:)` | Exit 1 with `Hi <login>!` is `.authenticated(login:)`; also `permissionDenied`, `hostKeyUnknown`, `timeout`, `failed(exitCode:)`. |
| D3 clone | `git … clone -- git@<alias>:<O>/<N>.git <folder>/.<N>.fxvault-clone-<uuid>`, then an exclusive rename to `<folder>/<N>` | `GitService.clone(repo:alias:into:)` | Fails early if `<N>` exists. Exit 128 retried `Limits.cloneRetries` (3) times, `Timeouts.cloneRetryInterval` (3 s) apart, unless stderr shows `Permission denied`, `Repository not found` or `Host key verification failed`. On failure only the temp directory is removed. EPERM is `.folderAccessDenied`. |
| D4 repo root | `git … rev-parse --show-toplevel` | `repositoryRoot(containing:)` | |
| D5 ignored? | `git … check-ignore -q -- <rel>` | `isIgnored(relativePath:inRepository:)` | Exit 0 means ignored. |
| D6 tracked? | `git … ls-files --error-unmatch -- <rel>` | `isTracked(relativePath:inRepository:)` | Exit 0 means tracked. |

SSH aliases must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` (at most 253 characters).
`SSHConfigParser` reads `~/.ssh/config` and its `Include`s (cycles stop) and skips wildcard,
negated and unsafe host entries.

## E. Error classification (`GHStderrClassifier.classify`)

Input: operation, exit code, stderr with token patterns redacted (values are redacted only for
display), the `-i` status when present, and for `gh api -i` calls the `errors[]` details of the
response body (`APIResponseParser.errorDetails`, at most `GHConstants.maxErrorDetailCount`): gh
prints only the body's top-level `message` on stderr (see Observed behavior). Status sources:
native `HTTP (\d{3}): ` or `HTTP (\d{3}) \(` (gh's form for a response with no message)
anywhere in stderr; `gh api`'s `^gh: (.*) \(HTTP (\d{3})\)$` or
`^gh: HTTP (\d{3})$`; `GraphQL:` messages by fragment; the `-i` status line. Rules, in order:

1. 401 or "Bad credentials" → `.tokenRevoked` (before rule 2, because a native 401 also prints a
   `gh auth login` hint)
2. Exit 4 or "You are not logged into any GitHub hosts" → `.notAuthenticated`
3. "SAML" → `.samlRequired(URL?)` (only `https://github.com/...` URLs are kept)
4. 429, "secondary rate limit", "API rate limit exceeded" → `.rateLimited`
5. "Must have admin rights" → `.adminRequired`
6. "Resource not accessible" or "repository read permissions" → `.writeAccessRequired`;
   `needs the "<scope>" scope` or "missing required scopes" → `.missingScopes([String])`
7. C1 with an organization-policy message → `.orgPolicyForbidsCreate`
8. "billing plan" / plan upgrade text → `.planGated`
9. 404, "Not Found", "Could not resolve to a Repository" → `.notFound` (C1's `users/<owner>`
   lookup → `.validation`)
10. 422 or "already exists" → `.validation(<redacted first line>)`
11. 500/502/503/504 → `.serverError(status:)`
12. `dial tcp`, `no such host`, `connection refused`, `connection reset`, `i/o timeout`,
    `TLS handshake timeout`, `error connecting to `, `check your internet connection` → `.network`
13. Runner timeout: on a write → `.indeterminate`, on a read → `.timeout`
14. Anything else → `.unexpected(exitCode:)`

When stderr alone gives `.validation` or `.unexpected` and the body has details, the rules run
again on stderr plus the details; only a plan, admin, write-access, scope, SAML, rate-limit or
org-policy result from that second pass replaces the first (a detail can never turn a 422 into
`.notFound`). A `.validation` message then reads `<first stderr line>: <detail>; <detail>`.

Also from the service layer: a missing executable (ENOENT for the binary) → `.notInstalled`; a
missing working directory or other spawn failure → `.launchFailed`; truncated stdout →
`.outputTooLarge`; undecodable output → `.malformedOutput`; task cancellation → `.cancelled`.

The classifier table is `Tests/GitHubKitTests/Fixtures/gh/stderr-cases.json` (48 cases). Cases
marked `"synthetic": true` (org policy on create, plan gating, secondary and GraphQL rate limits,
the scope message, the GraphQL SAML link, the native 422) are educated guesses until the M3 write
spike re-records them.

`GHError.logCode` is the value-free code written to `sync_journal.error_code` and the log.
`StderrRedactor` masks classic (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`) and fine-grained
(`github_pat_`) token patterns, plus any plaintext value passed to it.

## F. Who runs what (SyncEngine and VaultData)

The builders above are only called through `GHCommandScheduler` operations; no caller builds
argv. Schedulers come from `GitHubEnvironmentRepository.scheduler(for:)` (one per account,
case-insensitive, seeded once from the journal's write start times over the last hour).

| Caller | Commands | Notes |
|---|---|---|
| `GitHubEnvironmentRepository` | A1–A4, D1, D2 | gh detection (shell probe, `GHLocator`, 2.97.0 floor), accounts and scopes, token cache (`purgeTokens()` on lock), SSH alias test (D1 must resolve to github.com, then D2) |
| `RepoCatalogRepository` | A5, B1, B2; import: B2, B3, B5, B6–B9 | One owner failing (SAML, not found) marks only that owner unavailable. An import read failing for permission, SAML or plan reasons marks only that scope unreadable; token, network and rate-limit failures stop the import |
| `SyncPreflight` | B2 (repository to create, journaled as a read), B3–B9 for every touched scope | D27 base checks; the pending-verification pass runs on the same re-list |
| `SyncExecutor` | C1–C9, then B-row re-lists | Order: C1, C2 upserts, C3/C4 patterns, guided renames, scope writes (repository first, variables before secrets), item deletes, C9. Before a scope's writes it re-lists the scope (D27 re-check, `pre_write_updated_at`); after them it verifies by re-listing every `Timeouts.verifyRetryInterval` (2 s) for up to `verifyRetryWindow` (60 s) |
| `SyncExecutor` (new repository) | B2 after C1 | Within `Timeouts.freshRepoWindow` (90 s) after C1, "not found" is retried every `freshRepoRetryInterval` (1 s) for up to `freshRepoRetryWindow` (60 s) and never classified as plan-gated |
| `SyncReconciler` | B2, B3–B9 | Launch reconciliation of `in_flight` / `indeterminate` journal rows by re-list; never by the local clock. A timed-out C1 is adopted only after the journaled "name is free" lookup and a B2 showing the expected owner and visibility |
| `DeletionPreviewLoader` | B4, B5, B7, B9 | §7.5 live contents of each environment to delete; "unknown" on failure |
| `DriftRepository` | B2–B9 | Full re-list on open (debounced `Timeouts.driftDebounce`, 2 min); a resolution re-reads the subject's scope and fails with `.stale` when it changed again |
| `RepoCreationRepository` | B2, B10g, B10l, D3 | Name availability, owner and template pickers (templates cached per account), clone through the mapped SSH alias |
| `SharingRepository` | B3, B5, B6–B9 (optional, `RemoteConfigReader`) | Lets the import plan show what GitHub already lists |

- **404 on deletes.** C6, C8 and C9 count a `.notFound` as done only after a successful re-list
  of the same scope (B3 for C9); a failed re-list leaves the change pending.
- **Status 303 on C3** counts as success; the executor re-lists B5 and records the policy ids.
- **One token refresh** per run on `.tokenRevoked`; rate limits back off twice, then the run
  stops with the rest pending (`SyncStopReason.rateLimited`).
- Tests use `FakeCommandRunner` (unmatched calls exit `unmatchedExitCode` with
  `unmatchedStderr`) and the stateful `GitHubSimulator` in the test-only `FXVaultTestSupport`
  target, which answers unscripted calls from simulated GitHub state in gh's output formats.

## Observed behavior

Recorded on 2026-10-15 with gh 2.102.0 on macOS 27 against github.com (API version
2026-03-10). Names are placeholders: `owner-a` is the gh account, `Example-Org` its Free-plan
organization. Only **read** calls were made; the write facts below are still open (see
"Pending: write spike"), except those recorded under "Organization writes, 2026-10-26".

**Discovery (A1–A3, A5, B1).**
- **Enterprise Managed Users** (reported 2026-10-15 for 0.3.0, gh 2.102.0): `gh auth status`
  lists managed users as `<normalized handle>_<short code>` (two accounts of one teammate, both
  `tokenSource` `keyring`, scopes `admin:public_key, gist, read:org, repo`). GitHub documents the
  handle as letters, digits and single inner hyphens, the short code as 3–8 letters and digits,
  the setup user as `<short code>_admin`, and 39 characters for the whole login. 0.3.0's
  validator rejected the underscore and A3 dropped both accounts; fixture
  `gh/auth-status-emu.json` uses synthetic logins of that shape.
- A Finder-like launch (`PATH=/usr/bin:/bin`, no shell variables) finds gh through the Homebrew
  fallback: `/opt/homebrew/bin/gh` is a symlink into `/opt/homebrew/Cellar/gh/<v>/bin/gh`
  (`drwxr-xr-x <user>:admin`; `/opt/homebrew/bin` is `drwxrwxr-x <user>:admin`), accepted by
  the trust checks. The zsh login-shell probe (A2) returns an all-absolute PATH that resolves to
  the same binary.
- `gh --version` prints `gh version 2.102.0 (2026-09-30)` plus a release URL line.
- `gh auth status --json hosts`: each account has `state`, `active`, `host`, `login`,
  `tokenSource` (`keyring`), `scopes` (`"gist, read:org, repo"`: comma plus space) and
  `gitProtocol`. No token is printed.
- `gh org list` prints one login per line. B1 rows carry exactly the 13 requested fields; `id` is
  a GraphQL node id (`R_kgDO…`), `owner` is `{id, login}`, `defaultBranchRef` `{name}`.

**Reads (B2–B9).**
- An unknown repository (B2): `GraphQL: Could not resolve to a Repository with the name
  '<o>/<r>'. (repository)`, exit 1.
- Empty scopes: `gh secret list` and `gh variable list` print `[]`; B3 prints
  `[{"total_count":0,"environments":[]}]`.
- **B5 on an environment whose policy is not custom** (`deployment_branch_policy: null`) is a
  404 exactly like a missing environment (`gh: Not Found (HTTP 404)`; with `--paginate --slurp`
  stdout still holds the error body wrapped in the slurp array,
  `[{"message":"Not Found",…,"status":"404"}]`). FX Vault reads B5 only for custom policies, and
  the executor treats a B5 404 as "no patterns".
- B7/B9 for a missing environment: `failed to get secrets: HTTP 404: Not Found
  (https://api.github.com/repos/<o>/<r>/environments/<e>/secrets?per_page=100)` (same for
  variables), exit 1.
- B6/B8 on a public repository without rights: `HTTP 403: You must have repository read
  permissions or have the repository secrets fine-grained permission.` (`variables` for B8) →
  `.writeAccessRequired`; an import records both scopes as unreadable and drift reports nothing
  for them.
- `updatedAt` and `createdAt` of secrets and variables have **whole seconds** (`…T08:47:32Z`),
  at repository and environment level. Two writes of one secret within the same second can list
  the same `updatedAt`, which the secret verification (`updatedAt != pre_write_updated_at`) and
  drift (`isSameTimestamp`, 1 ms) cannot tell apart: such a push stays pending until the
  pending-verification pass gives up and re-pushes it. A residual risk only for writes less than
  a second apart.
- Free-plan organization, **private** repository: B3, B4, B7 and B9 read normally (existing
  environments with `deployment_branch_policy: null`, environment secrets and variables listed).
  Reads are not plan-gated.

**`gh api -i` output and errors.**
- Framing: the status line ends in `\n`, every header in `\r\n`, then `\r\n` and the body
  (`APIResponseParser` accepts both).
- **A failed `gh api` call prints only the body's top-level `message` on stderr**
  (`gh: Validation Failed (HTTP 422)`), with or without `-i`. The `errors[]` details GitHub adds
  (for example `[{"resource":"Search","field":"q","code":"missing"}]`) are only in the body on
  stdout. Before this was recorded the classifier saw stderr only, so a plan or permission reason
  given in `errors[]` of a C2/C3/C4/C9 failure was classified as `.validation`; the service now
  passes the details (section E). Fixture: `api/validation-422-errors.txt` (recorded on a read
  call; the shape is GitHub's generic validation error).

**Clone and `.env` (D1–D6).**
- `ssh -G github.com` resolves to github.com and `ssh -T git@github.com` authenticates as the
  account (D2 `.authenticated`), from a Finder-like environment with the agent socket only.
- D3 through the alias gives `origin` = `git@<alias>:<O>/<N>.git` and leaves no
  `.<N>.fxvault-clone-*` directory; a second clone into the same folder fails with
  `.destinationExists` before git runs.
- D4–D6 in a temporary repository under `/var/folders` (a symlink to `/private/var`):
  `rev-parse --show-toplevel` answers with the `/private` path and the relative path is still
  found; `.env` listed in `.gitignore` is `.ignored`, `.env.production` is `.notIgnored` with
  the suggested line `/.env.production`, and after `addGitignoreEntry` it is `.ignored`. The
  exported file is mode 0600.

**Write run, 2026-10-15 (gh 2.102.0).** The opt-in write suite passed against real GitHub:
the public-repository scenario (create repository with README, `.gitignore` and license; two
environments with custom and protected-branch policies; repository and environment secrets and
variables including a multi-line value and Unicode; independent re-checks with raw `gh`; edit,
delete and item rename; guided environment rename; drift from a simulated teammate resolved
once keep-local and once accept-GitHub; clone through the SSH alias; `.env` export) and the
Free-plan scenario on a private organization repository. Observed on that Free-plan private
repository: C2 PUT with or without a branch policy returns 200, environment secret and variable
sets succeed, but C3 (add a deployment branch pattern) returns `gh: Not Found (HTTP 404)` with an
empty body. The executor now classifies a C3 404 on a visible repository as `.planGated`
(test `a404OnAPatternPostOfAVisibleRepositoryIsPlanGated`). The facts below that the suite did
not assert explicitly stay open.

**Organization writes, 2026-10-26 (gh 2.102.0).** Throwaway `FXVAULT_CHECK_*` items on a real
organization, deleted afterwards:
- C10 with `--visibility=selected --repos=<bare name>` reaches `<org>/<name>` (B14 lists it).
- C12 twice upserts (the second value wins), and an upsert also changes the visibility.
- C6/C8/C11/C13 on a name GitHub no longer has: `failed to delete secret <n>: HTTP 404
  (https://api.github.com/…)`, exit 1, with no `: Not Found`. gh prints `HTTP nnn (url)` for
  any response without a message; `GHStderrClassifier` reads it as the status.
- B12–B15 and the Azure listings decode real data: `LiveSourcesTests` (`FXV_LIVE_ORG=<org>`,
  `FXV_LIVE_AZ=1`).

**Still open from the write spike (Q6).** The write run above did not record these facts explicitly. Until a run confirms that a
C2 PUT without `reviewers`/`wait_timer` keeps them, preflight blocks a policy change on any
existing environment that B3 lists with rules other than `branch_policy`
(`SyncBlockReason.protectionRulesPresent`); new environments and guided-rename targets are not
affected. Run the write suite on a throwaway repository before tagging a release and record the
results here. The opt-in suite
`Tests/VaultDataTests/Live` records every open fact when run with
`FXV_LIVE_E2E=1 FXV_LIVE_E2E_WRITE=1 FXV_LIVE_E2E_FREE_ORG=<org>
FXV_LIVE_E2E_REPORT=<file.json> swift test --filter LiveE2E`: identical-value `gh secret set` and
`gh variable set` and `updatedAt`; trailing CRLF, double LF, inner LF and surrounding spaces of
a variable through gh; empty values; C3 POST of an existing pattern; whether a PUT without
`reviewers` keeps them; whether DELETE removes an environment's secrets; a 422 PUT;
and on the Free organization's private repository the stderr of an environment PUT with a
custom policy, a branch-policy POST and environment secret and variable sets, with how
`GHStderrClassifier` reads each. The report replaces the account and organization names.

## G. Runtime destinations (HTTPS, v0.8.0)

DestinationKit's client (`AzureKeyVaultRemote`; 1.0 removed the Supabase and Vercel clients) sends
every request through `ProviderHTTPClient`
and one `HTTPTransporting`: `URLSessionTransport` in the app, `FakeHTTPTransport` in tests,
previews and the offline build. No other code makes HTTP requests. Security rules:
[SECURITY-MODEL.md](SECURITY-MODEL.md) §10.4. Destinations are experimental.

### Conventions

- **Hosts.** `https` only, port 443, no user or password; the host is exactly
  `<vault>.vault.azure.net` (`DestinationHostPolicy`), checked before sending
  and on the response URL. Redirects are refused: a 3xx is `.disallowedHost`.
- **Targets and URLs.** Targets are validated before a client exists (`DestinationRules.validate`):
  a vault name of 3–24 letters, digits and single dashes that starts with a letter and ends with a
  letter or digit; a tenant that is a UUID or a domain. `ProviderURL.make` joins
  segments that pass `PathSegmentValidator`, percent-encoded with the unreserved set (as
  `GitHubPath`); query keys and values are encoded the same way.
- **Headers.** `Accept: application/json`, `Content-Type: application/json` with a body,
  `User-Agent: FXVault`, `Authorization: Bearer <token>`. Callers cannot set `Authorization`,
  `User-Agent`, `Cookie`, `Host` or `Content-Length`; a header value with a line break is refused.
- **Bodies and answers.** Bodies are written by `JSONBodyWriter` straight into `SecretBytes`.
  Answers are read into a `SecretByteBuffer` (at most `Limits.maxDestinationResponseBytes`,
  16 MiB, `.responseTooLarge` beyond) and parsed by `SecretJSONDocument` (RFC 8259, nesting up to
  64, duplicate keys refused), then wiped. Values never become `String`s.
- **Timeouts.** `Timeouts.destinationRequest` (30 s) per request and per transfer.
- **Pagination.** At most 400 pages per listing (`.responseTooLarge` after). A Key Vault `nextLink`
  seen twice is `.decoding`.
- **Logs.** `DestinationLog` (category `destinations`, debug): provider, method, status and
  `DestinationError.logCode`. Never a URL, header, body, name or token.

### Retries (`ProviderHTTPClient.send`)

| Failure | Behaviour |
|---|---|
| 401 on Key Vault | Drop the tenant's cached `az` token and send once more with a new one (any request: one that was refused was not applied). A second 401 is `.unauthorized`. |
| 429 | Idempotent requests: wait `Retry-After` (seconds or an HTTP date) or `Timeouts.destinationRateLimitBackoff` (10 s), at most `Limits.rateLimitRetries` (2) times. A `Retry-After` longer than `Timeouts.destinationMaxRetryAfter` (60 s) is thrown at once. |
| 5xx, `.network`, `.timeout` | Idempotent requests: at most `Limits.idempotentRetries` (2) more times, after `Timeouts.idempotentRetryBackoff` × attempt (2 s, then 4 s). |
| anything else | Thrown to the caller. |

Idempotent: GET, PUT and DELETE. Sent once: Key Vault recover. Bodies are encoded once and wiped after the last attempt; each attempt gets its
own token copy.

### Errors (`ProviderErrorMapper`, `URLSessionTransport.map`)

| Answer | `DestinationError` |
|---|---|
| 401 | `.unauthorized` |
| 402 | `.forbidden` |
| 403 | `.forbidden` |
| 404, 410 | `.notFound` |
| 409 | `.deletedButRecoverable` for Key Vault's `ObjectIsDeletedButRecoverable`, else `.conflict(code:)` |
| 413 | `.valueTooLarge` |
| 429 | `.rateLimited(retryAfter:)` after the retries |
| 3xx | `.disallowedHost` |
| other 4xx | `.invalidRequest(code:)` |
| 5xx | `.server(status:)` after the retries |
| URLSession timeout | `.timeout` |
| cancelled | `.cancelled` |
| redirect, ATS or bad URL errors | `.disallowedHost` |
| unreadable answer | `.decoding` |
| no connection, DNS, lost connection, TLS failure | `.network` |

Only the provider's error code is read from an error body, then sanitized to 1–64 characters of
`[A-Za-z0-9_.-]`: Key Vault `error.innererror.code`, then `error.code`. Messages are never read
(they may quote names). FX Vault's own refusals are `.invalidRequest` with a `LocalCode`
(`writeOnly`, `invalidHeader`; `fakeUnmatched` in tests) and never reach a provider (`reachedProvider` is false).

### G.1 Azure Key Vault (data plane, api-version 7.4)

**Running `az`.** Every `az` command goes through `AzureCLIRunner` and `CommandRunning` (the
`ProcessRunner` rules of section "Child process rules": absolute path, argv array, empty working
directory, no inherited descriptors), always with `--output json`. A truncated stdout is
`.responseTooLarge`.

**Token.** `AzureCLITokenProvider` runs:

```
<az> account get-access-token --resource https://vault.azure.net [--tenant <tenant>] --output json
```

- The binary comes from `AzureCLILocator`: the login shell's PATH directories, then
  `/opt/homebrew/bin` and `/usr/local/bin` (an override path exists in the API, not in the app).
  The first `az` that exists decides and must pass `GHLocator.evaluate` (no consented trust),
  otherwise `.azUntrusted(path:)`; none at all is `.azNotInstalled`. It is located again before
  every run.
- The tenant must be a UUID or a domain (`DestinationRules.isValidTenantID`), so it can never
  become a flag. Environment: the az row of "Child environments". Empty stdin,
  `Timeouts.azAccessToken` (60 s).
- stdout: `accessToken` (read with the secret JSON scanner; printable ASCII, else `.decoding`) and
  `expires_on` (unix seconds, a number or text) or, from older `az`, `expiresOn` (local time).
  stdout is wiped. The token is cached per tenant until `expires_on` −
  `Timeouts.accessTokenRefreshMargin` (5 min); concurrent callers share one run; callers get
  copies.
- Failures: the binary missing at launch (ENOENT) → `.azNotInstalled`; another launch failure →
  `.azFailed(exitCode: -1)`; the timeout → `.timeout`; stderr containing `az login` (checked after
  JWTs and GitHub token patterns are redacted) → `.azNotSignedIn`; stderr containing ARM's
  `AuthorizationFailed` → `.forbidden`; anything else → `.azFailed(exitCode:)`
  (`AzureCLIRunner.classify`, shared by every `az` command). stderr is never logged.

**Discovery (1.0, B8).** `AzureCLIDiscovery` lists the Azure › subscription › vault tree,
read-only, with `Timeouts.azList` (60 s), the same binary, environment and failure mapping:

| Command | argv | Reads | Notes |
|---|---|---|---|
| subscriptions | `<az> account list --output json` | `id`, `name`, `tenantId`, `state`, `isDefault`; optional `tenantDisplayName` (1.0 S1b) | `id` and `tenantId` must be UUIDs (the tenant is lowercased); any entry missing a field is `.decoding` for the whole answer. `name` and `tenantDisplayName` are cleaned (`DisplayNameSanitizer`, up to 255 bytes); an empty `name` shows the id, and `tenantDisplayName` is nil when absent or empty (older `az`). `DestinationRepository` cleans a subscription name again when it saves one. `user` is never read. A subscription listed twice keeps the default entry. `[]` is `.azNotSignedIn`: with nobody signed in `az` exits 0, and `AZURE_CORE_ONLY_SHOW_ERRORS` hides its hint. `state`: Enabled, Warned, PastDue, Disabled, Deleted, else `other`. |
| vaults | `<az> keyvault list --resource-type vault --subscription <id> --output json` | `name`, `resourceGroup`, `location`, `properties.vaultUri` | The id is a `UUID` value, so it can never become a flag. `--resource-type vault` leaves out Managed HSMs. A name that breaks the vault rules (`DestinationRules.isValidKeyVaultName`) or a missing resource group or location is `.decoding`. `vaultUri` is kept only when it is exactly the vault's own `https://<name>.vault.azure.net` (another cloud's or vault's host gives nil); the data plane never uses it. |

`discover()` lists the subscriptions, then each one's vaults, one `az` at a time (concurrent runs
race on `az`'s token cache). A subscription whose listing fails keeps its error
(`.azNotSignedIn` for a tenant that needs its own `az login --tenant`, `.forbidden` without a
role); only a failed subscription listing or `.cancelled` fails the call.

**Endpoints** (`https://<vault>.vault.azure.net`, every request with `api-version=7.4`):

| Call | Request | Body | Reads | Notes |
|---|---|---|---|---|
| list | `GET /secrets?api-version=7.4&maxresults=25`, then each `nextLink` | | `value[]`: `id`, `attributes.enabled`, `attributes.updated`, `managed`; `nextLink` | The name is the path segment after `secrets` in `id`; `attributes.updated` (unix seconds) is the change marker. A disabled secret is unusable and unreadable, a managed one (it backs a certificate) unusable. `nextLink` must stay on the vault's host. |
| read | `GET /secrets/<name>` | | `value` | Enabled secrets only. |
| set | `PUT /secrets/<name>` | `{"value": …}` | `attributes.updated` | Creates a new version; the old version's content type and tags are not copied. Value at most `Limits.maxKeyVaultValueBytes` (25 KiB). |
| recover | `POST /deletedsecrets/<name>/recover` | | | Only after a set answered 409 `ObjectIsDeletedButRecoverable`. Then `GET /secrets/<name>` every `Timeouts.verifyRetryInterval` (2 s) for up to `verifyRetryWindow` (60 s) until it is back (a 404 keeps waiting, a 403 counts as back), and the PUT again. Sent once. |
| delete | `DELETE /secrets/<name>` | | | A soft delete. FX Vault never purges. |

Names: FX Vault's name with `_` → `-` on the way out (1–127 letters, digits and dashes, checked
again before the URL is built); on the way in `-` → `_`, uppercased. A listed name that cannot
become a valid FX Vault name is unusable (`DestinationUnusableReason.invalidName`).

### G.2 Who calls what (VaultData)

| Caller | Calls | Notes |
|---|---|---|
| `DestinationSyncRepository.review` | list | Every destination of the repository with pending changes (others are not contacted); settles `destination_journal` rows left unfinished |
| `DestinationSyncRepository.run` | list, set (Key Vault: recover), delete, list | Lists right before the writes (change-marker checks), journals each write `in_flight`, one confirming re-list; deletions only with `includeDeletions` (the user confirmed them) |
| `DestinationSyncRepository.refresh` | list | Refresh: remote adds, changes and deletions since the last sync |
| `DestinationSyncRepository.resolve` | list, read | Keep Mine / Use Remote; refreshes first and throws `.stale` when a finding no longer holds; values are read only for Use Remote |
| `DestinationSyncRepository.importRemote` | list, read | Right after Add Destination: every usable remote item the vault does not have, with its value where the provider returns one |
| `ShellResolvingAzureTokens` | `az` | Creates `AzureCLITokenProvider` once the login-shell probe (A2) is in; `reset()` on lock |
| `AzureDiscoveryRepository` | `az account list`, `az keyvault list` | `subscriptions()`, `keyVaults(subscriptionID:)`, `discover()` for Connect Azure, the sidebar and Settings › Accounts › Azure; the login-shell PATH (A2) as for tokens; stores nothing |

Clients come from `DestinationRemoteFactory(transport:azureTokens:clock:)` through
`LiveDestinationRemoteProvider`.

### G.3 Tests and observed behavior

- `FakeHTTPTransport` answers scripted requests and records them (unmatched requests get
  `.invalidRequest(fakeUnmatched)`); fixtures are in
  `Tests/DestinationKitTests/Fixtures/keyvault`. VaultData's sync tests use an
  in-memory remote.
- The opt-in live suite `Tests/VaultDataTests/Live/LiveDestinationTests.swift` is never run in CI.
  It runs only when its variables are set: `FXV_LIVE_DEST_KEYVAULT` (optional
  `FXV_LIVE_DEST_TENANT`); `FXV_LIVE_DEST_AZ_TOKEN=1` only fetches an `az` token. It writes and
  deletes names starting with `FXV_E2E_` and needs a throwaway vault.
- **Recorded on 2026-10-16:** the `az` token test passed without contacting a vault. The Key
  Vault data plane has not run live yet: its behavior above comes from the client and its
  fixtures.

## H. Setup commands (Homebrew, 1.0)

```
<brew> install gh | upgrade gh | install azure-cli
```

- Only `SetupCommand`'s fixed argv runs (**Run** on the gh setup screen); anything else, including
  `gh auth login` and `az login`, stays Copy-only.
- `brew` is `/opt/homebrew/bin/brew`, then `/usr/local/bin/brew`; it must pass
  `GHLocator.evaluate` (no consented trust), otherwise there is no **Run**.
- Environment: `ProcessEnvironmentBuilder.homebrew` (identity, `<prefix>/bin:<prefix>/sbin` before
  the system PATH, `NONINTERACTIVE=1`, `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_NO_EMOJI=1`,
  `NO_COLOR=1`, `TERM=dumb`). Timeout 600 s.
- Output: stdout then stderr, redacted (`StderrRedactor`), last 40 lines. A success checks gh
  again; a failure shows its exit code and lines.
- Not run live from the app yet: the commands and their output come from Homebrew's documented
  behavior and the fakes.
