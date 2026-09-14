# maitri-pkgs

The pacman package repository behind [maitri](https://github.com/maitrios/maitri): the `[maitri]`
repo its `pacman.conf` points at, built and signed in GitHub Actions and published as one GitHub
Release per channel.

```
[maitri]
Server = https://github.com/maitrios/maitri-pkgs/releases/download/stable
```

## Channels

| Channel | Release tag | Contents |
|---|---|---|
| `stable` | `stable` | every package, with `maitri` + `maitri-settings` pinned to a maitri release tag |
| `edge` | `edge` | the same, plus `maitri-dev` + `maitri-settings-dev` built from maitri's `main` |

Arch packages come from the official mirrors; only what is not in Arch lives here. `maitri channel set
stable|edge` switches a machine between the two.

## Packages

- **maitri** / **maitri-settings** — the desktop itself, built from a pinned commit of
  maitrios/maitri (`pkgbuilds/maitri`, `pkgbuilds/maitri-settings`). They move in lockstep;
  `scripts/bump-maitri` is the only thing that should edit their pins.
- **maitri-dev** / **maitri-settings-dev** — the same recipes following `main`, edge only.
- **maitri-keyring** — the signing key, trust anchor for the repo. **maitri-nvim** — LazyVim setup.
  **maitri-fish** — fish functions and completions (maitrios/maitri-fish).
- Everything else mirrors an AUR or vendor recipe that maitri's default install or an opt-in menu
  entry needs: launcher (vicinae-bin, maitri-vicinae-extension), Helium, editors, the oma* apps,
  hardware drivers, gaming and AI extras. Most are copied from
  [omarchy-pkgs](https://github.com/omacom/omarchy-pkgs) and refreshed from there.

## How it builds

`.github/workflows/build-pkgs.yml` runs on every push touching `pkgbuilds/`:

1. **build** (matrix: `core`, `heavy`) seeds the published `stable` packages as a cache, then runs
   `.github/build-packages.sh` inside an Arch container. Only PKGBUILDs whose exact
   `name-pkgver-pkgrel` is not cached compile. `heavy` is `linux-ptl` and `sunshine` on a runner with
   extra disk; VCS `-git` packages build only on demand. No signing key is present in this job.
2. **publish** (`stable`, then `edge`) downloads the channel's current assets plus what was built,
   checks the release pair is in lockstep, signs every package with `MAITRI_GPG_PRIVATE_KEY`,
   `repo-add`s `maitri.db`, uploads packages before the database, and deletes superseded assets.

`.github/workflows/build-edge-dev.yml` builds the dev pair whenever maitrios/maitri pushes to `main`
(its `notify-pkgs.yml` sends a `repository_dispatch`), or six-hourly, and publishes to `edge` under
the same concurrency group.

Manual runs: **Actions → Build maitri packages → Run workflow**, with `force_rebuild` or a
space-separated `packages` list.

## Releasing maitri

See [RELEASING.md](RELEASING.md). In short: tag maitri, run `scripts/bump-maitri vX.Y.Z`, push.

## Adding or updating a package

1. Create `pkgbuilds/<name>/` with the PKGBUILD (and `.install`, patches, launchers). Recipes from
   omarchy-pkgs are copied without their `.omarchy/` metadata; rename any `omarchy-*` runtime
   references (commands, `~/.config/omarchy`) to maitri.
2. Add an entry to `.nvchecker.toml` so `scripts/check-updates` reports when it falls behind.
3. If maitri's default install needs it, add it to `install/maitri-base.packages` in the maitri repo
   (its header lists what comes from this channel).
4. Push; CI builds only the new or changed package.

`scripts/check-updates` (needs `nvchecker`) lists packages behind their upstream.
