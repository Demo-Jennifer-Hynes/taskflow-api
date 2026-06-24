#!/usr/bin/env bash
# Seeds a GitHub repo with issues, labels, and comments from taskflow-api
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/hynes-hq/taskflow-api/main/scripts/seed.sh) OWNER/YOUR-REPO
#
# Prerequisites: gh CLI installed and authenticated

set -euo pipefail

TARGET="${1:-}"
SOURCE_REPO="hynes-hq/taskflow-api"
SEED_URL="https://raw.githubusercontent.com/hynes-hq/taskflow-api/main/scripts/seed-data.json"

# --- Checks ---
if [[ -z "$TARGET" ]]; then
  echo "Usage: seed.sh OWNER/YOUR-REPO"
  echo "Example: seed.sh myorg/my-taskflow-fork"
  exit 1
fi

command -v gh >/dev/null 2>&1      || { echo "Error: gh CLI not installed. See https://cli.github.com"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Error: python3 not found"; exit 1; }
gh auth status >/dev/null 2>&1     || { echo "Error: not authenticated. Run: gh auth login"; exit 1; }

echo "Seeding $TARGET from $SOURCE_REPO"
echo ""

# --- Fetch seed data ---
if ! curl -fsSL "$SEED_URL" -o /tmp/_seed_data.json 2>/dev/null; then
  echo "Error: could not fetch seed data from $SEED_URL"
  echo "Make sure seed-data.json has been committed to $SOURCE_REPO/scripts/"
  exit 1
fi

# --- Run seeder ---
python3 - "$TARGET" <<'PYEOF'
import sys, json, subprocess, time

target = sys.argv[1]
data   = json.load(open("/tmp/_seed_data.json"))

def gh_post(path, payload):
    result = subprocess.run(
        ["gh", "api", "--method", "POST", path, "--input", "-"],
        input=json.dumps(payload).encode(),
        capture_output=True
    )
    if result.returncode != 0:
        print(f"    warn: {result.stderr.decode().strip()[:120]}")
    return result.returncode == 0

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
    ok = gh_post(f"repos/{target}/labels", {
        "name":        label["name"],
        "color":       label["color"],
        "description": label["description"],
    })
    if ok:
        created += 1
    time.sleep(0.1)

print(f"  Labels: {created} created, {skipped} already existed")

# ── 2. Issues ──────────────────────────────────────────────────────────────
print("Creating issues...")

# Sort oldest-first so numbering is predictable
issues = sorted(
    [i for i in data["issues"] if not i["is_pr"]],
    key=lambda i: i["number"]
)

number_map = {}  # original_number → new_number
issue_created = 0

for issue in issues:
    payload = {
        "title":  issue["title"],
        "body":   issue["body"],
        "labels": issue["labels"],
    }
    result = subprocess.run(
        ["gh", "api", "--method", "POST", f"repos/{target}/issues", "--input", "-"],
        input=json.dumps(payload).encode(),
        capture_output=True
    )
    if result.returncode == 0:
        new_issue = json.loads(result.stdout)
        number_map[str(issue["number"])] = new_issue["number"]
        issue_created += 1
    else:
        print(f"  warn: failed to create issue #{issue['number']}: "
              f"{result.stderr.decode().strip()[:100]}")
    time.sleep(0.2)

print(f"  Issues: {issue_created} created")

# ── 3. Comments ────────────────────────────────────────────────────────────
print("Adding comments...")
comment_count = 0

for orig_num, comments in data["comments"].items():
    new_num = number_map.get(orig_num)
    if new_num is None:
        continue
    for comment in comments:
        ok = gh_post(f"repos/{target}/issues/{new_num}/comments", {
            "body": comment["body"]
        })
        if ok:
            comment_count += 1
        time.sleep(0.15)

print(f"  Comments: {comment_count} added")

# ── 4. Close issues that were closed in the source ─────────────────────────
closed = [i for i in issues if i["state"] == "closed"]
if closed:
    print(f"Closing {len(closed)} issues...")
    for issue in closed:
        new_num = number_map.get(str(issue["number"]))
        if new_num is None:
            continue
        subprocess.run(
            ["gh", "api", "--method", "PATCH",
             f"repos/{target}/issues/{new_num}",
             "--input", "-"],
            input=json.dumps({"state": "closed"}).encode(),
            capture_output=True
        )
        time.sleep(0.1)

print("")
print(f"Done! View your repo: https://github.com/{target}/issues")
PYEOF

rm -f /tmp/_seed_data.json
