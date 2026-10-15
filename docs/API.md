# FX Vault - gh, git and ssh command catalog

FX Vault has no server API. Every GitHub operation is a child process: the GitHub CLI (`gh`),
`/usr/bin/git` or `/usr/bin/ssh`. This catalog is the implemented form of plan §8 and lives in
`Packages/FXVaultKit/Sources/GitHubKit`. Operation ids (`A1`, `B3`, `C5`, ...) are the raw
values of `GHOperation`; each builder's `logTemplate` (shown below) is the only form of a command
that is ever logged.

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
- **`gh api`** (written `API` below) is used only for environments and deployment branch
  policies. It always sends `-H "Accept: application/vnd.github+json"`,
  `-H "X-GitHub-Api-Version: 2026-03-10"` and an explicit `-X <METHOD>`. `GitHubPath`
  percent-encodes each segment (ASCII unreserved set; `a/b c` becomes `a%2Fb%20c`) and throws on
  dot segments and their encoded forms. List reads use `--paginate --slurp`; single-object reads
  and writes add `-i` and are parsed by `APIResponseParser` (status line, kept headers, body).
  Bodies are sent with `--input -`.
- **Timeouts** (`Timeouts`): A4 `ghAuthToken` 60 s, B1 `ghRepoList` 120 s, everything else
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

Never passed, even when set in the app's environment: `GH_DEBUG DEBUG GITHUB_TOKEN
GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_REPO GH_FORCE_TTY CLICOLOR_FORCE GH_EDITOR
GH_BROWSER`.

## A. Discovery and auth

| Op | argv (`logTemplate`) | Builder | Notes |
|---|---|---|---|
| A1 version | `gh --version` | `GHLocator.versionCommand()` | `^gh version (\d+)\.(\d+)\.(\d+)`. Below `GHVersion.minimum` (2.97.0) is `.versionTooOld`. No token. |
| A2 shell probe | `<login shell> -l -c '<script>'`, then `-i -l -c`; csh/tcsh get `-c`, then `-i -c` | `ShellEnvironmentResolver` | One shell-agnostic script made only of absolute `/usr/bin/printf` and `/usr/bin/printenv` calls separated by `;`, between the markers `__FXV_B__` and `__FXV_E__`. Captures only `PATH GH_CONFIG_DIR XDG_CONFIG_HOME XDG_CACHE_HOME XDG_STATE_HOME SSH_AUTH_SOCK`; PATH keeps absolute directories only, the others must be absolute paths. Environment `FXVAULT_RESOLVING_ENV=1`, 5 s. Falls back to `ShellEnvironmentModel.empty`. |
| A3 accounts | `gh auth status --hostname github.com --json hosts` | `GHAuthService.statusCommand()` | No token. `state` `success` is ok, `timeout` is offline; `error` is offline for network fragments, re-login for `HTTP 401`/`Bad credentials`, otherwise unexpected. `scopes` is split on `,` and trimmed; an absent or empty value is `.unknown`. |
| A4 token | `gh auth token --hostname github.com --user={login}` | `GHAuthService.tokenCommand(login:)` | No token. Trimmed and cached in `GHTokenCache` (memory only, `purge()` on lock). |
| A5 orgs | `gh org list --limit 300` | `GHOrgsCommands.list()` | One login per line; each validated. Needs `read:org`, otherwise the list can be silently incomplete. |

`GHLocator.locate(overridePath:shell:)` picks the binary: the override, then Homebrew
(`/opt/homebrew/bin`, `/usr/local/bin`), the shell PATH, MacPorts, Nix and `~/.local/bin`. A
candidate must be a regular executable file, owned by root or the user, not world-writable,
in a directory that is not world-writable. Group write is accepted only for the `wheel` and
`admin` groups (Homebrew's `/opt/homebrew/bin` is `drwxrwxr-x root:admin`). Symlinks are
resolved; `GHInstallationModel.hasChanged(fromResolvedPath:)` detects a changed binary.

## B. Read

| Op | argv (`logTemplate`) | Builder / decoder | Notes |
|---|---|---|---|
| B1 repos | `gh repo list {o} --limit 1000 --json <B1 fields>` | `GHReposCommands.list(owner:)` / `decodeList` | Fields: `id,name,nameWithOwner,owner,isPrivate,visibility,isArchived,isFork,viewerPermission,viewerCanAdminister,defaultBranchRef,sshUrl,createdAt`. Invalid names are skipped. `GHRepoDTO.makeRepoModel` maps to `RepoModel`. |
| B2 repo | `gh repo view {o}/{r} --json <B1 fields>` | `.view(_:)` / `decodeView` | Add by name, availability check, C1 follow-up. |
| B3 environments | `gh api -X GET repos/{o}/{r}/environments --paginate --slurp` | `GHEnvironmentsAPI.list(repo:)` / `decodeList` | `GHEnvironmentDTO`: policy kind, `foreignRulesJSON` (canonical JSON of protection rules other than branch policy). |
| B4 environment | `gh api -X GET -i repos/{o}/{r}/environments/{e}` | `.get(repo:environment:)` / `decodeEnvironment` | 404 means absent: `GHCommandScheduler.environment(_:named:)` returns nil. |
| B5 patterns | `gh api -X GET repos/{o}/{r}/environments/{e}/deployment-branch-policies --paginate --slurp` | `.listBranchPolicies` / `decodeBranchPolicies` | `GHBranchPolicyDTO`; a missing `type` means branch. |
| B6/B7 secrets | `gh secret list --repo={o}/{r} [--env={e}] --json name,updatedAt` | `GHSecretsCommands.list` / `decodeList` | gh follows every page. |
| B8/B9 variables | `gh variable list --repo={o}/{r} [--env={e}] --json name,value,updatedAt,createdAt` | `GHVariablesCommands.list` / `decodeList` | Values become `SecretBytes` (`GHVariableListingModel`); stdout is wiped. The JSON decoder's transient `String` copies cannot be wiped. |
| B10g / B10l | `gh repo gitignore list`, `gh repo license list` | `GHTemplatesCommands` | Plain text by line; license key column first. |

## C. Write

All writes are `isWrite`, journaled by the caller before they start, and never run twice in
parallel. Values and JSON bodies are on stdin.

| Op | argv (`logTemplate`) | Builder | Success and special cases |
|---|---|---|---|
| C1 create repo | `gh repo create {o}/{n} --private\|--public\|--internal [--description={d}] [--add-readme] [--gitignore={t}] [--license={l}]` | `GHReposCommands.create(_:)` / `decodeCreated` | Never `--clone`, **never retried**. stdout is one line, the new repo URL, which gives the normalized name. A `users/<owner>` 404 is `.validation`; "already exists" is `.validation`; org policy text is `.orgPolicyForbidsCreate`. |
| C2 env upsert | `gh api -X PUT -i repos/{o}/{r}/environments/{e} --input -` | `GHEnvironmentsAPI.upsert` | Body `{"deployment_branch_policy": null \| {"protected_branches":true,"custom_branch_policies":false} \| {false,true}}`. Never sends reviewers, wait timer or prevent-self-review. |
| C3 pattern add | `gh api -X POST -i repos/{o}/{r}/environments/{e}/deployment-branch-policies --input -` | `.addBranchPolicy` | Body `{"name","type"}`. 200 returns the policy; a bare 303 (gh exits 1 with `gh: HTTP 303`) also counts as success and returns nil (the caller re-lists with B5). |
| C4 pattern delete | `gh api -X DELETE -i repos/{o}/{r}/environments/{e}/deployment-branch-policies/{id}` | `.deleteBranchPolicy` | 204; a 404 counts as done. |
| C5 secret set | `gh secret set {n} --repo={o}/{r} [--env={e}]` | `GHSecretsCommands.set` | Value on stdin (the builder copies it). Verified by the caller through B6/B7 `updatedAt`. |
| C6 secret delete | `gh secret delete {n} --repo={o}/{r} [--env={e}]` | `.delete` | A 404 is thrown as `.notFound`; the caller treats it as done only after a successful re-list of the same scope. |
| C7 variable set | `gh variable set {n} --repo={o}/{r} [--env={e}]` | `GHVariablesCommands.set(…isUpdate:)` | Upsert; write cost 2 when `isUpdate`. Empty values are rejected before argv. |
| C8 variable delete | `gh variable delete {n} --repo={o}/{r} [--env={e}]` | `.delete` | As C6. |
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
display), and the `-i` status when present. Status sources: native `HTTP (\d{3}): ` anywhere in
stderr; `gh api`'s `^gh: (.*) \(HTTP (\d{3})\)$` or `^gh: HTTP (\d{3})$`; `GraphQL:` messages
by fragment; the `-i` status line. Rules, in order:

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

Also from the service layer: a missing executable (ENOENT for the binary) → `.notInstalled`; a
missing working directory or other spawn failure → `.launchFailed`; truncated stdout →
`.outputTooLarge`; undecodable output → `.malformedOutput`; task cancellation → `.cancelled`.

The classifier table is `Tests/GitHubKitTests/Fixtures/gh/stderr-cases.json` (41 cases). Cases
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
