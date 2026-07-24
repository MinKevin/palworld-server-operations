# Contributing

Focused issues and pull requests are welcome.

## Before submitting

- Search existing issues first.
- Use [.github/SECURITY.md](SECURITY.md) for vulnerabilities.
- Remove credentials, private deployment details, world data, and connection
  stores from code, logs, screenshots, and test fixtures.
- Confirm that new code, assets, and dependencies can be redistributed under
  GPL-3.0-only and any compatible third-party terms.
- AI-assisted contributions are welcome, but the submitter must understand,
  review, test, and disclose the assistance.

Do not commit real `config/serverN.env` files, `data/`, `runtime/`, `backups/`,
`.connections`, private keys, passwords, or API tokens.

## Development checks

Keep changes small and update the relevant tests. Rebuild generated artifacts
when their sources change:

```powershell
$env:PYTHONDONTWRITEBYTECODE = "1"
python -B tools/build_ssh_payloads.py
python -B tools/build_linux_installer.py
& 'C:\Program Files\Git\bin\bash.exe' -n `
  install/lib.sh install/manager install/scaffold.sh install/setup.sh `
  install/test operate/pal
python -B -m unittest discover -s tests -v
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools/windows-client/build-exe.ps1
Remove-Item Env:PYTHONDONTWRITEBYTECODE
```

The Windows build embeds a manifest of its normalized source and bundled
resource hashes. CI checks both committed executables against that manifest,
so source or generated-payload changes must be followed by an EXE rebuild.

Run `python -B tools/windows-ssh-manager/fetch_sshnet.py` only when changing the
locked SSH.NET dependency set, then review the regenerated package hashes and
third-party legal notices before committing them.

Keep source comments and identifiers in English. Preserve Windows PowerShell
5.1 and Ubuntu/Debian compatibility unless a proposal explicitly changes it.
Do not weaken credential redaction, host-key verification, destructive-action
confirmation, backup validation, or API authentication.

When changing Palworld settings, compare Pocketpair's
[official versioned configuration reference](https://docs.palworldgame.com/settings-and-operation/configuration/)
with the current `PalWorldSettings.ini` shape. Keep the
English and Korean ENV templates identical in key order, enabled/commented
state, and values. Mark INI compatibility keys that are absent from the official
v1.0 reference instead of calling them unsupported, and update the template
tests when the upstream reference changes.

By contributing, you agree that your contribution is distributed under
GPL-3.0-only.
