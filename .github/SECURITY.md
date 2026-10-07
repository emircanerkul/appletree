# Security Policy

## Reporting a vulnerability

Please do **not** open a public issue for a security problem. Report it
privately, either way:

- **GitHub private advisory** (preferred):
  <https://github.com/emircanerkul/appletree/security/advisories/new>
- **Email**: <security@appletree.apps.erklab.com>

A GitHub advisory is visible only to the maintainer until a fix is published.
If you would rather not use GitHub, the email reaches the same person.

Please include what you can of:

- what the problem is and what an attacker could do with it;
- the AppleTree version (AppleTree → About AppleTree) and your macOS version;
- the smallest set of steps that shows it;
- whether it needs a specific configuration, such as a custom model provider.

Please do not attach anything with your own API keys or tokens in it.

## What to expect

This is a small project maintained by one person, so there is no formal SLA.
Reports are read as soon as possible, and you will get an answer either way.
Fixes are published as a new release with the issue credited unless you ask
to stay anonymous.

## Supported versions

Only the latest release is supported. Fixes are not backported.

## Scope

AppleTree is a local disk-space tool. It has no accounts, no analytics and no
servers of its own, so the interesting surface is small and specific:

**In scope**

- A path AppleTree removes that its own guards say it must never touch
  (`CleanupGuard`: protected folders, git repositories, macOS-managed data,
  symlinks that resolve into a protected folder).
- A command AppleTree executes that is not one of the 27 allowlisted
  tool-cleanup forms, or a way to smuggle shell syntax into one.
- The two-step delete acting on anything other than what this cleanup moved
  to the Trash.
- A planner reply escaping into file-system actions rather than staying a
  proposal, or into something executed as a shell string.
- A vulnerability in how a custom provider's API key is stored (it belongs in
  the macOS Keychain, never in a preference file) or sent.

**Out of scope**

- Anything requiring an attacker who already has your user account or your
  Mac, since AppleTree runs entirely as you with your permissions.
- What a model provider you configured yourself does with the scan summary it
  receives. That is your relationship with that provider; see
  [docs/appstore/privacy-policy.md](docs/appstore/privacy-policy.md).
- Cosmetic issues, feature requests and ordinary bugs. Those belong in the
  issue tracker.

## Design notes that may save you time

AppleTree deliberately never trusts the planner:

- The AI writes a **plan**, never an action. AppleTree performs every deletion
  itself, behind its own guards.
- Every path is re-checked at action time, not just when the plan was
  validated, so a folder that changed in between is not acted on.
- Deletion is two-step: move to the Trash (reversible), then delete for good.
  The second step only touches what the first step moved.
- Only the owning tool's own cleanup commands are run, matched exactly, with no
  shell metacharacters permitted.
- A custom model provider is sent the scan summary — paths, sizes, counts and
  dates — and never file contents. It runs no tools at all.
