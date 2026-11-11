# Working on Anode

## Versions (every push)

`VERSION` in `build-app.sh` is the version About shows. Bump it with every push, by what the push contains:

- **Bug fix, speed or battery work, anything with no new capability** → last number: 1.15.0 → 1.15.1.
- **A new feature, or a visible change in how something works** → middle number, last back to 0: 1.15.1 → 1.16.0.
- **A rewrite or a break** → first number. Only when the owner says so.

When several kinds are in one push, the biggest wins. Then, in the same push:

1. Add the new version at the top of `CHANGELOG.md` (date, plain bullets for the person using the app).
2. Rewrite `UPDATE-NOTE.md`: two plain sentences saying what this update is. The update screen and `update.sh` show them.
3. Tag the release commit `vX.Y.Z` (annotated) and push the tag with the branch.

`Tests/PowerKitTests/ReleaseFilesTests.swift` fails if `VERSION`, the top changelog entry and the note disagree.

## Every change

- Run `./test.sh --quick` before pushing. Run `./update.sh` after a change and confirm `BSSourceCommit` in the installed
  `Info.plist` equals `git rev-parse --short HEAD` and that the running process's inode matches the installed binary.
- Never put a tester's name, or words like "friend", in a commit, comment or test.
- Do not rewrite pushed history or move a pushed tag without the owner saying so.
