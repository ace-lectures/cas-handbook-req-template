#!/usr/bin/env bash
#
# Bootstrap the milestones, labels and section-tracking issues for a student
# copy of the requirements handbook template.
#
# Idempotent: re-running only creates what is missing, so it is safe to run
# again after the deadlines change or a section is added.
#
# Requires: gh (authenticated via GITHUB_TOKEN), jq.
# Expects:  REPO, M1_DUE, M2_DUE, FINAL_DUE in the environment.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COURSE="${HERE}/../course"

: "${REPO:?REPO must be set (owner/name)}"
: "${M1_DUE:?M1_DUE must be set}"
: "${M2_DUE:?M2_DUE must be set}"
: "${FINAL_DUE:?FINAL_DUE must be set}"

# ---------------------------------------------------------------- milestones

# ensure_milestone <title> <description> <due_on>; echoes the milestone number.
# Looks at state=all: a closed milestone must not be recreated.
ensure_milestone () {
  local title="$1" descr="$2" due="$3" number
  number=$(gh api --paginate "repos/${REPO}/milestones?state=all&per_page=100" \
             --jq "[.[] | select(.title == \"${title}\") | .number] | first // empty")
  if [[ -n "$number" ]]; then
    echo "Milestone '${title}' already exists (#${number})" >&2
  else
    number=$(gh api "repos/${REPO}/milestones" \
               -f title="$title" -f state="open" \
               -f description="$descr" -f due_on="$due" --jq '.number')
    echo "Created milestone '${title}' (#${number}) due ${due}" >&2
  fi
  printf '%s' "$number"
}

# Plain variables rather than an associative array, so this stays runnable on
# the bash 3.2 that ships with macOS as well as on the Actions runner.
MILESTONE_1=$(ensure_milestone "Milestone 1" \
  "First Window of Opportunity for feedback"     "$M1_DUE")
MILESTONE_2=$(ensure_milestone "Milestone 2" \
  "Second Window of Opportunity for feedback"    "$M2_DUE")
MILESTONE_3=$(ensure_milestone "Milestone 3 - Final" \
  "Complete document due, delivered for grading" "$FINAL_DUE")

milestone_number () {
  case "$1" in
    1) printf '%s' "$MILESTONE_1" ;;
    2) printf '%s' "$MILESTONE_2" ;;
    3) printf '%s' "$MILESTONE_3" ;;
    *) echo "::error::unknown milestone '$1' in sections.json" >&2; exit 1 ;;
  esac
}

for n in 1 2 3; do
  [ -n "$(milestone_number "$n")" ] || {
    echo "::error::could not resolve milestone $n" >&2; exit 1; }
done

# -------------------------------------------------------------------- labels

while read -r name color descr; do
  if gh api --paginate "repos/${REPO}/labels?per_page=100" \
       --jq '.[].name' | grep -qxF "$name"; then
    echo "Label '${name}' already exists" >&2
  else
    gh api "repos/${REPO}/labels" \
      -f name="$name" -f color="$color" -f description="$descr" >/dev/null
    echo "Created label '${name}'" >&2
  fi
done < <(jq -r '.[] | [.name, .color, .description] | @tsv' "${COURSE}/labels.json")

# -------------------------------------------------------------------- issues

# One sweep for every existing title, open *and* closed, across all pages,
# excluding pull requests (the issues endpoint returns those too).
existing_titles=$(gh api --paginate "repos/${REPO}/issues?state=all&per_page=100" \
                    --jq '.[] | select(.pull_request | not) | .title')

created=0 skipped=0
while read -r section; do
  title=$(jq -r '.title'     <<<"$section")
  body=$(jq  -r '.body'      <<<"$section")
  ms=$(jq    -r '.milestone' <<<"$section")

  if grep -qxF "$title" <<<"$existing_titles"; then
    echo "Issue '${title}' already exists" >&2
    skipped=$(( skipped + 1 ))
    continue
  fi

  # shellcheck disable=SC2046  # deliberate word splitting: one -F per label
  number=$(gh api "repos/${REPO}/issues" \
             -f title="$title" \
             -f body="$body" \
             -F milestone="$(milestone_number "$ms")" \
             $(jq -r '.labels[] | "-Flabels[]=" + .' <<<"$section") \
             --jq '.number')
  echo "Created issue #${number}: ${title}" >&2
  created=$(( created + 1 ))
done < <(jq -c '.[]' "${COURSE}/sections.json")

echo "Done: ${created} issue(s) created, ${skipped} already present." >&2
