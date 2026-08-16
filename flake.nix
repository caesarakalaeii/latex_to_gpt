{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "latex_to_gpt -- Python script that rewrites LaTeX thesis chapters via the OpenAI chat API. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose: flake.lock holds exactly one node.
  # The system list and the genAttrs helper that a flake-utils
  # `eachDefaultSystem` would supply are the `systems` / `forAllSystems` pair
  # inside the canonical machinery below, so the list stays editable here
  # instead of living in a second input.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed argument set: a second input added later would
    # otherwise abort at eval. Measured with a throwaway flake declaring
    # `outputs = { nixpkgs }:`, which nix rejects with
    #   error: function 'outputs' called with unexpected argument 'self'
    # -- nix always passes `self`, and this style needs it: `self` is the only
    # way a wrapper sitting in the store can name this repo's own files, which
    # is what anchors every verb (see rootPreamble). The cost is that every
    # wrapper's store path changes whenever any TRACKED file changes.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # ======================================================================
      # PER-REPO BLOCK 5 -- the name in the interactive banner
      # ======================================================================
      repoName = "latex_to_gpt";

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # `checks.toolchain` realises this closure, so a typo'd attr name fails at
      # the flake gate instead of surfacing as "command not found" halfway
      # through a task.
      #
      # No texlive here, and that is a finding rather than an oversight: despite
      # the repo name, nothing in this tree compiles LaTeX. text_smoother.py
      # opens RAW_FILE_LOCATION = 'latex.txt' as plain text, splits it on
      # \section / \subsection, sends the parts to the OpenAI chat API and
      # writes the reply to 'smoothed_output'. Grepping every tracked .py and
      # .md for documentclass, latexmk, pdflatex, subprocess, texlive or a .tex
      # path matches nothing. Carrying a TeX distribution to compile nothing is
      # not free: at this lockfile's nixpkgs the texliveSmall closure measures
      # 626240848 bytes (`nix path-info -S`), i.e. ~626 MB of store to realise
      # before the first verb runs.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: an attr that disappears
      # in a nixpkgs bump is then reported as a bare `error: undefined variable
      # '<name>'` (measured) with no hint of which set it came from, and the
      # name is not greppable.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        # Pinned by MAJOR, never `pkgs.python3`: at this lockfile's nixpkgs the
        # rolling alias is python3 3.14.7 while python313 is 3.13.15, so the
        # alias would move the interpreter -- and invalidate .venv -- under a
        # lock bump that looks unrelated.
        pkgs.python313
        pkgs.uv
        pkgs.ruff

        # ---- general tooling, called by no verb below ----
        # git is not decoration here: $SRC_ROOT contains TRACKED files only, so
        # `git add` is what makes a new file visible to a verb.
        pkgs.git
        # `nix flake show --json` is the machine-readable command map.
        pkgs.jq
        # This tree has no Makefile today; make is on PATH for ad-hoc use.
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # `setup` installs manylinux wheels, whose .so files are dlopened at
      # runtime: neither patchelf nor the nix linker ever sees them, and this is
      # NixOS, so there is no /usr/lib to fall back on (`ls
      # /usr/lib/libstdc++.so.6` -> No such file or directory).
      # stdenv.cc.cc.lib supplies libstdc++, the one that breaks such imports.
      #
      # Measured on 2026-08-15, so the next agent need not guess. This repo's
      # CURRENT dependency set does not need it: `openai<1` resolves to
      # openai 0.28.1 and pulls aiohttp 3.14.3, whose compiled extension links
      # libc, libpthread and the vdso only (ldd), and `import openai, aiohttp`
      # succeeds with LD_LIBRARY_PATH unset. It is kept because it goes
      # load-bearing the moment anyone adds an ordinary compiled wheel to the
      # same venv: after `uv pip install numpy` (numpy 2.5.2), `import numpy`
      # fails with `libstdc++.so.6: cannot open shared object file: No such file
      # or directory` when LD_LIBRARY_PATH is unset and succeeds with this entry
      # on it. Keep the list minimal -- LD_LIBRARY_PATH is a blunt instrument,
      # and an entry nobody can demonstrate a need for is an entry that should
      # go (zlib used to sit here and none of the above needed it).
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Constants only. They are applied to BOTH surfaces -- the dev shell and
      # every wrapper -- so a verb cannot behave differently depending on how it
      # was invoked. Anything that must READ an existing value
      # (LD_LIBRARY_PATH) or UNSET one (SOURCE_DATE_EPOCH) is the machinery's
      # job, not this attrset's.
      envVars = pkgs: {
        # Keep uv on THIS shell's interpreter. Measured without it: with nix's
        # python313 (3.13.15) first on PATH, `uv venv` still built the venv from
        # ~/.local/share/uv/python/cpython-3.13.14-linux-x86_64-gnu -- a
        # portable CPython uv had fetched for itself. Two interpreters, one
        # venv, and nothing in the output says which one is live.
        UV_PYTHON = "${pkgs.python313}/bin/python";
        # ...and do not fetch a further one: `uv venv --help` documents
        # `--no-python-downloads` as `[env: "UV_PYTHON_DOWNLOADS=never"]`, i.e.
        # downloading is what uv does by default when it finds no interpreter it
        # likes. An unattended verb must fail loudly instead.
        UV_PYTHON_DOWNLOADS = "never";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth: it generates `apps` (so `nix run .#run`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` cannot disagree with what
      # `dev-run` actually runs.
      #
      # `build` and `test` are absent on purpose. `git ls-files` lists six
      # files: .gitignore, README.md, api_secrets_example.py, flake.lock,
      # flake.nix, text_smoother.py. No artifact is produced, and there is no
      # test suite, no pytest, no tests directory and no CI workflow to point a
      # verb at. A stub echoing "not applicable" would only turn this map into a
      # liar; absence is information.
      #
      # Each `text` is bash under `set -euo pipefail`, shellcheck'd at BUILD
      # time, and runs with $REPO_ROOT, $SRC_ROOT and `need_writable_checkout`
      # already in scope. $REPO_ROOT is never empty -- it is the read-only store
      # snapshot when the caller stands outside any checkout -- so a verb that
      # writes calls the guard, and a verb that only reads does not.
      commands = pkgs: {
        setup = {
          # The dependency set is derived from the imports, because there is
          # nothing else to derive it from: no requirements.txt, no
          # pyproject.toml and no lockfile is tracked, and the README's install
          # step is the single line `pip install openai`. text_smoother.py
          # imports openai, os and api_secrets; only openai is third-party.
          #
          # The <1 bound is load-bearing, not caution. text_smoother.py uses the
          # pre-1.0 surface -- `openai.api_key = ...` (line 7) and
          # `openai.ChatCompletion.create(...)` (line 51) -- and on a current
          # openai (3.1.0 today) that call raises APIRemovedInV1: "You tried to
          # access openai.ChatCompletion, but this is no longer supported in
          # openai>=1.0.0". Measured, not assumed. Drop the bound only together
          # with porting the script to `OpenAI().chat.completions.create`.
          #
          # It is also why this shell cannot be made offline with
          # `python313.withPackages`: at this lockfile's nixpkgs,
          # python313Packages.openai is 2.41.1 -- the major this code cannot run
          # against.
          #
          # --allow-existing is not cosmetic. Measured: a second `uv venv` over
          # an existing .venv exits 2 with "error: Failed to create virtual
          # environment / Caused by: A virtual environment already exists at:
          # .venv", BEFORE the install line runs -- so without the flag the
          # bootstrap verb failed on exactly the trees that had already been set
          # up, which is every retry. Not --clear: that deletes a working venv
          # to re-download what is already in it.
          description = "(network) create/update .venv with the openai client the script needs";
          # A .venv belongs to a checkout, and the snapshot is read-only, so
          # there is nothing sensible to do without one -- least of all
          # unpacking a venv into whichever directory the caller stood in.
          text = ''
            need_writable_checkout
            uv venv --allow-existing "$REPO_ROOT/.venv"
            uv pip install --python "$REPO_ROOT/.venv/bin/python" 'openai<1'
          '';
        };
        run = {
          # Absolute interpreter path, not a bare `python`: the wrappers PREPEND
          # the nix toolchain to PATH, so a bare name resolves to the store copy
          # and misses everything `setup` installed into .venv.
          #
          # The `cd` is a fix, not a preference. text_smoother.py hardcodes
          # RAW_FILE_LOCATION = 'latex.txt' (line 34) and
          # open('smoothed_output', 'w') (line 70), both relative to the PROCESS
          # cwd, so without it `nix run /path/to/this-repo#run` would read
          # whatever latex.txt sat in the caller's directory and write
          # smoothed_output next to it. Measured with the cd in place: run from
          # a subdirectory of the checkout it read the root's latex.txt and
          # wrote the root's smoothed_output, leaving the subdirectory empty.
          # That matches the README's contract, "Place your LaTeX code file in
          # the same directory as the script".
          #
          # Needs api_secrets.py (copy api_secrets_example.py and fill in the
          # key), a latex.txt in the root, and .venv from `setup`. All three are
          # gitignored and therefore absent from the snapshot: another verb that
          # cannot work without a checkout.
          description = "smooth latex.txt into smoothed_output, both in the repo root (needs `setup`, api_secrets.py, network)";
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            "$REPO_ROOT/.venv/bin/python" "$REPO_ROOT/text_smoother.py" "$@"
          '';
        };
        lint = {
          description = "ruff check (the whole repo, from any directory)";
          # `cd` first, then a bare `.` default. Both halves are load-bearing:
          # `ruff check "$@"` alone would grade the caller's cwd, and even
          # `ruff check "''${@:-$REPO_ROOT}"` grades the cwd the moment the
          # caller passes a flag rather than a path (`--fix`, `--show-files`),
          # because any argument at all suppresses the default -- measured:
          # `ruff check --show-files` with no path prints the files in $PWD.
          # Standing in the root closes both holes and makes a relative path
          # argument mean the same thing from anywhere.
          #
          # --no-cache always, not just outside a checkout. ruff writes its
          # incremental cache into the PROCESS cwd, not next to the files it was
          # handed (measured: `ruff check ../elsewhere` leaves .ruff_cache in
          # $PWD), and when that cwd is the read-only snapshot it does not
          # degrade -- it exits 2 with "Failed to initialize cache at
          # <dir>/.ruff_cache: Permission denied". Two files do not need a
          # cache, and a repo that keeps no .ruff_cache cannot commit one.
          text = ''
            cd "$REPO_ROOT"
            ruff check --no-cache "''${@:-.}"
          '';
        };
        fmt = {
          description = "ruff format (rewrites files, so it needs the checkout)";
          # MUTATING, hence the guard and no fallback to the snapshot: a
          # formatter that quietly falls back to the caller's directory rewrites
          # source that has nothing to do with this project, which is what
          # checks.verbAnchoring pins. --no-cache for the same reason as lint:
          # no verb of this repo leaves a .ruff_cache behind.
          text = ''
            need_writable_checkout
            cd "$REPO_ROOT"
            ruff format --no-cache "''${@:-.}"
          '';
        };
      };

      # ======================================================================
      # PER-REPO BLOCK 6 -- checks that know what this repo's verbs do
      # ======================================================================
      # The canonical `anchoring` check proves the MECHANISM -- rootPreamble and
      # guardPreamble -- behaves. It cannot prove that THIS repo's verbs use it,
      # which is what this check is for. It supersedes a check of the same
      # purpose that used to sit INSIDE the region this repo labelled generic
      # and byte-identical, while asserting on dev-lint, dev-fmt, .venv and
      # .ruff_cache by name -- repo-specific reasoning, hence this section.
      #
      # The build sandbox is an honest stand-in for "some unrelated directory":
      # no git repo, no checkout of this repo on the path up to /, and no Python
      # in it but what the probe plants.
      extraChecks = pkgs: {
        verbAnchoring =
          pkgs.runCommand "verb-anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              set -euo pipefail

              mkdir decoy
              cd decoy
              printf 'import os,sys\nx  =1\n' > decoy_only.py
              printf '{\n  description = "not this repo";\n  outputs = _: { };\n}\n' > flake.nix
              cp -r . ../decoy.orig

              # A read-only verb must grade THIS repo from any directory.
              # Asserted on WHICH files were read (--show-files) rather than on
              # findings or exit code, so this check does not start lying the
              # day someone fixes the last ruff warning. Grep by NAME, not by
              # directory: had the anchor landed on the decoy, ruff would print
              # paths inside it and a grep for the string "decoy" would match --
              # but a grep for a filename this repo does not contain is the test
              # that cannot be satisfied both ways.
              dev-lint --show-files > files.log 2>&1
              grep -q '/text_smoother.py$' files.log || {
                echo "dev-lint did not read this repo:" >&2
                cat files.log >&2
                exit 1
              }
              if grep -q decoy_only files.log; then
                echo "dev-lint read the caller's directory:" >&2
                cat files.log >&2
                exit 1
              fi

              # ...and every verb that writes or keeps state must refuse rather
              # than improvise a checkout out of $PWD. setup and run would also
              # need the network, so this doubles as proof that they exit before
              # reaching it -- inside the sandbox there is none.
              for verb in fmt setup run; do
                if "dev-$verb" > "$verb.log" 2>&1; then
                  echo "dev-$verb should have refused outside a checkout:" >&2
                  cat "$verb.log" >&2
                  exit 1
                fi
              done

              # Nothing whatsoever may have appeared next to the caller: not a
              # reformatted file, not a .venv, not even a .ruff_cache. Every
              # file the probe itself creates is named *.log, so the exclusion
              # cannot be hiding one of theirs.
              diff -r --exclude='*.log' . ../decoy.orig

              touch "$out"
            '';
      };

      # >>>>> BEGIN CANONICAL MACHINERY v1 <<<<<
      # ======================================================================
      # Everything from the BEGIN sentinel above to the END sentinel on the last
      # line of this file is fleet-canonical text: the same bytes in every repo
      # that carries this flake style. That is a checkable claim, not a boast --
      #
      #   sed -n '/BEGIN CANONICAL MACHINERY v1/,$p' flake.nix | sha256sum
      #
      # prints the same digest in every repo, or one of them has been edited.
      # (`,$p`, not a range ending on the END sentinel: a range whose closing
      # pattern were spelled out here would terminate on this very comment.)
      # Nothing here names a repository, a language, a tool or a project file.
      # If you find such a name below, it is contamination: the fix is to move
      # it into the per-repo section above, never to special-case it here.
      #
      # This region READS exactly these names from the per-repo section:
      #   nixpkgs  self  lib  repoName  toolchain  nativeLibs  envVars
      #   commands  extraChecks
      # and DEFINES exactly these:
      #   systems  forAllSystems  ldPreamble  rootPreamble  guardPreamble
      #   wrappers  helpFor  anchorCheck
      # plus the four flake outputs apps / devShells / checks / formatter.
      # Anything else in scope is invisible to it. The types of those eight
      # inputs, and the shell variables this region exports into command texts,
      # are specified in INTERFACE.md, which travels with this block.
      #
      # To change behaviour here you change it in every repo at once and bump
      # the version in both sentinels. A local edit is a bug by construction:
      # the digest above stops matching, and -- because rootPreamble anchors on
      # flake.nix byte-identity -- an edited working tree also stops being
      # recognised by wrappers built from the previous revision.
      # ======================================================================

      # ---- systems policy: decided once for the whole fleet ----
      #
      # Read this list as "evaluated on three, built on one". That is what was
      # measured, and it is all it means:
      #   * `nix flake check --all-systems` passes, so every output attribute
      #     below EVALUATES on all three systems.
      #   * only x86_64-linux has ever been BUILT. The machine this was verified
      #     on has no aarch64 emulation -- no binfmt handler, and `extra-
      #     platforms` is x86-only -- so aarch64 cannot be built there at all.
      # It is not a statement that anything works on aarch64. Do not upgrade it
      # into one in a README.
      #
      # Evaluating all three is still worth its seconds, because the failure it
      # catches is an eval-time failure: a `pkgs.<attr>` that exists on Linux
      # and not on darwin (`stdenv.cc.cc.lib` is the usual one) throws during
      # evaluation, and `nix flake check` without --all-systems checks only the
      # current system and sails straight past it.
      #
      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with a `throw`. genAttrs is lazy, so plain `nix develop`
      # on Linux would not notice -- it detonates later, on the --all-systems
      # run this policy requires. Add it back only against a separate
      # nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather
      # than a system string, because that is what every call site wants, and
      # keeps the system list in this file rather than in a second input's
      # hardcoded copy of it.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      #
      # `&&` short-circuits in Nix, so on darwin `nativeLibs pkgs` is never
      # forced. That is load-bearing for the systems policy above: it is what
      # lets a repo list Linux-only attrs in nativeLibs and still evaluate on
      # aarch64-darwin. Do not reorder the two operands.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $SRC_ROOT and $REPO_ROOT. `nix run` and `nix develop`
      # both start in whatever directory they were invoked from, and no verb may
      # act on that directory -- these two are what it acts on instead.
      #
      # $SRC_ROOT is this flake's own source, snapshotted into the store when
      # the flake was evaluated. It is the one anchor that is always available:
      # `nix run /path/to/repo#lint` tells the running program nothing whatever
      # about /path/to/repo (flake refs are location-independent by design, and
      # there is no $FLAKE_DIR to read), so without `self` a wrapper invoked
      # that way has literally no way to name the repo it belongs to. Two
      # limitations worth knowing: it is read-only, being a store path, and in a
      # git checkout it contains only TRACKED files.
      #
      # $REPO_ROOT is the writable checkout when the caller is standing in one,
      # and $SRC_ROOT when they are not. Three things this deliberately is NOT:
      #
      #   * NOT `pwd`. A fallback to the caller's directory is how `fmt`
      #     rewrites a stranger's source tree and how `lint` prints "all checks
      #     passed" having read none of this repo.
      #   * NOT `git rev-parse --show-toplevel`. Run from inside some OTHER git
      #     repo it cheerfully answers with THAT repo's top level. It also needs
      #     git on PATH and a .git directory, so it fails on an export and in
      #     any wrapper whose toolchain omits git.
      #   * NOT an inherited $REPO_ROOT from the environment. The dev shell
      #     EXPORTS this variable, so honouring it would mean that running
      #     `nix run /path/to/B#fmt` from inside repo A's dev shell points B's
      #     formatter at A. An explicit path argument is how a caller overrides
      #     a verb's target; an ambient variable is how they do it by accident.
      #
      # Instead: walk up from $PWD and take the first ancestor that IS this
      # repo, proved by carrying a byte-identical flake.nix. A single tracked
      # filename, a marker directory, or a set of them is not proof -- sibling
      # repos in a fleet share those, and a decoy can be built to carry any list
      # of names you care to publish. The whole flake.nix is what distinguishes
      # repos, because description, toolchain and command map all differ, so the
      # whole flake.nix is what gets compared. Compared with bash's own
      # `$(<file)` rather than cmp or sha256sum, so the check depends on no
      # package at all -- pure builtins, correct even in a wrapper whose PATH
      # carries nothing but the repo's own toolchain.
      #
      # Consequence worth knowing: edit flake.nix and the dev-* wrappers in an
      # already-open `nix develop` stop recognising the tree, because they were
      # built from the previous flake.nix. That is a stale shell telling you so
      # -- re-enter it. `nix run` re-evaluates every time and never sees this.
      rootPreamble = ''
        SRC_ROOT=${lib.escapeShellArg "${self}"}
        export SRC_ROOT

        _dev_find_root() {
          local dir ref
          ref=$(<"$SRC_ROOT/flake.nix") || return 1
          dir=$(
            unset CDPATH
            cd -P -- "''${1:-.}" 2>/dev/null && pwd
          ) || return 1
          while [ -n "$dir" ]; do
            if [ -f "$dir/flake.nix" ] && [ "$(<"$dir/flake.nix")" = "$ref" ]; then
              printf '%s\n' "$dir"
              return 0
            fi
            dir=''${dir%/*}
          done
          return 1
        }

        REPO_ROOT="$(_dev_find_root "$PWD" || printf '%s\n' "$SRC_ROOT")"
        export REPO_ROOT
      '';

      # Wrappers only, not the shellHook -- an interactive shell has no business
      # carrying this function around. Any command text that writes files calls
      # it first, and it is the reason a mutating verb can fail loudly instead
      # of falling back to "well, the cwd then".
      #
      # The test is $REPO_ROOT != $SRC_ROOT, i.e. "rootPreamble found a real
      # checkout", not a permission or a store-path-prefix test. Both of those
      # answer a narrower question: a checkout may be read-only for unrelated
      # reasons, and a store path is not the only tree we must refuse to write.
      guardPreamble = ''
        need_writable_checkout() {
          if [ "$REPO_ROOT" != "$SRC_ROOT" ]; then
            return 0
          fi
          echo "''${0##*/}: this command rewrites files, so it needs a writable" >&2
          echo "checkout of this repo -- and standing in $PWD there is none: no" >&2
          echo "parent directory carries this flake's flake.nix. The only tree in" >&2
          echo "reach is the read-only store snapshot $SRC_ROOT, and rewriting" >&2
          echo "$PWD instead is exactly the bug this guard exists to prevent." >&2
          echo "cd into the repo (or \`nix develop\` it), or pass an explicit path." >&2
          exit 1
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      #
      # writeShellApplication, not writeShellScriptBin: it runs shellcheck at
      # BUILD time and sets `set -euo pipefail`, so an unquoted $@ or a silently
      # ignored failure is a `nix flake check` failure rather than a surprise in
      # front of an agent.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${guardPreamble}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      # `dev-help` is generated from the same attrset as everything else, so it
      # cannot describe a verb that does not exist or miss one that does. No
      # runtimeInputs: printing the map must work with nothing installed.
      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };

      # The regression gate for rootPreamble and guardPreamble, which are the
      # two pieces of this flake that can silently damage a tree that is not
      # this repo. It tests the MECHANISM, not any verb, which is precisely what
      # makes it fleet-generic: it needs to know nothing about what this repo
      # does, only that the anchor resolves and the guard refuses.
      #
      # The decoy is a real directory carrying a real flake.nix that differs.
      # Marker-file anchors pass a decoy like this -- that is the whole point of
      # the probe -- and so does any anchor that trusts `pwd`. Probe 2 is the
      # other half, and without it a guard that refused everything would score a
      # perfect pass: a tree that IS byte-identical must still be adopted, or
      # every mutating verb in the repo is dead. Probe 3 pins the subdirectory
      # case, which is the normal one for an agent working inside a repo.
      #
      # A per-repo probe that drives the actual verbs is strictly better and
      # cannot live here -- it has to know which verb writes and which needs a
      # network. INTERFACE.md shows how to add one via `extraChecks`.
      anchorCheck =
        pkgs:
        pkgs.runCommand "anchor-check" { } ''
          set -euo pipefail

          # The two preambles under test, verbatim, in a file the probes source.
          # A quoted heredoc, so every $ below is the bash the wrappers see.
          cat > preamble.sh <<'CANONICAL_PREAMBLE_EOF'
          ${rootPreamble}
          ${guardPreamble}
          CANONICAL_PREAMBLE_EOF

          mkdir decoy
          printf '{\n  description = "a different repo";\n  outputs = _: { };\n}\n' > decoy/flake.nix
          printf 'do not touch me\n' > decoy/victim.txt
          cp -r decoy decoy.orig

          # ---- probe 1: a foreign tree must not be adopted ----
          if ! ( cd decoy && . ../preamble.sh && [ "$REPO_ROOT" = "$SRC_ROOT" ] ); then
            echo "anchor adopted a directory that is not this repo" >&2
            exit 1
          fi
          # In a subshell: need_writable_checkout ends in `exit`, which would
          # otherwise take this whole build down instead of failing a condition.
          if ( cd decoy && . ../preamble.sh && need_writable_checkout ) > guard.log 2>&1; then
            echo "need_writable_checkout accepted a tree that is not this repo" >&2
            exit 1
          fi
          if ! diff -r decoy decoy.orig; then
            echo "the probes modified the foreign tree" >&2
            exit 1
          fi

          # ---- probe 2: a byte-identical checkout must be adopted ----
          cp -r ${lib.escapeShellArg "${self}"} checkout
          chmod -R u+w checkout
          if ! ( cd checkout && . ../preamble.sh &&
                 [ "$REPO_ROOT" = "$(pwd -P)" ] && need_writable_checkout ); then
            echo "anchor refused a byte-identical checkout of this repo" >&2
            exit 1
          fi

          # ---- probe 3: from a subdirectory, still the checkout root ----
          mkdir -p checkout/probe3/deeper
          if ! ( cd checkout/probe3/deeper && . ../../../preamble.sh &&
                 [ "$REPO_ROOT" = "$(cd -P ../.. && pwd)" ] ); then
            echo "anchor did not walk up to the checkout root from a subdirectory" >&2
            exit 1
          fi

          touch "$out"
        '';
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Natively-compiled extension modules are routinely built at -O0,
          # where glibc's _FORTIFY_SOURCE stops being a warning and becomes a
          # hard error.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # $REPO_ROOT and $SRC_ROOT are exported here as a convenience for
            # the human at the prompt. Every wrapper re-resolves them from
            # scratch and none of them reads these, on purpose: a stale value
            # exported by one repo's shell must never steer another repo's verb.
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No environment
            # bootstrapping, no dependency installation, no `read`, no
            # `exec $SHELL`. Bootstrapping in the hook makes a cold
            # `nix develop -c <anything>` start downloading before it runs
            # anything, on EVERY invocation -- the exact failure an unattended
            # agent cannot diagnose. That is what a `setup` verb is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "${repoName} dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction, and the only gate this
      # style has. `toolchain` realises the whole toolchain closure (so a typo'd
      # or currently-broken attr fails here, not halfway through a task) and
      # builds every wrapper, which runs shellcheck over every command text.
      # `anchoring` is the regression test described above.
      #
      # Repo-specific checks go in `extraChecks`, never here. They may not
      # shadow either canonical name: silently replacing `anchoring` with
      # something weaker is the exact failure this whole file exists to make
      # impossible, so a collision is an eval error with both names in it.
      #
      # NEVER add a check that always passes. An agent reads "all checks
      # passed!" as a signal, and a fake check makes `nix flake check` a liar.
      checks = forAllSystems (
        pkgs:
        let
          canonical = {
            toolchain =
              pkgs.runCommand "toolchain-check"
                {
                  nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];
                }
                ''
                  set -euo pipefail
                  dev-help > help.txt

                  # A while-read over a heredoc rather than `for x in <list>`,
                  # which is a bash syntax error when the list is empty -- and a
                  # repo with no verbs yet is a legitimate state.
                  while IFS= read -r verb; do
                    [ -n "$verb" ] || continue
                    command -v "dev-$verb" > /dev/null || {
                      echo "dev-$verb is not on PATH" >&2
                      exit 1
                    }
                    grep -q -- "dev-$verb" help.txt || {
                      echo "dev-$verb is missing from the dev-help map" >&2
                      exit 1
                    }
                  done <<'CANONICAL_VERBS_EOF'
                  ${lib.concatStringsSep "\n" (lib.attrNames (commands pkgs))}
                  CANONICAL_VERBS_EOF

                  touch "$out"
                '';
            anchoring = anchorCheck pkgs;
          };
          extra = extraChecks pkgs;
          clash = lib.intersectLists (lib.attrNames canonical) (lib.attrNames extra);
        in
        if clash != [ ] then
          throw "extraChecks must not redefine canonical checks: ${lib.concatStringsSep ", " clash}"
        else
          canonical // extra
      );

      # `nix fmt` -- formats the *Nix* in this repo; project code gets a `fmt`
      # verb. nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because
      # bare nixfmt tries to parse every path handed to it and fails on non-Nix
      # files. This file ships already formatted, so `nix fmt` is a no-op rather
      # than a diff across the fleet.
      #
      # This is the one verb here NOT anchored to $REPO_ROOT, and it cannot be:
      # `nix fmt` is nix's own verb, and nix -- not this flake -- decides which
      # paths the formatter receives, passing the cwd when the user names none.
      # A wrapper that overrode them would break `nix fmt path/to/one/file.nix`,
      # and it cannot tell that "." apart from the default. So `nix fmt` formats
      # where you stand, by design; the `fmt` verb is the anchored one.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
# >>>>> END CANONICAL MACHINERY v1 <<<<<
