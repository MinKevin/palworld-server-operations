# Code signing policy

## Provider and scope

Official Windows releases of Palworld Server Operations are intended to be
signed through the open-source code-signing program described below:

> Free code signing provided by SignPath.io, certificate by SignPath Foundation.

Until that integration is approved and enabled, release notes explicitly state
that the Windows executables are unsigned. Authenticode applies to the Admin and
Client Windows executables; the Linux `.run` installer is covered by the
published SHA-256 checksum instead.

## Project roles

- Committer and reviewer: [MinKevin](https://github.com/MinKevin)
- Signing approver: [MinKevin](https://github.com/MinKevin)

The maintainer uses multi-factor authentication for repository and signing
access. Every signing request must originate from the public repository and be
manually approved by the signing approver.

## Build and release integrity

- Official sources are hosted at
  <https://github.com/MinKevin/palworld-server-operations>.
- Windows release executables are built on GitHub-hosted Windows runners from
  the tagged source revision.
- The workflow runs regression tests, rebuilds generated payloads, verifies
  build-input fingerprints, and publishes SHA-256 checksums.
- Only the two project-owned Windows executables are submitted for
  Authenticode signing. Palworld game binaries and bundled third-party
  dependencies are not signed as if they were authored by this project.
- Release artifacts are not modified after signing. Checksums are generated
  from the final files that are published.

## Privacy and network access

This program will not transfer any information to other networked systems
unless specifically requested by the user or the person installing or
operating it.

The applications have no telemetry or advertising. They connect only to SSH
hosts, Server API endpoints, and project links explicitly selected or
configured by the operator. Linux-side setup and update operations download
required open-source packages, container components, SteamCMD, and Palworld
dedicated-server files from their respective upstream services.

## Security reports

Please follow the private reporting instructions in
[SECURITY.md](SECURITY.md). Do not attach credentials, tokens, private keys,
connection stores, server configuration, or world data to a public issue.
