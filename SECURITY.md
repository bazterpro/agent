# Security model

This fork is designed to prevent changes in `hetrixtools/agent` from reaching
installed servers automatically.

## Trust boundaries

- Runtime code and updates are fetched only from `bazterpro/agent`.
- The release ref is pinned to `secure-v2.4.1-1`; branch arguments are rejected.
- The locally trusted installer/updater contains the expected SHA-256 values
  for `hetrixtools_agent.sh` and `hetrixtools.cfg`.
- There is no automatic upstream synchronization workflow.
- The agent only posts metrics to `https://sm.hetrixtools.net/v2/`; it does not
  execute the endpoint response.

SHA-256 protects installed servers from an unexpected file change after the
installer/updater has been reviewed. A repository-account compromise can still
replace a newly downloaded installer, so always verify the installer itself
against a checksum kept outside the repository before executing it.

## Runtime modes

The dashboard-generated second installer argument selects the runtime mode:

- `0`: run as `hetrixtools`, with `PrivateDevices=yes`.
- `1`: run as `root`, without `PrivateDevices`, so SMART, RAID and NVMe metrics
  remain available.

Both modes use mandatory TLS verification and systemd hardening including
`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
`ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`,
`RestrictSUIDSGID`, `LockPersonality`, and `MemoryDenyWriteExecute`.

## Running processes

Process monitoring is available for operational diagnostics. When enabled,
the upstream-compatible payload includes full command lines. Avoid placing
passwords or API tokens in process arguments.

## Updating

Updates are manual. Review changes, update the pinned release ref and embedded
hashes, publish a new immutable tag, then verify and run the updater. Never
merge or sync upstream changes without review.
