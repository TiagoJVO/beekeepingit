# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately through this repository's **Security → Advisories → "Report a vulnerability"**
([open the form](https://github.com/TiagoJVO/beekeepingit/security/advisories/new)). If you can't
use that, contact the maintainer via the address on their GitHub profile.

We'll acknowledge the report, keep you updated, and credit you when a fix ships (unless you'd
prefer to remain anonymous).

## Supported versions

BeekeepingIT is **pre-release** — there are no published releases yet, so there is nothing
deployed to patch. Once releases exist, this section will list which are supported with
security updates.

## Handling & expectations

Security expectations for the codebase live in
[`.claude/rules/coding-standards.md`](.claude/rules/coding-standards.md) (NFR-SEC / NFR-CMP):
no secrets in the repo, input validation against SQLi/XSS/CSRF, and the consent/GDPR path for
cloud AI. Secret scanning and push protection are enabled on this repository.
