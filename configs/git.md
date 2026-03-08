# git options

Configure git with sensible defaults using `git config --global` (user) or `git config --system` (system-wide).

## Default settings

```shell
git config --global init.defaultBranch development
git config --global fetch.prune true
git config --global branch.sort -committerdate
git config --global push.autoSetupRemote true
git config --global column.ui auto
git config --global tag.sort -version:refname
git config --global diff.colorMoved zebra
git config --global diff.algorithm histogram
git config --global merge.conflictstyle diff3
git config --global help.autocorrect prompt
```

### Conditional settings

```shell
# Only if nano is installed:
git config --global core.editor nano
```

## Setting details

| Setting | Value | Purpose |
|---------|-------|---------|
| `init.defaultBranch` | `development` | New repositories use `development` as the default branch |
| `fetch.prune` | `true` | Automatically remove remote-tracking branches that no longer exist on the remote |
| `branch.sort` | `-committerdate` | List branches by most recent commit first |
| `push.autoSetupRemote` | `true` | Automatically set up remote tracking on first push (no more `git push -u`) |
| `column.ui` | `auto` | Display branch, tag, and status output in columns when terminal is wide enough |
| `tag.sort` | `-version:refname` | Sort tags by version number (v1.0 < v1.1 < v2.0) instead of alphabetically |
| `diff.colorMoved` | `zebra` | Highlight moved code blocks with alternating colors in diffs |
| `diff.algorithm` | `histogram` | Use histogram diff algorithm for more readable diffs |
| `merge.conflictstyle` | `diff3` | Show the original (base) text alongside ours/theirs in merge conflicts |
| `help.autocorrect` | `prompt` | When a command is mistyped, prompt whether to run the closest match |
| `core.editor` | `nano` | Use nano as the default editor for commit messages, interactive rebase, etc. (only set if nano is installed) |

## Git LFS

Git LFS (Large File Storage) is also initialized if the `git-lfs` package is installed. This sets up the smudge/clean filters needed for LFS-tracked files:

```shell
git lfs install
```

For system scope, use `git lfs install --system` to initialize for all users.

## Scope

- **User scope** (`git config --global`): writes to `~/.gitconfig`, affects current user only
- **System scope** (`git config --system`): writes to `/etc/gitconfig` (Linux) or `/opt/homebrew/etc/gitconfig` (macOS), affects all users
