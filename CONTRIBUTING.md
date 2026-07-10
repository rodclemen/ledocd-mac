# Contributing to LED OCD for Mac

Bug reports, feature requests, documentation improvements, and pull requests
are welcome.

## Before opening an issue

- Search existing issues to avoid duplicates.
- Confirm that the problem still occurs in the latest release.
- Remove passwords, serial numbers, Apple credentials, personal information,
  and other secrets from screenshots and logs.
- Use GitHub's private vulnerability reporting for security problems instead
  of opening a public issue.

## Bug reports

Please include:

- the LED OCD for Mac version;
- the macOS version;
- the Mac model and whether it uses Apple silicon or Intel, when relevant;
- the LED OCD or GI OCD hardware and firmware version, when known;
- clear steps to reproduce the problem;
- what you expected to happen;
- what actually happened; and
- relevant logs or screenshots with sensitive information removed.

## Feature requests

Describe the problem or workflow the feature would improve. A suggested
interface is useful, but the underlying use case matters more.

## Pull requests

Keep each pull request focused on one change.

Before submitting:

1. Build the project with `./build.sh`.
2. Test the affected workflow, using real hardware when the change requires it.
3. Update the README or manual when behavior changes.
4. Add a clear entry to `CHANGELOG.md` for user-visible changes.
5. Do not commit build products, credentials, signing files, or personal data.
6. Do not copy additional code, data, documentation, images, or other material
   from ledocd.com, Harold Toler's original software, or another project unless
   its license or written permission clearly allows it.
7. Confirm that you have the right to contribute everything in the pull
   request.

## Contribution licence

By submitting a contribution to this repository, you agree to license that
contribution under the repository's `LICENSE`, including the Commons Clause
License Condition.

You retain copyright in your contribution. You confirm that the contribution
is your original work or that you have sufficient permission to submit and
license it under those terms.

A contribution may be declined when its origin or licensing is unclear.
