# Platforms — macOS, Linux and Windows (WSL)

Every skill here is bash plus Python 3 with the standard library only, so it runs wherever both
exist. macOS and Linux are first-class. **Windows is supported through WSL 2 only.** Native Windows
shells (PowerShell, cmd, Git Bash) are not supported, because the hooks rely on POSIX paths, file
modes and symlinks.

The rest of the docs assume a Unix shell. This page is where the platforms differ.

---

## Installing the base tools

| Tool        | macOS (Homebrew)                                   | Debian / Ubuntu / WSL                                                                        | Fedora / RHEL                |
| ----------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------- | ---------------------------- |
| git         | `brew install git`                                 | `sudo apt install git`                                                                       | `sudo dnf install git`       |
| python3     | `brew install python`                              | `sudo apt install python3`                                                                   | `sudo dnf install python3`   |
| node        | `brew install node`                                | [NodeSource](https://github.com/nodesource/distributions) or a version manager such as `fnm` | same as Debian               |
| pnpm / yarn | `corepack enable`                                  | `corepack enable`                                                                            | `corepack enable`            |
| gh          | `brew install gh`                                  | [cli.github.com install guide](https://github.com/cli/cli/blob/trunk/docs/install_linux.md)  | `sudo dnf install gh`        |
| pipx        | `brew install pipx`                                | `sudo apt install pipx`                                                                      | `sudo dnf install pipx`      |
| trash       | built into recent macOS; else `brew install trash` | `sudo apt install trash-cli`                                                                 | `sudo dnf install trash-cli` |

After installing pipx, run `pipx ensurepath` and open a new terminal.

Sources: [pipx installation](https://pipx.pypa.io/stable/),
[trash-cli](https://github.com/andreafrancia/trash-cli),
[corepack](https://nodejs.org/api/corepack.html).

`trash-cli` installs `trash-put`, and on most distributions a `trash` alias as well. If
`command -v trash` finds nothing after installing it, add `alias trash=trash-put` to your shell rc.
The skills fall back to `trash-put` or `gio trash` on their own. The alias is for you and for the
assistant, which is told to use `trash`.

---

## Windows — set up WSL first

1. Install WSL 2 with a Ubuntu distribution: `wsl --install` in an administrator PowerShell, then
   restart ([Microsoft guide](https://learn.microsoft.com/windows/wsl/install)).
2. In VS Code, install the **WSL** extension. Open repos with `code .` from inside the WSL
   terminal, so VS Code, its extensions and every hook run on the Linux side
   ([VS Code WSL guide](https://code.visualstudio.com/docs/remote/wsl)).
3. Install every tool from the Debian / Ubuntu column above **inside WSL**, including the AI
   assistant's CLI. A Windows install of `node` or `git` is invisible to WSL hooks, and vice versa.
4. Follow [Onboarding — a new developer](onboarding-new-developer.md) from step 1, inside WSL.

Two rules prevent most WSL problems:

- **Keep repos in the Linux filesystem** (`~/src/acme-api`), never under `/mnt/c/...`. Across the
  `/mnt/c` boundary, file watching is unreliable, file modes are lost (hooks lose their exec bit),
  graph builds are many times slower, and lock files behave differently.
- **Keep LF line endings.** A shell script checked out with CRLF fails with `bad interpreter`.
  `setup-project-tooling` commits a `.gitattributes` with `*.sh text eol=lf` for this reason. Also
  set `git config --global core.autocrlf input` inside WSL.

---

## Differences the skills already absorb

You do not need to do anything about these. They are listed so that an odd message makes sense.

| Difference                                       | How the skills handle it                             |
| ------------------------------------------------ | ---------------------------------------------------- |
| macOS has no `flock`                             | a `mkdir`-based lock                                 |
| `md5sum` (GNU) vs `md5` (BSD)                    | a shim picks whichever exists                        |
| `timeout` (GNU) vs `gtimeout` or nothing (macOS) | a shim, or the step runs without a timeout           |
| BSD vs GNU `sed -i`                              | installers edit files with Python, not `sed`         |
| macOS ships bash 3.2                             | installers avoid bash 4 features                     |
| case-insensitive filesystems (macOS default)     | `.gitignore` patches for `MANIFEST` and `[Ss]cripts` |

---

## Differences you may hit

| Symptom                                                                   | Cause and fix                                                                                                                                                                                                     |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a hook says `gh` or `pipx` is not found, though it works in your terminal | hooks run in a non-login shell that may not load your profile. On Apple Silicon, `/opt/homebrew/bin` is the usual one missing. Put the `PATH` export in `~/.zshenv` (zsh) or make sure `~/.bashrc` sets it (bash) |
| `handoff claim` says it "cannot reach the board's remote"                 | usually the same `PATH` problem: git's credential helper is `gh`, which the hook cannot find. Check `PATH` before the network                                                                                     |
| `readlink: illegal option -- f`                                           | macOS older than 12.3. Upgrade macOS, or `brew install coreutils`                                                                                                                                                 |
| zsh prints "command not found" followed by the whole command line         | one binary in it is missing. zsh echoes the full line, which makes it look like a quoting bug                                                                                                                     |
| a hook works for you but not for a teammate on another OS                 | check its exec bit (`git ls-files -s path`, mode `100755`) and its line endings (`git ls-files --eol path`)                                                                                                       |
