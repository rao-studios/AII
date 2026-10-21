# The aii command

[← AII](README.md) · [the stack](../../README.md)

`aii` with no arguments, in a terminal, opens the studio. Everywhere else it prints `aii status`. Every
subcommand manages this Mac's Ambient Intelligence Index: whose build is installed, the two servers,
your keys, the lanes and the models.

Four ways to run it:
- **`Scripts/setup.sh [debug|release] [--add-to-path]`.** The first one. It checks the toolchain,
  resolves the packages and runs `Scripts/install-cli.sh`, then checks that `aii` is on PATH and prints
  the line to add when it isn't (`--add-to-path` appends it to your shell profile). Next comes
  `aii setup`.
- **`Scripts/aii.command`.** Double-click it in Finder. It opens the studio from this checkout,
  building `aii` the first time. If the build or the studio fails, the window stays open with the exit
  code until a key is pressed.
- **`Scripts/cli.sh [arguments]`.** It builds `aii` when its sources are newer than the binary, then
  runs it with your arguments. `AII_CONFIG=release` builds release, and `AII_SKIP_BUILD=1` skips the
  build.
- **`Scripts/install-cli.sh [debug|release]`.** It puts `aii` on your PATH: it builds the command
  (release by default), copies it to `~/.rao/bin/aii` with `aii.json` beside it naming the checkout,
  and links it into `~/.local/bin` when that folder exists. When neither folder is on PATH, it prints
  the line to add. It builds only the command; `aii install` builds the servers.

## Where it acts

The home is `AII_HOME` when set, else `~/.rao`. `aii` acts as the stack identity, `aii`:
- it installs your own build, which every app keeps;
- it holds the stack with a pinned lease from `aii start` to `aii stop`;
- it reads every lane and writes none, and it never removes documents or groups from Thread;
- it manages the lanes manifest, `aii/lanes.json`: which apps have a lane, and whom each files under
  with no account.

## Commands

### Looking

| Command | What it does |
|---|---|
| `aii status [--json]` | Whose build is installed and from where, the contract, Sewn and Thread (pid, ports, proof, the embedder), who holds the stack, the lanes, your keys (`keys  Mistral ✓ (aii) · Tinker none · Supabase ✓`, never a value), and which models are on this Mac. The contract row sets the build's contract beside this `aii`'s, with the fix when they differ. `--json` prints the same report as JSON. |
| `aii doctor` | Runs every check and prints its fix. The checks: the home (layout 1, mode 0700); the secrets (each registered app and `aii`, 0600, 64 hex); the device key; the lanes (every secret has a manifest entry and every entry a secret; how many lanes are under `aii-local`; lanes registered under an older device key); the keys (`keys/providers.json` is 0600 and decodes; none is a supported state: the index runs on device); `supabase` (`aii/aii.env` holds both values or neither, and no API key; none passes: no accounts layer); the install (`AIIServer` matches `install.json`); its source (your build's private record, or Rao's signature); the contract; Sewn and Thread (verified, and the embedder); the models the index needs; and `aii` on PATH (fix: `Scripts/setup.sh --add-to-path`). Writes nothing. Exits 1 if any check fails. |
| `aii logs [sewn\|thread] [-f] [-n N]` | The last N lines (default 50) of a server's log, or both, from `aii/run/`. `-f` follows them. |

### Your build

| Command | What it does |
|---|---|
| `aii install [<checkout>] [--debug] [--no-build]` | Builds `AIIServer` and its Metal library from an AII checkout with `Scripts/build-servers.sh`, release unless `--debug`. Then installs it as your build: `source: local`, `installedBy: aii`, with the checkout's path, commit and configuration. Every app keeps it. `--no-build` installs what the checkout already built. When Sewn or Thread still runs the previous build, it prints `→ … running the previous build: aii restart`. It also copies the checkout's `.env`: `MISTRAL_API_KEY` and `TINKER_API_KEY` into `keys/providers.json` (`→ providers.json: MISTRAL_API_KEY set`, `already set`, or `kept: your account's key`), and `SUPABASE_URL` and `SUPABASE_ANON_KEY` into `aii/aii.env` where it has none. |
| `aii update` | Rebuilds your build from the checkout it came from, in the same configuration, and installs it again, copying `.env` the same way. |
| `aii uninstall --yes` | Removes your build and its record, so the next Rao app to launch installs its bundled copy. It refuses while Sewn or Thread runs, so run `aii stop` first. It also refuses an app's build, which that app manages. |

`aii install` builds from the first of these that is an AII checkout, and prints its choice on stderr:
1. the argument;
2. `AII_CHECKOUT`;
3. the installed build's checkout;
4. the checkout in `~/.rao/bin/aii.json`;
5. the checkout that holds this `aii`;
6. the checkout that holds the current folder.

A checkout holds `Package.swift` and `Scripts/build-servers.sh`.

### Running

| Command | What it does |
|---|---|
| `aii start` | Starts Sewn and Thread from the installed build, or adopts them when they run, and holds them with a pinned lease until `aii stop`. A new home is provisioned first. |
| `aii stop [--force]` | Releases `aii`'s lease and stops the servers when no app still holds them. While an app holds them it refuses, naming the app. `--force` stops them anyway. |
| `aii restart [sewn\|thread]` | Stops the server, or both, whoever holds it, and starts the installed build in its place. |

### First run

| Command | What it does |
|---|---|
| `aii setup [<checkout>] [--debug] [--no-build] [--no-install] [--no-start] [--no-models] [--no-prompt] [--mistral-key-stdin] [--supabase-url U] [--supabase-anon-key K]` | Everything a first run needs, and safe to run again. (1) Provisions `~/.rao`. (2) Takes your key: from the checkout's `.env`, else `--mistral-key-stdin`, else a hidden prompt for one API key of your choice (Mistral, then Tinker if you skip it; Enter for neither, and the index runs on device). Supabase is never asked for: it comes from `.env` or the two flags, for an app with accounts. (3) Builds and installs `AIIServer` when nothing is installed and a checkout is found; a Rao app's build is kept. (4) Starts the servers and holds them, as `aii start` does. (5) Pulls the two models the index needs. (6) Prints the doctor's checks. Each key lands with a masked line (`→ ~/.rao/keys/providers.json: MISTRAL_API_KEY set (…k9Qz)`). Exits 0 when every step it ran succeeded; the doctor's lines are information. |

### Keys, lanes, models and the home

| Command | What it does |
|---|---|
| `aii keys` | Your provider keys in `keys/providers.json`, masked (the last 4 characters), with their source, writer and date; then the Supabase pair from `aii/aii.env`. A key is read on every call, so a change is live with no restart; `aii.env` is read by Sewn at start. |
| `aii keys set <mistral\|tinker> [--stdin] [--force]` | Sets a key from a hidden prompt, or the first line of stdin with `--stdin` (`pbpaste \| aii keys set mistral --stdin`); never from an argument. A key your account handed over is kept unless `--force`. |
| `aii keys remove <mistral\|tinker> --yes` | Removes a key; the servers run on device without it. |
| `aii keys supabase [--url U] [--anon-key K] [--remove --yes]` | The Supabase project for an app with accounts: its URL and anon public key (never the service-role key) into `aii/aii.env`. When Sewn is running it prints `→ aii restart sewn`. |
| `aii lanes` | Every lane in the manifest: its name, display name, owner, lane id, whether its secret is there, and its documents when Thread answers. |
| `aii lanes add <name> [--display "Notes"] [--owner aii-local]` | Registers a lane from the terminal, the first time only: the secret and the manifest entry. A name is 2 to 32 of `a-z` and `0-9`, starting with a letter, and never `aii`. The first registration's display name stays. `--owner` sets whom its records are filed under with no account: `aii-local`, shared, or `local-<name>`, its own and the default (the Rao apps start under `aii-local`). |
| `aii lanes owner <name> aii-local\|local-<name>` | Switches a lane's no-account owner. Running servers read it within two seconds. Documents already filed keep their old owner until they are filed again. |
| `aii lanes doctor [<name>]` | Walks one lane, or every lane, down the stack as the app itself: the manifest, the secret, the lane id, admission by both servers, Thread's view, the groups, a sample of the records, the owner, and recent log lines. Each layer passes or prints its fix; the first that fails is where to look. Writes nothing. Exits 1 if a lane fails. |
| `aii lanes remove <name> --yes` | Removes the app's secret and manifest entry. Its documents stay in Thread, and `aii lanes add <name>` finds them again. It refuses while the app runs. |
| `aii models` | Every pinned model, its revision, and whether it is on this Mac. It asks Sewn, so the stack must be up. |
| `aii models pull <role>` | Fetches a pinned model at its commit and waits for it. The roles are `embedding`, `generalSmall`, `generalStandard`, `generalLarge`, `vision` and `coding`. |
| `aii models remove <role> --yes` | Deletes a pinned model from this Mac. |
| `aii reset [--yes]` | Brings the home back to a fresh layout 1. It stops the servers and removes `aii/bin/`, `aii/install.json`, `aii/run/`, `aii/leases/` and `layout.json`. It keeps the secrets, the keys, the lanes manifest, Sewn's data, the index and the models. Without `--yes` it only says what would go. It refuses while an app runs. |

## The studio

There are five screens. `1`–`5` switch between them.

| Screen | Shows | Keys |
|---|---|---|
| **1 Index** | whose build, the contract, Sewn and Thread (pid, ports, proof, the embedder) and who holds them, live | `i` install your build, `u` update it once it is yours, `s` start or stop, `r` restart |
| **2 Lanes** | every lane in the manifest: display name, owner, lane id, secret, documents | `a` add (a name, then a display name), `o` switch the owner between `aii-local` and `local-<name>` (`y` to confirm), `d` the lane doctor in a pane, `x` remove (type the name to confirm), `⏎` details, `↑` `↓` select |
| **3 Models** | every pinned model, whether it is on this Mac, and download progress | `p` pull, `x` remove (`y` to confirm), `↑` `↓` select |
| **4 Logs** | Sewn's or Thread's log, followed | `tab` switch |
| **5 Doctor** | every check with its fix | `r` run again |

On every screen, `?` lists every key, `esc` closes a prompt and `q` quits. Two Ctrl-Cs within a second
and a half always quit, with exit code 130.

How it behaves:
- **Each key calls the same library function as its command**, so the studio adds no logic of its own.
- **One action runs at a time.** The screens keep reading while it runs.
- **An empty home is a state, not an error.** Index says nothing is installed and offers `i`.
- **Lanes points at the example.** Its footer names `swift run --package-path Examples/Notes`, the way
  to watch a custom lane fill.

Display variables:
- `AII_COLOR=truecolor|256|16|none` sets the colour depth.
- `AII_ASCII=1` draws ASCII glyphs.
- `AII_NO_ITALIC=1` turns italics off.
- `AII_UI_THEME=terminal` keeps the terminal's own background.
- `AII_TUI_STATS=1` shows frames per second and bytes per frame in the top-right corner.

What libraries print while the studio runs goes to `aii-studio.log` in the temporary folder
(`$TMPDIR`).

## The example

`Examples/Notes` is the smallest app on the index, and the shape every custom app takes. With AII
installed, run it from the checkout:

```sh
swift run --package-path Examples/Notes
```

It registers the `notes` lane, files three notes, recalls them as `Note`s, asks a cited question (on
device, or through your key), and forgets its group. `aii lanes` then lists `notes`, `aii lanes doctor notes` walks it down
the stack, and `aii lanes remove notes --yes` takes it away. The code is walked through in [AII → Join](README.md#join).

## Environment

| Variable | Meaning |
|---|---|
| `AII_HOME` | The home (default `~/.rao`). |
| `AII_CHECKOUT` | The checkout `aii install` builds from when no argument names one. |
| `AII_NO_UI` | Bare `aii` prints `aii status` instead of opening the studio. `TERM=dumb` does the same. |
| `AII_COLOR`, `AII_ASCII`, `AII_NO_ITALIC`, `AII_UI_THEME`, `AII_TUI_STATS` | The studio's display (see above). |
| `AII_CONFIG`, `AII_SKIP_BUILD` | `Scripts/cli.sh`: the build configuration (default debug), and skipping the build. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | `aii doctor` or `aii lanes doctor` found a failing check |
| 64 | Usage: a bad argument, lane name or checkout, a missing `--yes`, `aii stop` while an app holds the stack, or a key with no terminal to ask on and no `--stdin`, an empty key, or a provider `aii` doesn't know |
| 65 | Bad data: an installed binary that no longer matches its record, a bad signature, a refused request, a failed download |
| 66 | Missing: nothing installed, nothing built, no build of yours, no such lane, no log yet |
| 69 | Unavailable: a server that does not answer, or answers with an error |
| 70 | Internal error |
| 75 | Temporary: an app is running, or Sewn and Thread are; try again after |
| 78 | Configuration: the home, a contract gap, an untrusted record, a refused secret |
| 130 | Interrupted |
