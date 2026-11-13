# Release Process

This repo releases as a Linux-first Ruby + QuickShell + Waybar source/user-prefix package.

It does not define a native desktop bundle, updater feed, tap/cask package, or notarization flow.

## Release Tracks

- Preview release: `make check` passes.
- Stable release: `make check-live` passes on the intended release machine with live Codex, Claude, Gemini, OpenCode, Z.ai, and Ollama Cloud credentials.

## Required Gates

Before tagging:

```bash
make syntax
make test
make smoke
make check
```

For stable:

```bash
make check-live
```

Install and rename-safety validation:

```bash
make install
make configure-user
make install-solverforge-linux-integration
readlink -f ~/.local/bin/tokenmaxx
tokenmaxx config validate
tokenmaxx waybar render
tokenmaxx ui status --format json --pretty
rg "<old checkout directory name>" ~/.config/tokenmaxx ~/.local/bin ~/.local/share/solverforge
```

The final `rg` command must have no live integration hits. Use the actual old checkout directory name when running it.

## Documentation Gate

Release-facing docs must describe the current Linux product only:

```bash
rg "<retired product term pattern>" README.md AGENTS.md WIREFRAME.md docs
```

Any hit for retired upstream product, packaging, or provider claims must be removed from current docs.

## Peak/Off-Peak Window Update (Required)

Before tagging, re-verify every peak/off-peak window against the vendor's current documentation. No supported provider API exposes the schedule and no runtime source can correct it, so this cannot be automated.

1. Open each vendor's current pricing/plan documentation for the entries in `Core::Peak::SCHEDULES` (`lib/tokenmaxx/core/peak.rb`).
2. Confirm the peak weekday range, UTC start, and UTC end for every entry, and the model scope.
3. If any window changed, update `Core::Peak::SCHEDULES` and the matching table in `docs/providers.md` in the same release.
4. Re-check the boundaries in the machine's local zone (including DST and non-hour offsets) before finishing.

Do not encode limited-time promotions; encode only standing recurring schedules.

## Provider Claims

The release may claim support for exactly:

- `codex`
- `claude`
- `gemini`
- `opencode`
- `zai`
- `ollama`

Provider behavior must match `lib/tokenmaxx/providers/*`.

## Release Workflow

1. Commit the release work as atomic conventional commits (`feat`, `fix`, `docs`, ...). The changelog and version bump are derived from these commits.
2. Re-verify and update every peak/off-peak window (see "Peak/Off-Peak Window Update" above).
3. Run the required gates on the exact tree being released.
4. Cut the release with native `csemver` and the checked-in `csemver.toml`. Do not hand-edit `CHANGELOG.md`, bypass commit hooks, or create the release commit or tag by hand:

   ```bash
   csemver --dry-run
   csemver
   ```

   The default bump follows Conventional Commits. For an explicit level or version, pass the same `--release-as minor` or `--release-as X.Y.Z` to the preview and cut.

   The tool bumps `version.env` and the Codex app-server client identity in `lib/tokenmaxx/providers/codex.rb`, regenerates `CHANGELOG.md`, creates the release commit, and tags it.

5. Verify the release before publishing:

   ```bash
   git show --stat --oneline HEAD   # exactly version.env + codex.rb + CHANGELOG.md
   git tag --points-at HEAD         # the intended tag
   git status --short               # must be clean
   sed -n '1,16p' CHANGELOG.md      # correct heading and compare URL
   ```

6. Deploy the released version and restart the runtime — running processes keep executing the previous code until restarted (see "Restart After Install" in `docs/installation.md`):

   ```bash
   make install
   # restart tokenmaxx daemon, then restart the panel and run: tokenmaxx ui open
   ```

7. Publish to both remotes and prove the remote state:

   ```bash
   git push git.local main vX.Y.Z
   git push blackopsrepl main vX.Y.Z
   git fetch git.local main
   git fetch blackopsrepl main
   git rev-list --left-right --count git.local/main...main     # expect: 0 0
   git rev-list --left-right --count blackopsrepl/main...main  # expect: 0 0
   git ls-remote git.local refs/tags/vX.Y.Z
   git ls-remote blackopsrepl refs/tags/vX.Y.Z
   ```

Both remote tag SHAs must match the local tag object, and divergence must be `0 0` on `main` for every remote. Verify each annotated tag's peeled commit (`refs/tags/vX.Y.Z^{}`) equals the released branch head.

8. Create the GitHub and Forgejo release objects from the tagged changelog, not automatic PR notes. `bin/release-notes vX.Y.Z` reads `CHANGELOG.md` from that tag and fails if the requested section is missing or has no release entries. Use its output unchanged as each release body, and read both objects back to verify their tag, title, body, and publication flags.
