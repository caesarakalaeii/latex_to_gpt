{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "latex_to_gpt -- Python script that rewrites LaTeX thesis chapters via the OpenAI chat API. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the other forty, and a
  # hardcoded system list this repo cannot edit. That list is currently broken:
  # it still contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'self'".
    #
    # `self` is not decoration: it is the only way a wrapper in the store can
    # name this repo's own files, which is what anchors every verb (see
    # rootPreamble). It does mean the wrappers rebuild whenever a tracked file
    # changes -- four shellcheck runs, about a second, and worth it.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # `nix flake check` realises this closure, so a typo'd attr name fails at
      # the flake gate instead of surfacing as "command not found" halfway
      # through a task.
      #
      # No texlive here, and that is a deliberate finding rather than an
      # oversight: despite the repo name, nothing in this tree compiles LaTeX.
      # text_smoother.py reads a plain text file (RAW_FILE_LOCATION =
      # 'latex.txt'), splits it on \section / \subsection, ships the parts to the
      # OpenAI chat API and writes the answer back out. There is no
      # \documentclass, no .tex file, no latexmk or pdflatex invocation and no
      # subprocess call anywhere in the repo. A scoped texliveSmall would add
      # ~626 MB to every cold agent's download to compile nothing. If a future
      # change actually typesets a document, add
      # `(pkgs.texliveSmall.withPackages (ps: [ ps.latexmk ]))` plus a `build`
      # verb running `latexmk -pdf -interaction=nonstopmode` -- the
      # -interaction flag is mandatory, LaTeX otherwise drops to an interactive
      # `?` prompt and hangs until the agent's timeout.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      toolchain = pkgs: [
        # ---- this repo's ecosystem ----
        # Pinned by MAJOR, never `pkgs.python3`: the rolling alias is already in
        # 3.14 territory, and an alias that moves under you invalidates .venv on
        # the same afternoon.
        pkgs.python313
        pkgs.uv
        pkgs.ruff

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
        pkgs.gnumake
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # `dev-setup` installs manylinux wheels, and those carry .so files that are
      # dlopened at runtime -- neither patchelf nor the nix linker ever sees
      # them, and NixOS has no /usr/lib for them to find. stdenv.cc.cc.lib
      # supplies libstdc++, the one that breaks such imports.
      #
      # Measured, so the next agent does not have to guess: this repo's CURRENT
      # closure does not need it. openai 0.28.1 pulls aiohttp, whose extensions
      # link libc only, and `import openai, aiohttp` succeeds with
      # LD_LIBRARY_PATH cleared. It is kept as insurance for the venv, because it
      # goes load-bearing the moment anyone adds a normal compiled wheel -- an
      # `uv pip install numpy` in this same venv imports fine here and fails with
      # `libstdc++.so.6: cannot open shared object file` with the variable
      # cleared. Prepending costs nothing when unused, so do not "clean this up"
      # by emptying it; do keep it minimal, LD_LIBRARY_PATH is a blunt
      # instrument.
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
        pkgs.zlib
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only constants belong here. Anything that must READ an existing value
      # (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or touch the work
      # tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # Keep uv on the nix interpreter. Left alone it downloads its own
        # portable CPython, which then resolves a different set of wheels than
        # this shell pins: two Pythons, one venv, no way to tell which is live.
        UV_PYTHON = "${pkgs.python313}/bin/python";
        UV_PYTHON_DOWNLOADS = "never";
        # /nix/store and the work tree are usually different filesystems, so
        # uv's default hardlink strategy warns on every single install.
        UV_LINK_MODE = "copy";
        PIP_DISABLE_PIP_VERSION_CHECK = "1";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#run`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-run` actually runs.
      #
      # `build` and `test` are absent on purpose. The repo is a single
      # top-level script -- no artifact is produced, and there is no test suite,
      # no pytest, no CI workflow and no test directory to point one at. A stub
      # that echoed "not applicable" would only turn this map into a liar;
      # absence is information, and `nix flake show` then reports the truth.
      #
      # `text` is bash under `set -euo pipefail` and shellcheck'd at BUILD time.
      # It gets $REPO_ROOT / $SRC_ROOT and `require_work_tree` from rootPreamble,
      # and it must use them: the caller's cwd is never this repo's location, and
      # a verb that defaults to it is either lying (lint) or destructive (fmt).
      commands = pkgs: {
        setup = {
          # There is no requirements.txt, no pyproject.toml and no lockfile in
          # this repo -- the README says `pip install openai` and nothing else --
          # so the dependency set is derived from the imports: openai, plus the
          # stdlib.
          #
          # The <1 bound is load-bearing, not caution. text_smoother.py uses the
          # pre-1.0 client surface (`openai.api_key = ...` and
          # `openai.ChatCompletion.create(...)`), both removed in openai 1.0.
          # Installing current openai gives an immediate
          # `APIRemovedInV1: openai.ChatCompletion is no longer supported`.
          # Drop the bound only together with porting the script to
          # `OpenAI().chat.completions.create`.
          #
          # This is also why the shell cannot be made offline via
          # `python313.withPackages`: nixpkgs ships openai 2.41.1, i.e. exactly
          # the major this code cannot run against.
          #
          # --allow-existing is not cosmetic: without it a second `dev-setup` --
          # the obvious move in any retry loop, and the only move after this
          # pin changes -- dies with "A virtual environment already exists at:
          # .venv" and exit 2, BEFORE the install line runs. So the bootstrap
          # verb failed on precisely the trees that had already been set up. Do
          # not reach for --clear instead: that deletes a working venv to
          # re-download what is already in it.
          description = "(network) create/update .venv with the openai client the script needs";
          # A .venv belongs to a checkout, and the store snapshot is read-only,
          # so there is nothing sensible to do without one -- least of all
          # unpacking a venv into whichever directory the caller stood in.
          text = ''
            require_work_tree
            uv venv --allow-existing "$REPO_ROOT/.venv"
            uv pip install --python "$REPO_ROOT/.venv/bin/python" 'openai<1'
          '';
        };
        run = {
          # Absolute interpreter path, not a bare `python`: the wrappers PREPEND
          # the nix toolchain to PATH, so a bare name resolves to the store copy
          # and misses everything `setup` installed into .venv.
          #
          # It cds to the root, and that is a fix rather than a preference.
          # text_smoother.py hardcodes RAW_FILE_LOCATION = 'latex.txt' and
          # open('smoothed_output', 'w'), both relative to the CURRENT directory,
          # so the earlier version -- which stayed in the caller's cwd on the
          # theory that this let an agent point it at a thesis living anywhere --
          # meant `nix run /path/to/this-repo#run` read a stranger's latex.txt
          # and wrote a file called smoothed_output next to it. The README's
          # contract is "place your LaTeX code file in the same directory as the
          # script", i.e. the root, which is now the only place it looks.
          #
          # Needs api_secrets.py (copy api_secrets_example.py and fill in the
          # key), a latex.txt in the root, and .venv from `setup`. All three are
          # gitignored, hence absent from the snapshot: another verb that cannot
          # work without a checkout.
          description = "smooth latex.txt into smoothed_output, both in the repo root (needs `setup`, api_secrets.py, network)";
          text = ''
            require_work_tree
            cd "$REPO_ROOT"
            "$REPO_ROOT/.venv/bin/python" "$REPO_ROOT/text_smoother.py" "$@"
          '';
        };
        lint = {
          description = "ruff check (the whole repo, from any directory)";
          # `cd` first, then a bare `.` default. Both halves are load-bearing:
          # `ruff check "$@"` alone checked the caller's cwd, and even
          # `ruff check "''${@:-$SOMEROOT}"` still checks the cwd the moment the
          # caller passes a flag rather than a path (`--fix`, `--select F401`),
          # because any argument suppresses the default. Standing in the root
          # closes both, and it makes a relative path argument mean the same thing
          # no matter where the command was invoked from.
          #
          # ruff's incremental cache lands in $PWD. In the snapshot branch that is
          # the read-only store, so it is switched off there -- two files do not
          # need a cache, and littering the caller's directory with .ruff_cache
          # was part of the same bug.
          text = ''
            if [ -n "$REPO_ROOT" ]; then
              cd "$REPO_ROOT"
              ruff check "''${@:-.}"
            else
              cd "$SRC_ROOT"
              ruff check --no-cache "''${@:-.}"
            fi
          '';
        };
        fmt = {
          description = "ruff format (rewrites files, so it needs the checkout)";
          # MUTATING, hence no $SRC_ROOT fallback: formatting the snapshot would
          # either fail on the read-only store or, worse, report "1 file
          # reformatted" for a change nobody can ever see. And no cwd default --
          # that is exactly how `nix run /path/to/this-repo#fmt` used to rewrite
          # Python that had nothing to do with this project.
          text = ''
            require_work_tree
            cd "$REPO_ROOT"
            ruff format "''${@:-.}"
          '';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical in all 41 repos, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets two anchors, and NEITHER of them is the caller's cwd.
      #
      #   $SRC_ROOT   this flake's own source tree as copied into the store when
      #               the wrapper was built: always present, always exactly this
      #               repo's content, always read-only. It is the only repo path
      #               `nix run /elsewhere/this-repo#lint` can be certain of -- the
      #               wrapper is a store path and has no idea where the checkout
      #               it came from lives. It sees git-tracked files only, so a
      #               brand new file is invisible until `git add`.
      #   $REPO_ROOT  the live checkout, or EMPTY when the caller is not standing
      #               in it. Preferred whenever it exists: it is writable and it
      #               sees edits the snapshot does not.
      #
      # The previous `git rev-parse --show-toplevel || pwd` was worse than no
      # anchor at all. From an unrelated directory it resolved to that directory,
      # so `nix run <url>#lint` -- the form CI and a cold agent use -- reported
      # "All checks passed!" having inspected zero of this repo's files, and
      # `nix run <url>#fmt` rewrote a stranger's source. `git rev-parse` on its
      # own is not enough either: run from inside some OTHER checkout it happily
      # reports that repo. So a candidate only counts as ours when every
      # top-level name in the snapshot also exists in it -- cheap, needs no tool
      # beyond the shell, and unlike comparing flake.nix it survives editing this
      # file.
      #
      # Read-only verbs then fall back to $SRC_ROOT and report the same thing from
      # any cwd. Verbs that write or keep state call `require_work_tree` and
      # refuse instead: the snapshot is read-only, and the caller's directory is
      # not ours to guess at.
      rootPreamble = ''
        SRC_ROOT=${self}
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$REPO_ROOT" ]; then
          for entry in "$SRC_ROOT"/*; do
            [ -e "$REPO_ROOT/''${entry##*/}" ] || { REPO_ROOT=""; break; }
          done
        fi
        export SRC_ROOT REPO_ROOT

        # Called by every verb that writes, before it writes anything.
        require_work_tree() {
          if [ -z "$REPO_ROOT" ]; then
            echo "''${0##*/}: this verb writes to the checkout, and the directory" >&2
            echo "  you called from is not one. Run it from inside the work tree," >&2
            echo "  or from a \`nix develop\` started there." >&2
            exit 1
          fi
        }
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
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
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

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

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No venv creation, no
            # `pip install`, no `read`, no `exec $SHELL`. Bootstrapping in the
            # hook makes a cold `nix develop -c python` start downloading before
            # it runs anything, on EVERY invocation -- the exact failure an
            # unattended agent cannot diagnose. That is what `dev-setup` is for.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "latex_to_gpt dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. Add real
      # test derivations beside it. NEVER add a check that always passes: an
      # agent reads "all checks passed!" as a signal, and a fake check makes
      # `nix flake check` a liar.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';

        # The build sandbox is an ideal stand-in for "some unrelated directory":
        # no git repo, no config, and no Python in it but what we plant here.
        #
        # This check exists because the flake shipped with exactly the opposite
        # behaviour. Every command ended in a bare "$@", so given no arguments
        # they acted on the CALLER's cwd: `nix run <url>#lint` -- the form CI and
        # a cold agent use -- printed "All checks passed!" having inspected none
        # of this repo, and `nix run <url>#fmt` rewrote source files outside the
        # repo entirely. Both are regressions a human reviewer will not notice,
        # so they get a machine.
        anchoring =
          pkgs.runCommand "anchoring-check"
            {
              nativeBuildInputs = lib.attrValues (wrappers pkgs);
            }
            ''
              decoy="$NIX_BUILD_TOP/decoy"
              logs="$NIX_BUILD_TOP/logs"
              mkdir -p "$decoy" "$logs"
              printf 'import os,sys\nx=1\n' > "$decoy/decoy.py"
              cp "$decoy/decoy.py" "$decoy/decoy.py.orig"
              cd "$decoy"

              # Read-only verbs must inspect this repo wherever they are called
              # from. Asserted through --show-files rather than through findings,
              # so this check does not start lying the day someone fixes the last
              # ruff warning.
              dev-lint --show-files > "$logs/files.log"
              grep -q '/text_smoother.py$' "$logs/files.log" || {
                echo "dev-lint did not look at the repo:" >&2
                cat "$logs/files.log" >&2
                exit 1
              }
              if grep -q decoy "$logs/files.log"; then
                echo "dev-lint reached into the caller's directory:" >&2
                cat "$logs/files.log" >&2
                exit 1
              fi

              # Verbs that write must refuse when there is no checkout, rather
              # than improvise one out of $PWD. setup and run would also need the
              # network, so this doubles as proof they exit before reaching it.
              for verb in fmt setup run; do
                if "dev-$verb" > "$logs/$verb.log" 2>&1; then
                  echo "dev-$verb should have refused outside a work tree:" >&2
                  cat "$logs/$verb.log" >&2
                  exit 1
                fi
              done

              # Nothing whatsoever may have appeared next to the caller: not a
              # reformatted file, not a .venv, not even a .ruff_cache.
              cmp "$decoy/decoy.py" "$decoy/decoy.py.orig"
              [ "$(find "$decoy" -mindepth 1 | wc -l)" -eq 2 ] || {
                echo "something was written into the caller's directory:" >&2
                find "$decoy" -mindepth 1 >&2
                exit 1
              }
              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff in 41 repos.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
