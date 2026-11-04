# Changelog

Each release has a section here, named by its version, such as `## 1.0.0`;
that section is the text of its release on GitHub.

## 1.0.0

The first release. It trims the tooling a GitHub-hosted runner preinstalls from
the host underneath a container job, to make room for what the job's container
brings: flavour by flavour, the largest first, until `need-gib` are free, or
all of them. It reports the space before and after and what each flavour freed,
in the log, the job's summary and its outputs, and refuses to run anywhere but
in a container job on a GitHub-hosted runner.

Tested in the host image of xnvme-devenv, on `ubuntu-22.04`, `ubuntu-24.04` and
`ubuntu-26.04`, on runners hosted on both Azure and AWS.
