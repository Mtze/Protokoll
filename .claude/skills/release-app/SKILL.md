---
name: release-app
description: >
  Cut a GitHub release of Protokoll: pick the next version, write user-friendly
  release notes (plain-language first, technical details after), push the tag,
  let the release workflow build + publish, then attach the curated notes. Use
  whenever the user wants to release / ship / publish a new version, cut a
  release tag, or make a GitHub release.
---

# Release Protokoll on GitHub

Releasing is **tag-driven**. Pushing a `vX.Y.Z` tag runs the root `ci.yml`, which
runs `test` + `build`, and only if both pass runs the reusable
`release.yml`: it builds the Mac app, (optionally signs + notarizes,) zips it,
publishes a GitHub Release with `Protokoll.zip`, and auto-bumps
`Casks/protokoll.rb` on `main`. Your job here is to choose the version, **write
great release notes**, push the tag, and swap the auto-generated notes for the
curated ones once the release exists.

Do the whole thing from the repo root on an up-to-date `main`.

## 0. Preflight

```bash
gh auth status                        # must be logged in; else: gh auth refresh -h github.com
git switch main && git pull --ff-only
git status --porcelain                # must be empty (clean tree)
```
Confirm CI is green on `main` (`gh run list --branch main --limit 1`). Never
release a red `main`.

## 1. Pick the version

```bash
git tag --sort=-v:refname | head -1   # latest release tag, if any
```
- No tags yet → the first release is **`v0.1.0`** (matches `MARKETING_VERSION` in
  `project.yml` and the `Casks/protokoll.rb` placeholder).
- Otherwise ask the user for a **patch / minor / major** bump (or an explicit
  version) and compute `vX.Y.Z` (semver, always `v`-prefixed).

The tag drives the app's `MARKETING_VERSION` (the workflow passes it through) and
the cask `version`, so the tag is the single source of truth for the version.

## 2. Gather what changed

```bash
# since the last tag, or the whole history for the first release
git log <last-tag>..HEAD --no-merges --pretty='- %s'
```
Read the commits; do **not** paste them verbatim. Translate them into what a
user actually notices.

## 3. Write the release notes (the important part)

Write for a **non-technical Mac user first**. Lead with plain language - what they
can now do, in their words, benefit-first. Put technical detail **after**, in its
own clearly separated section, and only if it adds value. No raw commit hashes in
the user-facing part; no jargon like "refactor", "actor", "FTS5" up top.

Save the notes to a scratch file, e.g. `"$TMPDIR/protokoll-notes.md"`, using this
shape:

```markdown
## Protokoll vX.Y.Z

<1-3 sentences a normal person understands: what this release is / what's new and
why they'd care. For the first release, introduce the app itself.>

### What's new
- <User-facing change, framed as a benefit. e.g. "Record the call audio and your
  mic together, so nobody in the meeting gets left out of the notes.">
- <Another one. Keep it concrete and non-technical.>

### Install / update
```
brew tap mtze/protokoll https://github.com/Mtze/Protokoll   # first time only
brew install --cask protokoll                               # or: brew upgrade --cask protokoll
```
<Include this first-launch line while builds are unsigned:>
On first launch macOS may block the app (it isn't notarized yet). Approve it under
**System Settings > Privacy & Security**, or install with
`brew install --cask --no-quarantine protokoll`.

<details>
<summary>Technical details</summary>

- <Dev-facing notes: notable internals, ADRs touched, build/signing status,
  platform requirements (macOS 14+), known limitations.>
- <Only include this section if there's something worth saying.>
</details>
```

Writing rules:
- **User summary before technical**, always. The `<details>` block (or a trailing
  `### Technical details` heading) keeps the technical part out of the way.
- Group changes by what the user sees (Recording, Notes/Summary, Search, Fixes),
  not by module.
- Mention the **unsigned / first-launch caveat** in every release until Developer
  ID notarization is enabled (see `README.md` "Releases, signing & notarization").
- Keep it short and skimmable. Bullets over paragraphs.

**Show the drafted notes and the chosen version to the user and get explicit
approval before tagging** - a release is public and hard to unpublish.

## 4. Tag and push

```bash
git tag -a vX.Y.Z -F "$TMPDIR/protokoll-notes.md"   # annotated tag, notes as message
git push origin vX.Y.Z
```
This triggers the release. (Never tag a commit whose message contains `[skip ci]`
- it suppresses the whole run.)

## 5. Watch the release build

```bash
gh run watch "$(gh run list --workflow ci.yml --event push --limit 1 --json databaseId -q '.[0].databaseId')"
```
Wait for `test`, `build`, and `release` to finish. It takes a while (full build,
plus notarization if signing secrets are set). If it fails, the release won't be
published - fix forward, delete the tag (`git push --delete origin vX.Y.Z`), and
retry.

## 6. Attach the curated notes

The workflow creates the release with auto-generated notes as a placeholder.
Replace them with yours once the release exists:

```bash
gh release edit vX.Y.Z --notes-file "$TMPDIR/protokoll-notes.md" --latest
```

## 7. Verify and report

```bash
gh release view vX.Y.Z --web        # notes + Protokoll.zip asset attached
```
Confirm on `main` that the workflow bumped the cask:
```bash
git pull --ff-only && grep -E 'version|sha256' Casks/protokoll.rb   # real sha256, not 0000…
```
Then give the user the release URL and a one-line recap (version + headline
change). Users can now `brew install --cask protokoll`.

## Notes & gotchas

- **Signing is off by default.** Releases are unsigned until the `MACOS_*` /
  `NOTARY_*` repo secrets exist; the workflow flips to Developer ID sign +
  notarize automatically once they do. Keep the first-launch caveat in the notes
  until then.
- **Branch protection.** The cask-bump step pushes to `main`; if `main` is
  protected, that push is rejected and you must bump `Casks/protokoll.rb` via a
  PR instead (the workflow logs this).
- **`gh` auth.** If `gh` API calls fail, run `gh auth refresh -h github.com`. The
  tag push itself uses git/SSH and is independent of `gh`.
- **Optional durable changelog.** To keep release notes in the repo, write them to
  `docs/releases/vX.Y.Z.md` and commit that to `main` *before* tagging, so the tag
  includes them; then use that file in steps 4 and 6.
