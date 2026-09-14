# Releasing maitri packages

## A maitri release

1. In kindness-ai/maitri: land on `main`, set `version`, tag and push the tag (`git tag vX.Y.Z && git
   push origin vX.Y.Z`). Do not publish the GitHub release yet.
2. Here:

   ```bash
   scripts/bump-maitri vX.Y.Z        # pins maitri + maitri-settings to the tag's commit, commits
   git push origin main              # build-pkgs.yml builds and publishes stable + edge
   ```

   Wait for the workflow, then check `gh release view stable --json assets -q '.assets[].name' | grep
   '^maitri-'`.
3. In kindness-ai/maitri: `gh release create vX.Y.Z --generate-notes`. Its ISO build waits for the
   stable channel to carry `maitri X.Y.Z` before baking.

## Repackaging the same tag

`scripts/bump-maitri vX.Y.Z --rebuild` bumps `pkgrel`.

## Pre-releases

Tag `vX.Y.Z-rcN` in maitri; `bump-maitri` writes the attached `X.Y.ZrcN` form so pacman sorts it
before the final release.

## Edge

Automatic: every push to maitri `main` rebuilds `maitri-dev` and `maitri-settings-dev` onto `edge`
(`build-edge-dev.yml`). Trigger it by hand from the Actions tab if a dispatch was missed.

## Secrets and settings

- `MAITRI_GPG_PRIVATE_KEY` (secret): the maitri signing key, imported only in publish jobs.
- In kindness-ai/maitri: `MAITRI_PKGS_DISPATCH_TOKEN` (secret), a fine-grained PAT with
  `contents: write` on this repo, used by `notify-pkgs.yml`.
