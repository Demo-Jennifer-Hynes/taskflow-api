#!/usr/bin/env bash
# Seeds a GitHub repo with issues, labels, comments, and pull requests from taskflow-api.
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hynes-hq/taskflow-api/main/scripts/seed.sh) OWNER/YOUR-REPO
#
# Prerequisites:
#   - gh CLI installed (https://cli.github.com) and authenticated (gh auth login)
#   - git installed
#   - Push access to YOUR-REPO

set -euo pipefail

TARGET="${1:-}"
SOURCE_REPO="hynes-hq/taskflow-api"
BASE_URL="https://raw.githubusercontent.com/hynes-hq/taskflow-api/main/scripts"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Checks ---
if [[ -z "$TARGET" ]]; then
  echo "Usage: seed.sh OWNER/YOUR-REPO"
  echo "Example: seed.sh myorg/my-taskflow-fork"
  exit 1
fi

command -v gh >/dev/null 2>&1      || { echo "Error: gh CLI not installed. See https://cli.github.com"; exit 1; }
command -v git >/dev/null 2>&1     || { echo "Error: git not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not found"; exit 1; }
gh auth status >/dev/null 2>&1     || { echo "Error: not authenticated. Run: gh auth login"; exit 1; }

echo "Seeding $TARGET from $SOURCE_REPO"
echo ""

# --- Fetch seed data ---
echo "Fetching seed data..."
curl -fsSL "$BASE_URL/seed-data.json" -o "$WORK_DIR/seed-data.json" || {
  echo "Error: could not fetch seed-data.json from $BASE_URL"
  exit 1
}
curl -fsSL "$BASE_URL/branches.bundle" -o "$WORK_DIR/branches.bundle" || {
  echo "Error: could not fetch branches.bundle from $BASE_URL"
  exit 1
}

# --- Push PR branches ---
HAS_PRS=$(python3 -c "
import json
data = json.load(open('$WORK_DIR/seed-data.json'))
print('yes' if data.get('prs') else 'no')
")

if [[ "$HAS_PRS" == "yes" && -s "$WORK_DIR/branches.bundle" ]]; then
  echo "Pushing PR branches to $TARGET..."

  git clone --quiet "https://github.com/$TARGET.git" "$WORK_DIR/target-repo"
  cd "$WORK_DIR/target-repo"

  git fetch --quiet "$WORK_DIR/branches.bundle" 'refs/heads/*:refs/remotes/bundle/*'

  PR_BRANCHES=$(python3 -c "
import json
data = json.load(open('$WORK_DIR/seed-data.json'))
branches = set()
for p in data['prs']:
    branches.add(p['head_ref'])
    # base_ref (main) already exists, only push head branches
print(' '.join(b for b in branches if b != 'main'))
")

  TARGET_REMOTE="https://github.com/$TARGET.git"
  for branch in $PR_BRANCHES; do
    echo "  Pushing branch: $branch"
    git push --quiet "$TARGET_REMOTE" "refs/remotes/bundle/$branch:refs/heads/$branch" || {
      echo "  warn: failed to push $branch (may already exist)"
    }
  done

  cd - >/dev/null
fi

# --- Seed issues, labels, comments, PRs ---
python3 - "$TARGET" "$WORK_DIR/seed-data.json" <<'PYEOF'
import sys, json, subprocess, time

target    = sys.argv[1]
data      = json.load(open(sys.argv[2]))

def gh_api(method, path, payload=None):
    cmd = ["gh", "api", "--method", method, path]
    inp = json.dumps(payload).encode() if payload else None
    if inp:
        cmd += ["--input", "-"]
    result = subprocess.run(cmd, input=inp, capture_output=True)
    if result.returncode != 0:
        print(f"    warn: {result.stderr.decode().strip()[:120]}")
        return None
    return json.loads(result.stdout) if result.stdout else {}

# ── 1. Labels ──────────────────────────────────────────────────────────────
print("Creating labels...")
existing_raw = subprocess.run(
    ["gh", "api", f"repos/{target}/labels?per_page=100"],
    capture_output=True, text=True, check=True
).stdout
existing = {l["name"] for l in json.loads(existing_raw)}

created = skipped = 0
for label in data["labels"]:
    if label["name"] in existing:
        skipped += 1
        continue
    r = gh_api("POST", f"repos/{target}/labels", {
        "name": label["name"], "color": label["color"], "description": label["description"],
    })
    if r is not None:
        created += 1
    time.sleep(0.1)
print(f"  Labels: {created} created, {skipped} already existed")

# ── 2. Issues ──────────────────────────────────────────────────────────────
print("Creating issues...")
plain_issues = sorted(
    [i for i in data["issues"] if not i["is_pr"]],
    key=lambda i: i["number"]
)

number_map = {}
issue_created = 0
for issue in plain_issues:
    r = gh_api("POST", f"repos/{target}/issues", {
        "title":  issue["title"],
        "body":   issue["body"],
        "labels": issue["labels"],
    })
    if r:
        number_map[str(issue["number"])] = r["number"]
        issue_created += 1
    time.sleep(0.2)
print(f"  Issues: {issue_created} created")

# ── 3. Issue comments ──────────────────────────────────────────────────────
print("Adding issue comments...")
comment_count = 0
for orig_num, comments in data["comments"].items():
    new_num = number_map.get(orig_num)
    if new_num is None:
        continue
    for comment in comments:
        r = gh_api("POST", f"repos/{target}/issues/{new_num}/comments", {"body": comment["body"]})
        if r:
            comment_count += 1
        time.sleep(0.15)
print(f"  Comments: {comment_count} added")

# ── 4. Close issues that were closed in source ─────────────────────────────
closed = [i for i in plain_issues if i["state"] == "closed"]
if closed:
    print(f"Closing {len(closed)} issues...")
    for issue in closed:
        new_num = number_map.get(str(issue["number"]))
        if new_num:
            gh_api("PATCH", f"repos/{target}/issues/{new_num}", {"state": "closed"})
            time.sleep(0.1)

# ── 5. Pull requests ───────────────────────────────────────────────────────
prs = data.get("prs", [])
if prs:
    print(f"Creating {len(prs)} pull request(s)...")
    pr_number_map = {}
    pr_created = 0
    for pr in sorted(prs, key=lambda p: p["number"]):
        payload = {
            "title": pr["title"],
            "body":  pr["body"],
            "head":  pr["head_ref"],
            "base":  pr["base_ref"],
            "draft": pr["draft"],
        }
        r = gh_api("POST", f"repos/{target}/pulls", payload)
        if r:
            pr_number_map[str(pr["number"])] = r["number"]
            pr_created += 1
            # Apply labels to PR (done via issues API)
            if pr["labels"]:
                gh_api("PATCH", f"repos/{target}/issues/{r['number']}", {"labels": pr["labels"]})
        time.sleep(0.3)
    print(f"  PRs: {pr_created} created")

    # ── 6. PR comments ─────────────────────────────────────────────────────
    pr_comments = data.get("pr_comments", {})
    if pr_comments:
        print("Adding PR comments...")
        pr_comment_count = 0
        for orig_num, comments in pr_comments.items():
            new_num = pr_number_map.get(orig_num)
            if new_num is None:
                continue
            for comment in comments:
                r = gh_api("POST", f"repos/{target}/issues/{new_num}/comments", {"body": comment["body"]})
                if r:
                    pr_comment_count += 1
                time.sleep(0.15)
        print(f"  PR comments: {pr_comment_count} added")

    # ── 7. Close PRs that were closed/merged in source ─────────────────────
    closed_prs = [p for p in prs if p["state"] in ("closed", "merged")]
    if closed_prs:
        print(f"Closing {len(closed_prs)} PR(s)...")
        for pr in closed_prs:
            new_num = pr_number_map.get(str(pr["number"]))
            if new_num:
                gh_api("PATCH", f"repos/{target}/pulls/{new_num}", {"state": "closed"})
                time.sleep(0.1)

print("")
print(f"Done! View your repo: https://github.com/{target}")
PYEOF
