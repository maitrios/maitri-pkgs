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
\
