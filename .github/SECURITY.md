# Security policy

Security fixes target the current `main` branch and latest release.

Do not publish vulnerability details, credentials, private keys, hostnames,
world data, or API tokens in a public issue. Use GitHub's private
**Report a vulnerability** flow. If private reporting is not enabled, open a
minimal issue asking MinKevin to establish a private channel without including
technical details or secrets.

A useful report includes the affected version, component, impact, prerequisites,
sanitized reproduction steps, and a suggested mitigation when available.

If a secret was exposed, rotate or revoke it first. Deleting it from the current
tree does not remove it from Git history or existing clones.

A plain host/IP connection uses HTTP. Use a private network or VPN, or configure
a TLS reverse proxy and enter `https://host` in the Windows connection. HTTPS
uses normal Windows system certificate validation; do not bypass it or expose a
plaintext API directly to the public internet. Protect the Windows account,
encrypted connection store, master password, Linux account, SSH keys, and API
credentials.
