# Patched, multi-arch Mattermost Team Edition

Mattermost's Team Edition image is written for amd64. Mattermost releases binaries
for both amd64 and arm64, but not docker images.

This repo patches the Team Edition Dockerfile to make it work with both.

## Images

### `ghcr.io/<owner>/mattermost-team:<version>`

Mattermost Team Edition, identical to upstream apart from the build fixes needed
for arm64. This is the server you run. Tagged with the Mattermost version it
contains.

### `ghcr.io/<owner>/mattermost-mmctl:<version>`

`mmctl`, Mattermost's admin CLI, on a busybox base. The server image is
distroless and has no shell, so you can't run admin or bootstrap scripts that
drive `mmctl` from inside it. This image puts `mmctl` on top of a shell so you
can. Tracks the same version as the server.

## Why it's patched

- **Library paths.** Upstream copies document-processing libraries from a
  hardcoded amd64 directory; the patch globs the architecture directory so the
  same build works on arm64.
- **`passwd`.** Upstream copies a `passwd` file that ships in its build context;
  the patch sources it from the build stage instead, making the rebuild
  self-contained.

## Versions

Stable Mattermost releases are mirrored automatically and each published version is immutable.

## License

The Dockerfile patch and the workflow in this repo are licensed under
[AGPL-3.0](LICENSE), the same license as the upstream Mattermost Dockerfile they
build on.

The images themselves bundle Mattermost's official compiled binaries, which
Mattermost, Inc. licenses under the MIT license, on top of their base image and
document-processing tools under their own licenses. Those are included
unmodified and are not relicensed here.
