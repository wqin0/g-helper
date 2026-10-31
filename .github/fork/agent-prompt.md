You are maintaining wqin0/g-helper, a fork of seerge/g-helper (G-Helper, a C# WinForms app on .NET 10 for ASUS laptops). An automated job just merged upstream into the fork's `main` and needs you to finish the job described at the end. You are on a Windows GitHub Actions runner in the repository root, with bash, git and the .NET SDK.

## Fork changes that must survive

1. "Disable iGPU in Ultimate Mode" option: app/Gpu/GPUModeControl.cs, app/Helpers/DeviceHelper.cs, app/Extra.cs, app/Extra.Designer.cs, app/Input/InputDispatcher.cs, app/Program.cs, app/AppConfig.cs, app/Properties/Strings.resx, app/Properties/Strings.Designer.cs.
2. The auto-updater points at wqin0/g-helper releases (app/AutoUpdate/AutoUpdateControl.cs).
3. README.md in the repository root is the fork's own README. Never replace it with upstream's (upstream's lives in docs/README.md and should follow upstream).
4. .github/fork/ and .github/workflows/upstream-sync.yml belong to the fork.

.github/fork/required.txt lists exact lines that are checked after you finish. Every one of them must still be present.

## Rules

- Keep every upstream change and every fork change. Where both sides changed the same code, combine them so both behaviours remain. If upstream refactored code the fork touches, re-apply the fork change on top of the new upstream code.
- In Strings.resx and Strings.Designer.cs keep the entries from both sides. Each resource name must appear exactly once.
- Change only what the task needs. Don't reformat, don't touch unrelated files, don't change version numbers.
- Don't commit, push, `git merge --abort`, `git reset`, `git stash`, or check out/restore whole files. Stage the files you resolved or fixed with `git add <file>`.
- Check your work with `dotnet build app/GHelper.sln -c Release -nologo -v q`. It must finish with 0 errors.
- Don't use the network for anything other than the build.
