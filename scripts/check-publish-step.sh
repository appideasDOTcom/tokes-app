#!/bin/bash
# Exercise the "Publish to GitHub Release" step of .github/workflows/build.yml
# against a stub `gh`, without pushing anything. Extracts the step's `run`
# block with ruby -ryaml (this Mac has no actionlint or PyYAML), substitutes
# the one expression it uses, and runs it in a scratch directory for every
# case the step has to survive:
#
#   tag-new        release absent -> create + upload + edit
#   tag-exists     hand-made release (the v1.4.2 case) -> reuse, upload, edit
#   tag-race       view fails, create loses to a concurrent run, fallback view
#   branch-new     build-<run> pre-release on main / workflow_dispatch
#   branch-exists  re-run of the same run number
#   no-zip         build/ has no zip -> must exit non-zero before any gh call
#
# Each publishing case must end with exactly one `gh release edit` whose notes
# carry the sha256 of the zip that was uploaded (QA finding, PR #2: the reuse
# path used to replace the asset and leave the notes stale, so the cask step in
# RELEASING.md read a missing digest). Exit status is non-zero on any failure.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW="$REPO/.github/workflows/build.yml"
S=$(mktemp -d "${TMPDIR:-/tmp}/tokes-publish-check.XXXXXX")
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/work/build"

ruby -ryaml -e '
  d = YAML.load_file(ARGV[0])
  step = d["jobs"]["build"]["steps"].find { |x| x["name"] == "Publish to GitHub Release" } or abort "publish step not found"
  File.write(ARGV[1], step["run"].gsub("${{ github.run_number }}", "42"))
' "$WORKFLOW" "$S/publish.sh"

cat > "$S/bin/gh" <<'STUB'
#!/bin/bash
# Records every call to $STUB_LOG; behaviour per $STUB_MODE (new|exists|race).
echo "gh $*" >> "$STUB_LOG"
case "$1 $2" in
  "release view")
    case "$STUB_MODE" in
      new) exit 1 ;;
      exists) [[ "$*" == *--json* ]] && echo "https://example.invalid/release"; exit 0 ;;
      race) # first view: absent; create then "loses"; every later view succeeds
        n=$(grep -c '^gh release view' "$STUB_LOG")
        if [[ $n -ge 2 ]]; then [[ "$*" == *--json* ]] && echo "https://example.invalid/release"; exit 0; fi
        exit 1 ;;
    esac ;;
  "release create") [[ "$STUB_MODE" == race ]] && { echo "release already exists" >&2; exit 1; }; exit 0 ;;
  "release upload"|"release edit") exit 0 ;;
esac
exit 0
STUB
chmod +x "$S/bin/gh"

fail=0
run_case() { # label mode ref ref_name expect_tag with_zip
  local label=$1 mode=$2 ref=$3 name=$4 tag=$5 with_zip=$6
  export STUB_MODE=$mode STUB_LOG="$S/log-$label"
  : > "$STUB_LOG"
  rm -f "$S"/work/build/*.zip
  local sha=""
  if [[ $with_zip == yes ]]; then
    printf 'zip %s\n' "$label" > "$S/work/build/Tokes-0.0.0.zip"
    sha=$(shasum -a 256 "$S/work/build/Tokes-0.0.0.zip" | awk '{print $1}')
  fi
  local rc=0
  (cd "$S/work" && PATH="$S/bin:$PATH" GITHUB_REF=$ref GITHUB_REF_NAME=$name \
     GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GH_TOKEN=stub \
     bash -e "$S/publish.sh" >/dev/null 2>&1) || rc=$?
  local uploads edits
  uploads=$(grep -c '^gh release upload' "$STUB_LOG" || true)
  edits=$(grep -c "^gh release edit $tag .*$sha" "$STUB_LOG" || true)
  if [[ $with_zip == yes ]]; then
    if [[ $rc -eq 0 && $uploads -eq 1 && $edits -eq 1 ]]; then
      echo "ok    $label"
    else
      echo "FAIL  $label (rc=$rc uploads=$uploads edits-with-sha=$edits)"; cat "$STUB_LOG"; fail=1
    fi
  else
    if [[ $rc -ne 0 && ! -s "$STUB_LOG" ]]; then
      echo "ok    $label (exit $rc, no gh calls)"
    else
      echo "FAIL  $label (rc=$rc, gh calls: $(wc -l < "$STUB_LOG"))"; fail=1
    fi
  fi
}

run_case tag-new       new    refs/tags/v0.0.0 v0.0.0 v0.0.0   yes
run_case tag-exists    exists refs/tags/v0.0.0 v0.0.0 v0.0.0   yes
run_case tag-race      race   refs/tags/v0.0.0 v0.0.0 v0.0.0   yes
run_case branch-new    new    refs/heads/main  main   build-42 yes
run_case branch-exists exists refs/heads/main  main   build-42 yes
run_case no-zip        new    refs/tags/v0.0.0 v0.0.0 v0.0.0   no
exit $fail
