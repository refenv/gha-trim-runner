# gha-trim-runner

[![test](https://github.com/refenv/gha-trim-runner/actions/workflows/test.yml/badge.svg)](https://github.com/refenv/gha-trim-runner/actions/workflows/test.yml)
[![release](https://img.shields.io/github/v/release/refenv/gha-trim-runner?sort=semver)](https://github.com/refenv/gha-trim-runner/releases)
[![license](https://img.shields.io/github/license/refenv/gha-trim-runner)](LICENSE)
[![REUSE](https://img.shields.io/badge/REUSE-compliant-green)](https://reuse.software/)

Free disk space for your container job by removing the tooling preinstalled on
the GitHub-hosted runner's host.

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/xnvme/xnvme-devenv/host:v0.15.0
      options: --privileged -v /mnt:/mnt
    steps:
    - uses: refenv/gha-trim-runner@v1
    - run: make test   # with room for the guests and disk images it boots
```

A container job brings its own toolchain in its image. The runner underneath
still carries tens of GiB of its own, Android, .NET, GHC, Swift, the JVMs and
more, which the job does not use: the host only has to start the container
and run GitHub's runner. That tooling takes the room the image, and
what the job builds and runs in it, need, and how much is left differs from
runner to runner, so a job that fits on one runs out of space on the next.
This action removes the runner's tooling from the host, flavour by flavour,
and reports what it freed, so every run records the room it had.

A run's log, from the self-test on `ubuntu-26.04`, keeping .NET:

```
gha-trim-runner on Azure
  /: 79.2 GiB free of 144.3 GiB
  Removing from the host underneath this container job:
    android        11.0 GiB  /usr/local/lib/android
    haskell         3.7 GiB  /opt/ghc /usr/local/.ghcup
    swift           3.5 GiB  /usr/share/swift
    java            1.2 GiB  /usr/lib/jvm
    codeql          1.3 GiB  /opt/hostedtoolcache/CodeQL
    powershell      1.3 GiB  /usr/local/share/powershell
    microsoft       0.8 GiB  /opt/microsoft
    chromium        0.7 GiB  /usr/local/share/chromium
  Kept: dotnet
  /: 79.2 GiB -> 102.8 GiB free, 23.6 GiB freed in 73s
```

The same lands in the job's summary as a table, and as a notice on the run.

## Only GitHub-hosted runners, only container jobs

The action means to trim for this one use and nothing else, so nothing
overrides it:

* **Not on a self-hosted runner.** A self-hosted runner is managed by whoever
  runs it, and that is where to make room on one, not in a job.
* **Not in a job on the runner itself.** There, use the tooling the runner
  provides, or set up what the job needs with `actions/setup-python`,
  `rustup` and the like.

The action is for a job whose environment comes in a container, and focuses
on that, without purging someone's self-hosted runner by accident, or
encouraging bad practice in the conventional use of a GitHub-hosted runner.
Before removing anything, each of these must hold:

1. `runner.environment` is `github-hosted`, as GitHub reports it
2. the runner's name has the form GitHub gives its own, `GitHub Actions <n>`
3. the job runs in a container
4. the host is built from GitHub's runner images: its `/etc/environment` sets
   `ImageOS` and `ImageVersion`, and it has the runner user's `/home/runner`

Otherwise it reports the free space, says which did not hold, and outputs
`trimmed: false`.

## Usage

```yaml
- uses: refenv/gha-trim-runner@v1
  with:
    need-gib: 30     # stop once this much is free; empty trims every flavour
    haskell: false   # keep GHC on the host; every other flavour is trimmed
```

### Inputs

| Input      | Default | Description |
| ---------- | ------- | ----------- |
| `need-gib` | empty   | Trim flavour by flavour, the largest first, only until the runner's disk has this many GiB free; empty trims every flavour |
| `extra`    | empty   | More paths on the host to remove, one per line: absolute, below `/`, without whitespace, globs or `..` |
| `dry-run`  | `false` | List what would be removed, and remove nothing |

Every flavour is trimmed, the largest first, unless its input is `false`:

| Flavour      | Removes |
| ------------ | ------- |
| `android`    | `/usr/local/lib/android` |
| `dotnet`     | `/usr/share/dotnet` |
| `haskell`    | `/opt/ghc`, `/usr/local/.ghcup` |
| `swift`      | `/usr/share/swift` |
| `java`       | `/usr/lib/jvm` |
| `codeql`     | `/opt/hostedtoolcache/CodeQL` |
| `powershell` | `/usr/local/share/powershell` |
| `microsoft`  | `/opt/microsoft`, Edge among it |
| `chromium`   | `/usr/local/share/chromium` |

### Outputs

| Output             | Description |
| ------------------ | ----------- |
| `avail-gib-before` | GiB free on the runner's disk before, such as `21.4` |
| `avail-gib-after`  | GiB free on the runner's disk after |
| `trimmed`          | `true` when anything was removed |
| `removed`          | The flavours removed, separated by spaces, such as `android dotnet` |

## How it reaches the host

The tooling lives on the host, out of reach of `rm` in the job's container,
and so does the room it takes: the container's image and workspace are on the
host's disk too. GitHub gives a container job the host's Docker Engine socket;
the action uses it to start a container of the job's own image with the host's
root mounted, and removes the tooling there, so nothing more is pulled. That
socket is root on the host, which a job on a GitHub-hosted runner already has
through `sudo`; the action asks for nothing beyond it.

### What the job's container needs

The action runs in the job's container, and starts its helper from the same
image, so that image needs `bash`, `curl`, `awk`, `grep`, `df`, `cut`, `tr`,
`head`, `mktemp`, `date`, `sh` and `rm`, as most images with a shell have. The
action checks for them before anything else, and fails naming any that are
missing. It talks to the host's Docker Engine API over the socket with `curl`
rather than a docker client, which an image may lack, or have as another
engine's: the `docker` in xnvme-devenv's host image is podman's.

The action is tested in the host image of
[xnvme-devenv](https://github.com/xnvme/xnvme-devenv), the environment it was
made for: a container with its own toolchain, which boots QEMU guests whose
disk images take tens of GiB. It is tested on `ubuntu-22.04`, `ubuntu-24.04`
and `ubuntu-26.04`, as what each runner image preinstalls differs.

## Related work

Two well-established actions free disk on a GitHub-hosted runner, for a job
that runs on the runner itself:

* [jlumbroso/free-disk-space](https://github.com/jlumbroso/free-disk-space)
  removes the runner's tooling with `sudo`, by toggles much like the flavours
  here, and can also remove large apt packages, docker images, the
  preinstalled runtimes and swap
* [easimon/maximize-build-space](https://github.com/easimon/maximize-build-space)
  removes some of that tooling, then joins the free space of the root disk and
  `/mnt` into one LVM volume, mounted at the workspace

In a container job, every step runs in the job's container, these too, so
they reach neither the host's tooling nor its disks. That is the case this
action is for. To use them with a container that brings its own toolchain,
the job runs on the runner, they run first, and later steps start the
container by `docker run`, rather than by `container:`.

## Releasing

A commit on `main` with the subject `ver: bump to vX.Y.Z`, which sets
`VERSION` to `X.Y.Z` and adds a `## X.Y.Z` section to `CHANGELOG.md`, releases
it once the tests pass on it: the release workflow tags `vX.Y.Z`, creates the
release with that section as its notes, and moves `vX`, the tag users pin, to
it.

## License

BSD-3-Clause; the repository is [REUSE](https://reuse.software/) compliant,
which its CI checks.
