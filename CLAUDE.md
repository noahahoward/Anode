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
4. Create the GitHub Release for that tag, so the Releases box on GitHub matches the app (pushing a tag does not create one). Title
   `Anode X.Y.Z`, notes = that version's CHANGELOG entry, no files attached (there is no download), and mark it Latest:
   `gh release create vX.Y.Z --title "Anode X.Y.Z" --notes-file <notes> --verify-tag --latest`. Only after the owner says push.

`Tests/PowerKitTests/ReleaseFilesTests.swift` fails if `VERSION`, the top changelog entry and the note disagree.

## Every change

- Do not run tests, and do not commit for a push or push, until the owner says to push. (Building to see that the code compiles
  is fine.) A fix that works is not a push, and "it works" is not "push": ask.
- When the owner says push, the full suite (`./test.sh --full`) must pass before the push. Pushing without it only when the owner
  explicitly confirms that override.
- Work split across subagents: they only edit. They never run `swift build`, `swift test` or `./test.sh` themselves (each copy of
  the repo compiles the whole package, and several at once drained the battery at hundreds of percent per hour). Once their
  changes are merged, build and test everything they touched together, once: one big tested change, not many small ones.
- Run `./test.sh --full` before pushing: the suite plus a real install in a new folder next to the checkout, then the installed
  app (as a sandboxed test copy, `AppSandbox`) is driven through Settings and its Uninstall button, which fails on an error in
  what the install prints, on anything the uninstall leaves behind, or on any change to this Mac's own Anode. It needs
  Accessibility for the program that runs it (`ANODE_TEST_NO_UI=1` skips the button) and shows windows on screen.
  `./test.sh --quick` is for iterating (the git pre-push hook runs it). Run `./update.sh` after a change and confirm `BSSourceCommit` in the installed
  `Info.plist` equals `git rev-parse --short HEAD` and that the running process's inode matches the installed binary.
- Never put a tester's name, or words like "friend", in a commit, comment or test.
- Do not rewrite pushed history or move a pushed tag without the owner saying so.
