#!/usr/bin/env bash
# Exports issues, labels, and comments from a GitHub repo to seed-data.json
# Usage: ./export.sh [OWNER/REPO]
# Defaults to hynes-hq/taskflow-api

set -euo pipefail

REPO="${1:-hynes-hq/taskflow-api}"
OUT="seed-data.json"

command -v gh >/dev/null 2>&1   || { echo "Error: gh CLI not installed. https://cli.github.com"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not found"; exit 1; }
gh auth status >/dev/null 2>&1  || { echo "Error: not authenticated. Run: gh auth login"; exit 1; }

echo "Exporting $REPO → $OUT"

gh api "repos/$REPO/labels?per_page=100"           > /tmp/_labels.json
gh api "repos/$REPO/issues?state=all&per_page=100" > /tmp/_issues.json

echo "  Fetching per-issue comments..."
python3 - "$REPO" <<'PYEOF'
import sys, json, subprocess

repo   = sys.argv[1]
issues = json.load(open("/tmp/_issues.json"))

comments = {}
for issue in issues:
    if "pull_request" in issue:
        continue
    num = str(issue["number"])
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/issues/{num}/comments?per_page=100"],
        capture_output=True, text=True, check=True
    )
    raw = json.loads(result.stdout)
    if raw:
        comments[num] = [{"body": c["body"]} for c in raw]

labels = [
    {"name": l["name"], "color": l["color"], "description": l.get("description") or ""}
    for l in json.load(open("/tmp/_labels.json"))
]

issues_out = [
    {
        "number":  i["number"],
        "title":   i["title"],
        "body":    i.get("body") or "",
        "state":   i["state"],
        "labels":  [l["name"] for l in i["labels"]],
        "is_pr":   "pull_request" in i,
    }
    for i in issues
]

out = {"labels": labels, "issues": issues_out, "comments": comments}
json.dump(out, open("/tmp/_seed.json", "w"), indent=2)
print(f"  {len(labels)} labels, {len(issues_out)} issues, "
      f"{sum(len(v) for v in comments.values())} comments")
PYEOF

mv /tmp/_seed.json "$OUT"
rm -f /tmp/_labels.json /tmp/_issues.json
echo "Done → $OUT"
