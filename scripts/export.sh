#!/usr/bin/env bash
# Exports issues, labels, comments, PRs, and PR branches from a GitHub repo.
# Outputs seed-data.json and branches.bundle, then uploads both to scripts/ in the repo.
# Usage: ./export.sh [OWNER/REPO]
# Defaults to hynes-hq/taskflow-api

set -euo pipefail

REPO="${1:-hynes-hq/taskflow-api}"
OUT_JSON="seed-data.json"
OUT_BUNDLE="branches.bundle"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

command -v gh >/dev/null 2>&1      || { echo "Error: gh CLI not installed. https://cli.github.com"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not found"; exit 1; }
command -v git >/dev/null 2>&1     || { echo "Error: git not found"; exit 1; }
gh auth status >/dev/null 2>&1     || { echo "Error: not authenticated. Run: gh auth login"; exit 1; }

echo "Exporting $REPO → $OUT_JSON + $OUT_BUNDLE"

# --- Fetch metadata ---
gh api "repos/$REPO/labels?per_page=100"           > /tmp/_labels.json
gh api "repos/$REPO/issues?state=all&per_page=100" > /tmp/_issues.json
gh api "repos/$REPO/pulls?state=all&per_page=100"  > /tmp/_pulls.json

# --- Build JSON (issues + comments + PRs) ---
echo "  Building seed-data.json..."
python3 - "$REPO" <<'PYEOF'
import sys, json, subprocess

repo   = sys.argv[1]
issues = json.load(open("/tmp/_issues.json"))
pulls  = json.load(open("/tmp/_pulls.json"))
labels = json.load(open("/tmp/_labels.json"))

# Comments for non-PR issues
pr_issue_numbers = {p["number"] for p in pulls}
comments = {}
for issue in issues:
    if "pull_request" in issue or issue["number"] in pr_issue_numbers:
        continue
    num = str(issue["number"])
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/issues/{num}/comments?per_page=100"],
        capture_output=True, text=True, check=True
    )
    raw = json.loads(result.stdout)
    if raw:
        comments[num] = [{"body": c["body"]} for c in raw]

# Comments on PRs (review comments live on the issue thread)
pr_comments = {}
for pr in pulls:
    num = str(pr["number"])
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/issues/{num}/comments?per_page=100"],
        capture_output=True, text=True, check=True
    )
    raw = json.loads(result.stdout)
    if raw:
        pr_comments[num] = [{"body": c["body"]} for c in raw]

labels_out = [
    {"name": l["name"], "color": l["color"], "description": l.get("description") or ""}
    for l in labels
]

issues_out = [
    {
        "number": i["number"],
        "title":  i["title"],
        "body":   i.get("body") or "",
        "state":  i["state"],
        "labels": [l["name"] for l in i["labels"]],
        "is_pr":  "pull_request" in i,
    }
    for i in issues
]

prs_out = [
    {
        "number":   p["number"],
        "title":    p["title"],
        "body":     p.get("body") or "",
        "state":    p["state"],
        "head_ref": p["head"]["ref"],
        "base_ref": p["base"]["ref"],
        "labels":   [l["name"] for l in p["labels"]],
        "draft":    p.get("draft", False),
    }
    for p in pulls
]

out = {
    "labels":      labels_out,
    "issues":      issues_out,
    "comments":    comments,
    "prs":         prs_out,
    "pr_comments": pr_comments,
}
json.dump(out, open("/tmp/_seed.json", "w"), indent=2)
print(f"  {len(labels_out)} labels, {len([i for i in issues_out if not i['is_pr']])} issues, "
      f"{len(prs_out)} PRs, "
      f"{sum(len(v) for v in comments.values())} issue comments, "
      f"{sum(len(v) for v in pr_comments.values())} PR comments")
PYEOF

mv /tmp/_seed.json "$OUT_JSON"
rm -f /tmp/_labels.json /tmp/_issues.json /tmp/_pulls.json

# --- Bundle PR branches ---
echo "  Cloning repo to build branch bundle..."
PR_BRANCHES=$(python3 -c "
import json
data = json.load(open('$OUT_JSON'))
branches = {p['head_ref'] for p in data['prs']} | {p['base_ref'] for p in data['prs']}
print(' '.join(branches))
")

if [[ -n "$PR_BRANCHES" ]]; then
  git clone --quiet "https://github.com/$REPO.git" "$WORK_DIR/repo"
  cd "$WORK_DIR/repo"

  # Fetch all PR branches explicitly
  for branch in $PR_BRANCHES; do
    git fetch --quiet origin "$branch":"$branch" 2>/dev/null || true
  done

  # Create bundle containing all PR-related refs
  BUNDLE_REFS=""
  for branch in $PR_BRANCHES; do
    if git rev-parse --verify "$branch" >/dev/null 2>&1; then
      BUNDLE_REFS="$BUNDLE_REFS $branch"
    fi
  done

  git bundle create "$OLDPWD/$OUT_BUNDLE" $BUNDLE_REFS
  cd "$OLDPWD"
  echo "  Bundled branches:$BUNDLE_REFS"
else
  echo "  No PR branches to bundle."
  # Create an empty placeholder so seed.sh can detect the case
  touch "$OUT_BUNDLE"
fi

echo "Done → $OUT_JSON, $OUT_BUNDLE"
