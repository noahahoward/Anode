# Releases

Built with `./make-release.sh`, which produces three files per version:

```
BetterStats-<version>.app     the bundle
BetterStats-<version>.zip     the same bundle, packed with ditto
BetterStats-<version>.txt     version, source commit, build time, sha256
```

The `.txt` matters more than it looks. There is **no update mechanism**, so a
tester may be running anything; the bundle records the exact commit it was built
from in `BSSourceCommit`, and a report of "it does X" can be tied to source
rather than guessed at. Read it back off any bundle with:

```
defaults read /path/to/BetterStats.app/Contents/Info.plist BSSourceCommit
```

## Before you send this to anyone

The bundle is **ad-hoc signed and not notarised**. Read this part rather than
skipping it, because the obvious workaround is a genuinely bad idea here.

A `.app` that arrives over the internet — AirDrop, email, a download — gets the
quarantine attribute, and macOS will refuse to open this one. The usual advice
is `xattr -dr com.apple.quarantine`, and for this app that means asking someone
to disable the one check standing between "a binary a friend sent me" and "a
binary running with my full user privileges". BetterStats is deliberately
**unsandboxed** and enumerates every process on the machine. That is necessary
for what it does and it is exactly why the check exists.

**Preferred: have them build it.** A locally built bundle is never quarantined,
so the problem disappears instead of being disabled:

```
git clone <repo> && cd better-stats-app && ./build-app.sh
```

It needs Xcode. That is the whole cost. `git pull && ./build-app.sh` is also the
only update mechanism there is.

See [../TESTING.md](../TESTING.md) for what to expect on hardware this was not
calibrated on, what the app reads, and what is worth reporting back.

## Why the binaries are not committed

`.gitignore` excludes the `.app` and `.zip`; the `.txt` manifests are kept.

A release bundle is ~10 MB and cannot be removed from git history later without
rewriting it for everyone who has cloned. Since the recommended distribution
path is "build from source" anyway, committing the binary buys little and costs
permanently. If you do want them tracked — to hand someone a repo link and have
the artifact already in it — drop the two ignore lines and commit; that is a
deliberate choice, not an oversight.
