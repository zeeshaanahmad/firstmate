#!/usr/bin/env bash
# tests/static-guard-helpers.sh - the throwaway project fixture both static-guard
# suites drive (tests/fm-static-guard.test.sh, tests/fm-main-guard.test.sh).
#
# It builds a repository whose OWN pinned checker is a committed script: every
# USE_* name any .py file mentions must be defined in lib.py. Nothing here
# depends on ruff, uv, or any real managed project being present, and the shape
# is the measured defect - the default branch renames a symbol the PR still
# uses, so each side is green alone and only the combination is red.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_sg_git() {  # <repo> <git args...>
  git -C "$1" -c user.name=fmtest -c user.email=fmtest@example.invalid "${@:2}"
}

fm_sg_write_checker() {  # <dir>
  cat > "$1/check.sh" <<'SH'
#!/usr/bin/env bash
rc=0
for n in $(grep -hoE 'USE_[A-Z_]+' ./*.py 2>/dev/null | sort -u); do
  grep -qE "^$n = " lib.py 2>/dev/null || { echo "undefined name: $n"; rc=1; }
done
exit "$rc"
SH
  chmod +x "$1/check.sh"
}

# fm_sg_make_project <case_dir> [plain|nocheck|prconfig|makefile]
# Builds <case_dir>/origin.git (with HEAD on main and refs/pull/7/head) and
# <case_dir>/work, and records the base commit in <case_dir>/base.sha.
fm_sg_make_project() {
  local case_dir=$1 variant=${2:-plain} work="$1/work" origin="$1/origin.git"
  mkdir -p "$case_dir"
  git init -q --bare "$origin"
  git clone -q "$origin" "$work" 2>/dev/null
  printf 'USE_OLD = 1\n' > "$work/lib.py"
  fm_sg_write_checker "$work"
  case "$variant" in
    nocheck) ;;
    makefile)
      # Second discovery source: a Makefile lint: rule and no .no-mistakes.yaml.
      printf 'lint:\n\t@./check.sh\n' > "$work/Makefile"
      ;;
    *) printf 'commands:\n  lint: ./check.sh\n' > "$work/.no-mistakes.yaml" ;;
  esac
  fm_sg_git "$work" add -A
  fm_sg_git "$work" commit -qm base
  fm_sg_git "$work" branch -M main
  fm_sg_git "$work" rev-parse main > "$case_dir/base.sha"
  fm_sg_git "$work" push -q origin main
  git -C "$origin" symbolic-ref HEAD refs/heads/main

  fm_sg_git "$work" checkout -qb feat
  printf 'print(USE_OLD)\n' > "$work/use.py"
  if [ "$variant" = prconfig ]; then
    # The PR tries to point the guard at a check that always passes.
    printf 'commands:\n  lint: true\n' > "$work/.no-mistakes.yaml"
  fi
  fm_sg_git "$work" add -A
  fm_sg_git "$work" commit -qm feat
  fm_sg_git "$work" push -q origin feat
  git -C "$origin" update-ref refs/pull/7/head "$(fm_sg_git "$work" rev-parse feat)"
  fm_sg_git "$work" checkout -q main
}

# The default branch renames the symbol the PR still uses: each side green, the
# combination red. Also makes the default branch itself red for a tree that
# already contains use.py.
fm_sg_advance_main_rename() {  # <case_dir>
  local work=$1/work
  printf 'USE_NEW = 1\n' > "$work/lib.py"
  fm_sg_git "$work" add -A
  fm_sg_git "$work" commit -qm rename
  fm_sg_git "$work" push -q origin main
}

# The default branch moves in a way nothing else interacts with.
fm_sg_advance_main_harmless() {  # <case_dir>
  local work=$1/work
  printf '# unrelated %s\n' "$RANDOM" > "$work/notes.txt"
  fm_sg_git "$work" add -A
  fm_sg_git "$work" commit -qm notes
  fm_sg_git "$work" push -q origin main
}

# Land a use of USE_OLD directly on the default branch, so the default branch
# tip itself fails the project's own checker.
fm_sg_break_main() {  # <case_dir>
  local work=$1/work
  printf 'print(USE_OLD)\n' > "$work/use.py"
  printf 'USE_NEW = 1\n' > "$work/lib.py"
  fm_sg_git "$work" add -A
  fm_sg_git "$work" commit -qm 'break main'
  fm_sg_git "$work" push -q origin main
}

# Repair the default branch so its tip passes again.
fm_sg_repair_main() {  # <case_dir>
  local work=$1/work
  printf 'USE_OLD = 1\nUSE_NEW = 1\n' > "$work/lib.py"
  fm_sg_git "$work" add -A
  fm_sg_git "$work" commit -qm 'repair main'
  fm_sg_git "$work" push -q origin main
}

# A PR that edits the same line the default branch edits, so the squash result
# cannot be computed at all.
fm_sg_make_conflicting_pr() {  # <case_dir>
  local case_dir=$1 work="$1/work"
  fm_sg_git "$work" checkout -q -B conflict "$(cat "$case_dir/base.sha")"
  printf 'USE_OLD = 2\n' > "$work/lib.py"
  fm_sg_git "$work" add -A
  fm_sg_git "$work" commit -qm conflict
  fm_sg_git "$work" push -q origin conflict
  git -C "$case_dir/origin.git" update-ref refs/pull/7/head "$(fm_sg_git "$work" rev-parse conflict)"
  fm_sg_git "$work" checkout -q main
}
