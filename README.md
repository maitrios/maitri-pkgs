# maitri-pkgs

The custom pacman package repository for [maitri](https://github.com/kindness-ai/maitri) — i.e. the
`[maitri]` repo configured in maitri's `pacman.conf`:

```
[maitri]
Server = https://github.com/kindness-ai/maitri-pkgs/releases/download/stable
```

Packages are built + signed in CI (`.github/workflows/build-pkgs.yml`) inside an Arch container and
published to a GitHub Release per channel (`stable`, `edge`).

## Packages

- **maitri-keyring** — installs the maitri package-signing public key into pacman's keyring; the trust
  anchor for the `[maitri]` repo.

## Setup (one-time)

1. Generate the maitri signing key (see the main repo's notes), then add its **private** key as the repo
   secret `MAITRI_GPG_PRIVATE_KEY` (Settings → Secrets → Actions).
2. Add the **public** key as `pkgbuilds/maitri-keyring/maitri.gpg` and put its fingerprint in
   `pkgbuilds/maitri-keyring/maitri-trusted` (`<FINGERPRINT>:4:`).
3. Run the **Build maitri packages** workflow. Flip this repo **public** at launch so pacman can fetch anonymously.
