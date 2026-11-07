# Closing issues when a release ships

Issues stay open while a fix is being developed or tested. A published stable release closes only issues explicitly marked ready for that version.

## Prepare a release

1. Create a GitHub milestone whose title exactly matches the planned tag, for example `v0.4.3`.
2. Assign the relevant issues to that milestone.
3. Once each fix has been implemented, reviewed, and checked, add `ready-for-release`. Confirm its code will be included in the release tag before publishing.
4. Reference issues in commits and PRs with `Refs #1`. Avoid `Fixes`, `Closes`, or `Resolves`, which can close them at merge time.
5. Move unfinished issues to a later milestone before publishing, or leave them open in the current milestone until a maintainer chooses their next version. They are never moved or closed automatically.

For an existing milestone and label:

```sh
gh issue edit 1 --repo IGOLz/flusso --milestone v0.4.3 --add-label ready-for-release
```

The ready label and milestone are release bookkeeping, not proof that a fix is in Git. Publish only after committing the intended fixes, checking the tag points to the correct commit, and running the normal release checks.

## Publish

Use the normal `scripts/release.sh` and `scripts/publish.sh` flow. No new token or secret is needed. The **Close released issues** GitHub Action runs on `release.released`, when a stable release is published or an existing prerelease is promoted to stable. It:

- Excludes drafts and prereleases, and requires a stable `vX.Y.Z` tag.
- Verifies that the DMG, ZIP, update feed, and checksums are uploaded and nonempty.
- Finds the milestone with the exact tag title, then selects its open issues labelled `ready-for-release`. Pull requests are excluded.
- Rechecks each issue, posts an English comment linking to the published release, and closes it as completed.
- Closes the milestone only when its current open-item count is zero. Unready issues and open PRs keep it open.

A missing milestone is logged as a no-op. A missing asset blocks all issue writes. If an individual issue fails, the other candidates are still processed and the run fails at the end; the public release remains published. Correct the problem and rerun the Action. When using `GITHUB_TOKEN` to publish from another Action in future, GitHub normally suppresses downstream workflow events; explicitly dispatch this workflow, or arrange the release completion job in that same workflow. The current local publishing script uses your GitHub CLI login and triggers the release event normally.

## Simulation and recovery

In GitHub **Actions → Close released issues → Run workflow**, enter an existing published stable tag. Keep **dry_run** checked to preview candidate issue numbers without making any changes. Uncheck it only to complete or recover a real published release. This also works if the original release was published before the workflow existed, provided the workflow is now on the default branch.

Writes are serialized per release tag. Different tags and read-only simulations have separate concurrency groups, so one cannot displace another release from the pending queue. A marker in the bot's release comment prevents duplicate comments when closing an issue fails and the workflow is rerun. Markers posted by other users are ignored. An issue reopened after this version's release comment stays open on a retry; a fix for a later release can use a later milestone. A closed milestone is left untouched. The simulation also skips reopened issues already announced for that version and reports the open count after the proposed closures. Milestone closure uses a fresh list of open items instead of GitHub’s cached counter.

Commit and **push `main` first**, including both workflows, the script, tests, and the intended fixes, **before creating the next release tag**. The current publishing script creates a missing tag at the remote default-branch HEAD, not at an unpushed local commit. The `release.released` workflow must be present in the released commit. For the first rollout, the files in your working copy alone do not activate GitHub Actions.

## Implementation and checks

- `.github/workflows/release-issues.yml`: release/manual triggers, a simulation mode, serialized execution, pinned actions, and only `contents: read` plus `issues: write` permissions.
- `scripts/release-issues.cjs`: API reads, selection checks, comments, and closure.
- `Tests/ReleaseIssuesChecks.cjs`: offline fixtures covering stable release completion, dry runs, missing assets, prereleases, selection changes, incomplete milestones, retries, and reopened issues.
- `.github/workflows/check-release-issues.yml`: runs the tests on relevant pull requests and main-branch changes. The release Action also runs them before performing any writes.

```sh
node --test Tests/ReleaseIssuesChecks.cjs
```
