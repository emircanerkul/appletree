# Contributing to AppleTree

Thank you for considering a contribution to AppleTree! Before you open a
pull request, please read this document carefully — especially the
**Contribution License** section below. By submitting a contribution, you
agree to those terms.

## How to contribute

1. Open an issue describing the bug or feature before investing significant
   work, so we can align on the approach.
2. Fork the repository, create a feature branch, and make your changes.
3. Ensure existing tests pass and add tests for new behavior where
   reasonable.
4. Open a pull request with a clear description of what changed and why.

## Releasing

`make test` is the gate: it runs the Rust engine tests, every Swift suite, the
JSON CLI contract and the l10n check. There is no CI, so nothing else runs them —
run it before tagging.

```sh
make test                 # must be green; also runs `cargo test --release`
```

**Version lives in one place.** `Cargo.toml`'s `version` is read by the Makefile
for `CFBundleVersion` and `CFBundleShortVersionString`, so the app bundle and the
CLI both report it. `Cargo.lock` records it too, and `--locked` builds fail until
it is regenerated — that failure is the reminder, not a problem to route around:

```sh
# 1. Edit Cargo.toml's version; move CHANGELOG's "Unreleased" section under the
#    new "## X.Y.Z — YYYY-MM-DD" heading.
# 2. Regenerate the lock (no --locked here; that is what needs updating):
cargo build --offline --release
# 3. Verify both artifacts agree, then confirm --locked works again:
make build && /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    build/AppleTree.app/Contents/Info.plist
cargo build --locked --release
# 4. Commit, then tag with notes (annotated tags are the convention here):
git commit -am "release: vX.Y.Z"
git tag -a vX.Y.Z -m "AppleTree X.Y.Z" -m "<what changed, in the changelog's voice>"
git push origin main --follow-tags
```

### Packaging a DMG (Developer ID route)

```sh
make package              # build -> notarize (if possible) -> staple -> AppleTree.dmg
```

It signs with **Developer ID Application** when one is installed, then **Apple
Development**, then ad-hoc. Only the first can be notarized, and `make package`
**skips notarization silently** when it is absent: the DMG is still produced, but
Gatekeeper rejects it (`spctl --assess --type execute` says "rejected"). Check
which identity was used before shipping:

```sh
codesign -dvv build/AppleTree.app 2>&1 | grep '^Authority='
```

- `Authority=Developer ID Application: ...` -> notarization ran; the DMG is
  distributable and `SHA256SUMS.txt` is written for the download page.
- `Authority=Apple Development: ...` or `Signature=adhoc` -> **local use only.**

Notarization needs stored credentials once:

```sh
xcrun notarytool store-credentials appletree-notary \
    --apple-id <apple-id> --team-id <TEAM_ID> --password <app-specific-password>
```

### App Store route (Transporter)

```sh
make pkg                  # -> AppleTree.pkg, ready for Transporter
```

Transporter takes a **signed `.pkg`** for a macOS app. (`.ipa` is iOS-only and
`.aar` is Android; neither applies.) `make package` produces a `.dmg` for direct
download and is **not** submittable — it signs with Developer ID, which is the
wrong certificate for the store.

`make pkg` checks all four prerequisites **before building anything**, because an
unsigned or wrongly-entitled pkg uploads fine and is then rejected during review
with no useful message:

| Prerequisite | Signs | Status here |
| --- | --- | --- |
| **Apple Distribution** certificate | the `.app` | check with `security find-identity -v` |
| **Mac Installer Distribution** certificate | the `.pkg` | **install in Xcode first** |
| Sandbox entitlements (`app/AppleTree.entitlements`) | — | in the repo |
| Provisioning profile for `com.erklab.apps.appletree` | — | pass via `PROVISIONING_PROFILE=` if you have one |

The two certificates are **different** and both are required: one signs the app,
the other signs the container. Developer ID Application is a third, for direct
download only.

To get the installer certificate: **Xcode → Settings → Accounts → Manage
Certificates → + → Mac Installer Distribution**. Without it the target stops
rather than emitting an unsigned pkg.

Then verify and upload:

```sh
pkgutil --check-signature AppleTree.pkg     # must not say "no signature"
xcrun altool --validate-app -f AppleTree.pkg -t macos \
    -u <apple-id> -p <app-specific-password>
```

or drag `AppleTree.pkg` into Transporter, which validates on delivery.

Before spending a review cycle, `make deploy-sandbox` installs a rehearsal build
locally to check behaviour under the sandbox; see
`docs/appstore/app-store-metadata.md` section 3.

## Contribution License — please read carefully

AppleTree is distributed under a dual license:

* the historical snapshot described in [`LICENSE`](./LICENSE) remains
  **MIT**-licensed, and
* all later work is licensed under **CC BY-NC-SA 4.0**, with a separate
  commercial license available from the project owner. The published form of
  that commercial edition is AppleTree on the Mac App Store, where buying a
  copy grants that buyer commercial use of the app; the **source** stays
  CC BY-NC-SA 4.0 either way.

This means the project owner publishes a community edition under
CC BY-NC-SA 4.0 **and** may sell or otherwise commercialize the project
under separate terms. For that dual-licensing model to remain legally
possible, every contribution must come with rights that are **not**
limited to non-commercial use.

Therefore, by opening a pull request, submitting a patch, or otherwise
providing a contribution to this repository (in code, documentation, or any
other form), **you grant the project owner, Emircan ERKUL, a perpetual,
worldwide, irrevocable, royalty-free, fully transferable and sublicensable
license** to your contribution, including the rights to:

* use, reproduce, modify, adapt, translate, and distribute your
  contribution, in source or object form, as part of AppleTree or
  standalone;
* **use and commercialize your contribution, including selling it or
  licensing it commercially, without any restriction and without any
  obligation to pay you or to notify you;**
* relicense your contribution under any license — including proprietary
  and commercial licenses — as part of any edition of AppleTree (community,
  commercial, or otherwise);
* combine your contribution with other work under any license; and
* sublicense any of the above to third parties.

You retain copyright ownership of your contribution. Nothing in this
section transfers your copyright to the project owner; instead, it grants
the owner rights broad enough that **your contribution will never restrict
how the owner uses, licenses, sells, or distributes AppleTree**, now or in
the future. You warrant that you have the right to grant this license and
that your contribution is either your own original work or you otherwise
have the authority to submit it under these terms.

If you do not agree to these terms, do not submit a contribution to this
repository. If you submit one on behalf of an employer, you confirm that
you are authorized to do so.

### Why this section exists

If your contribution were licensed only under CC BY-NC-SA 4.0 (the license
of the community edition), it could not legally be included in any
commercial edition of AppleTree, because the NonCommercial term would bind
the project owner with respect to *your* code. The license grant above
removes that restriction: it is what allows the project to stay
dual-licensed while still accepting community contributions. This is the
same mechanism used by widely adopted Contributor License Agreements
(CLA), enforced here on an opt-out-free, submission-equals-agreement
basis: the act of opening a pull request against this repository is your
signature to this agreement.

## Licensing of your contribution in the repository

Once accepted, your contribution will be published in the public repository
under CC BY-NC-SA 4.0 (or MIT, where it is a derivative of the MIT-licensed
historical snapshot), consistent with [`LICENSE`](./LICENSE). The license
grant above is in addition to — not instead of — that public licensing.

## Questions

If you have questions about the Contribution License, or you need to
contribute under different terms (for example, because your employer
requires a signed agreement), open an issue or contact the project owner
before submitting code.
