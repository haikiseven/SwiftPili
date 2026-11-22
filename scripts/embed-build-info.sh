#!/bin/sh
# Records the git commit and build date in the BUILT app's Info.plist.
#
# Run by the "Embed Build Info" run-script phase (project.yml postBuildScripts)
# on every build. It edits only $TARGET_BUILD_DIR/$INFOPLIST_PATH, never a
# tracked file, so building does not dirty the working tree. Read back by
# AppBuildInfo; a missing key there means "unknown".
#
# Keys:
#   SPBuildGitCommit  short SHA of HEAD, or "unknown" without git/a repo
#   SPBuildGitDirty   true when tracked files differ from HEAD (the same rule
#                     as `git describe --dirty`); absent when unknown
#   SPBuildDate       UTC build time, ISO 8601
set -u

plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
repo="${SRCROOT:-$(pwd)}"
buddy=/usr/libexec/PlistBuddy

if [ ! -f "$plist" ]; then
    echo "warning: embed-build-info: $plist not found; skipping"
    exit 0
fi

commit=unknown
dirty=
if command -v git >/dev/null 2>&1 \
    && sha=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null) && [ -n "$sha" ]; then
    commit=$sha
    if changes=$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null); then
        if [ -n "$changes" ]; then dirty=true; else dirty=false; fi
    fi
fi
date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

set_key() {
    "$buddy" -c "Delete :$1" "$plist" >/dev/null 2>&1
    "$buddy" -c "Add :$1 $2 $3" "$plist"
}

set_key SPBuildGitCommit string "$commit"
set_key SPBuildDate string "$date"
"$buddy" -c "Delete :SPBuildGitDirty" "$plist" >/dev/null 2>&1
if [ -n "$dirty" ]; then
    set_key SPBuildGitDirty bool "$dirty"
fi

echo "embed-build-info: commit=$commit dirty=${dirty:-unknown} date=$date"
