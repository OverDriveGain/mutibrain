#!/bin/bash
# Re-vendor the MyMu ANDROID client (~/Projects/mymu/android) into the MyAgent
# Android app — the drawer's chat IS MyMu's chat, verbatim (Manar 2026-10-24,
# same rule as ios/MyMuChat). Idempotent: rsync core/ + ui/ (package kept:
# com.mymu.app.*), the harness logos, the HOST PATCHES, the VENDORING.md stamp.
#   scripts/vendor-mymu-android.sh [path-to-mymu-checkout]
set -euo pipefail
SRC=${1:-$HOME/Projects/mymu}
cd "$(dirname "$0")/.."
FROM="$SRC/android/app/src/main/java/com/mymu/app"
TO=android/app/src/main/java/com/mymu/app
mkdir -p "$TO"
# core/ + ui/ only: the standalone entry points (MainActivity, MyMuApplication,
# MyMuMessagingService, ShareActivity) live one level up and are NOT copied —
# the host (com.manarz.myagent) owns the activity, the Application and push.
rsync -a --delete "$FROM/core/" "$TO/core/"
rsync -a --delete "$FROM/ui/" "$TO/ui/"
cp "$SRC"/android/app/src/main/res/drawable/harness_*.xml android/app/src/main/res/drawable/

python3 - "$TO" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
def patch(rel, old, new, tag):
    p = root / rel; s = p.read_text()
    if tag in s: return
    assert old in s, f'{rel} changed upstream — re-check the patch ({tag})'
    p.write_text(s.replace(old, new, 1))

# 1. Resources + BuildConfig belong to the HOST module (namespace com.manarz.myagent).
for p in root.rglob('*.kt'):
    s = p.read_text(); o = s
    s = s.replace('import com.mymu.app.R\n', 'import com.manarz.myagent.R // HOST PATCH: host resources\n')
    s = s.replace('import com.mymu.app.BuildConfig\n', 'import com.manarz.myagent.BuildConfig // HOST PATCH: host BuildConfig\n')
    s = s.replace('com.mymu.app.BuildConfig.', 'com.manarz.myagent.BuildConfig.')
    # 2. The host manifest declares the FileProvider as ${applicationId}.files.
    s = s.replace('"${context.packageName}.fileprovider"', '"${context.packageName}.files" /* HOST PATCH: host FileProvider */')
    if s != o: p.write_text(s)

# 3. The drawer's CURATED roster (iOS ProjectsStore host patch, 2026-10-30):
#    agent names in order, brain first; null = every remote agent (MyMu's own
#    behaviour). `agents`, the swipe switcher and the dots all read rosterOf().
patch('core/ProjectsStore.kt',
'''    val agents: List<Project> get() = projects.value.filter { it.isRemoteAgent == true }''',
'''    // HOST PATCH (MyAgent): the drawer's curated roster — see VENDORING.md.
    var agentFilter: List<String>? = null
    fun rosterOf(list: List<Project>): List<Project> {
        val all = list.filter { it.isRemoteAgent == true }
        val names = agentFilter?.takeIf { it.isNotEmpty() } ?: return all
        val out = mutableListOf<Project>()
        for (n in names) {
            val w = n.lowercase()
            val p = all.firstOrNull { it.displayName.lowercase() == w }
                ?: all.firstOrNull { (it.sessions?.firstOrNull()?.summary ?: "").lowercase() == w }
            if (p != null && out.none { it.projectId == p.projectId }) out += p
        }
        return out
    }
    val agents: List<Project> get() = rosterOf(projects.value)''', 'HOST PATCH (MyAgent)')

patch('ui/AgentSwitcher.kt',
'''    val roster = projects.filter { it.isRemoteAgent == true }''',
'''    val roster = store.rosterOf(projects) // HOST PATCH (MyAgent): curated roster''', 'HOST PATCH (MyAgent)')
print('host patches in place')
PY

# Dictation needs NO patch on Android: MyMu's own ComposerInsertBus already
# carries "insert this into the draft" (com.manarz.myagent.chat.Dictation uses it).
HEAD=$(git -C "$SRC" rev-parse --short HEAD)
DIRTY=$(git -C "$SRC" status --short android | wc -l | tr -d ' ')
sed -i "s/^Last vendored: .*/Last vendored: $(date +%F\ %H:%M) from MyMu HEAD $HEAD (+ $DIRTY uncommitted files in its android tree)./" android/VENDORING.md
echo "vendored MyMu android $HEAD (+$DIRTY dirty) into $TO"
