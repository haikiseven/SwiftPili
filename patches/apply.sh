#!/usr/bin/env bash
#
# Apply every SwiftPili player patch to a sibling SwiftVLC fork, then all you do
# is run build-libvlc.sh. Idempotent — safe to re-run.
#
#   patches/apply.sh [--clean-vlc] [path-to-SwiftVLC]      # default: ../SwiftVLC
#
# Why a script and not just `git apply`:
#  - The AV1 fix edits the va_videotoolbox.c heredoc inside build-libvlc.sh. A
#    context-diff patch there breaks the moment build-libvlc.sh drifts a line
#    (it did). We apply it by ANCHOR instead — robust to line drift, idempotent.
#  - The libvlc/*.patch set must be COPIED into the fork's scripts/patches/
#    (build-libvlc.sh globs that dir); pointing --patches-dir at ours would drop
#    SwiftVLC's own chromecast patch.
#  - The AV1 module is only (re)generated when va_videotoolbox.c is absent, so a
#    clean VLC checkout is the ONLY reliable way to pick up an edited heredoc.
#    (Reverting individual generated files by hand strands Makefile.am — that
#    was the vt_utils_native '--tag' build break.)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # .../<repo>/patches
repo="$(cd "$here/.." && pwd)"                            # .../<repo>
clean_vlc=0
vlc=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clean-vlc)
      clean_vlc=1
      shift
      ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [ -n "$vlc" ]; then
        echo "ERROR: unexpected argument: $1" >&2
        exit 2
      fi
      vlc="$1"
      shift
      ;;
  esac
done
vlc="${vlc:-$(cd "$repo/.." && pwd)/SwiftVLC}"

[ -f "$vlc/scripts/build-libvlc.sh" ] \
  || { echo "ERROR: no SwiftVLC fork at '$vlc' — pass its path as \$1" >&2; exit 1; }
echo "SwiftVLC fork: $vlc"

# 0) Reset build-libvlc.sh to pristine so re-applies never STACK. Our edits
#    (0002/0003 + the AV1 fix) are uncommitted working-tree changes; without
#    this a prior 0004 apply + this script's editor both add a `decoded` var and
#    the generated module fails with "redefinition of 'decoded'". The fork's
#    committed content — including the base AV1 module heredoc — is preserved;
#    only our patches are reset, then re-applied fresh below.
if git -C "$vlc" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$vlc" checkout -- scripts/build-libvlc.sh 2>/dev/null \
    && echo "  reset scripts/build-libvlc.sh to pristine" || true
fi

# 1) build-script / Package.swift plumbing (0001-0003) — plain git apply, idempotent.
for p in "$here"/swiftvlc/000[123]-*.patch; do
  n=$(basename "$p")
  if git -C "$vlc" apply --reverse --check "$p" 2>/dev/null; then
    echo "  skip     $n (already applied)"
  elif git -C "$vlc" apply --check "$p" 2>/dev/null; then
    git -C "$vlc" apply "$p"; echo "  applied  $n"
  else
    echo "  WARN     $n did not apply cleanly — inspect manually" >&2
  fi
done

# 2) AV1 F17 fix — anchor-edit the va_videotoolbox.c heredoc (supersedes the
#    fragile swiftvlc/0004 git patch). Idempotent via marker strings.
python3 - "$vlc/scripts/build-libvlc.sh" <<'PY'
import sys
path = sys.argv[1]
s = open(path).read()
orig = s

# -- the fix: re-read the DECODED CVPixelBuffer when VLC clones the picture --
# Idempotency keys off the fix EXPRESSION, not a comment — so it also recognises
# a prior swiftvlc/0004 apply (whose comment text differs) and never duplicates.
if "*(CVPixelBufferRef *)src_ctx->avframe->buf[0]->data" in s:
    print("  AV1 copy() fix: already present")
else:
    anchor = "    *pic_ctx = *src_ctx;\n"
    if anchor not in s:
        sys.exit("  ERROR: copy() anchor not found — module heredoc differs, "
                 "send me `sed -n '1255,1340p' scripts/build-libvlc.sh`")
    s = s.replace(anchor, anchor + '''
    /* F17: capture the decoded CVPixelBuffer post-decode. Get() runs at
     * get_buffer2 time, BEFORE decode, so the buffer it read from
     * frame->data[3] was the empty pool buffer and rendered black though HW
     * decode ran. VLC clones the output picture only AFTER decode
     * (picture_Clone -> this copy op); by then FFmpeg's VT hwaccel has written
     * the decoded buffer into the VTHWFrame behind buf[0]->data (ref->pixbuf,
     * its first field — the same (VTHWFrame*)buf[0]->data cast FFmpeg uses).
     * NULL-safe: an unexpected layout yields NULL and keeps the old buffer
     * (black, never a crash). */
    CVPixelBufferRef decoded = NULL;
    if (src_ctx->avframe != NULL && src_ctx->avframe->buf[0] != NULL &&
        src_ctx->avframe->buf[0]->data != NULL)
        decoded = *(CVPixelBufferRef *)src_ctx->avframe->buf[0]->data;
    if (decoded != NULL)
        pic_ctx->cvpx = decoded;
''', 1)
    print("  AV1 copy() fix: applied")

# -- get-time diagnostic (non-fatal if its anchor is missing) --
if "[AV1-VT] Get:" in s:
    print("  AV1 diag: already present")
else:
    danchor = "    vt_dec_pic_context *pctx = malloc(sizeof(*pctx));\n"
    if danchor in s:
        s = s.replace(danchor,
'''    msg_Dbg(va, "[AV1-VT] Get: data[3]=%p buf[0]=%p buf0->data=%p pixbuf@buf0=%p",
            (void *)frame->data[3], (void *)frame->buf[0],
            frame->buf[0] ? (void *)frame->buf[0]->data : NULL,
            (frame->buf[0] && frame->buf[0]->data) ? *(void **)frame->buf[0]->data : NULL);

''' + danchor, 1)
        print("  AV1 diag: applied")
    else:
        print("  AV1 diag: anchor not found — skipped (non-fatal)")

if s != orig:
    open(path, "w").write(s)
PY

# 3) libvlc patches -> the fork's scripts/patches/ (build-libvlc.sh applies these)
mkdir -p "$vlc/scripts/patches"
# Drop every non-0001 numbered patch (retired or renamed, e.g. 0007 avsamplebuffer
# cap, or 0008-videotoolbox-native-av1 renamed to 0007-) while preserving
# SwiftVLC's own 0001-* chromecast patch, then copy the current set fresh.
for existing in "$vlc/scripts/patches"/[0-9][0-9][0-9][0-9]-*.patch; do
  [ -e "$existing" ] || continue
  case "$(basename "$existing")" in
    0001-*.patch) continue ;;
  esac
  rm -f "$existing"
done
cp "$here"/libvlc/*.patch "$vlc/scripts/patches/"
echo "  copied $(ls "$here"/libvlc/*.patch | wc -l | tr -d ' ') libvlc patch(es) -> scripts/patches/"

# 4) Reset VLC checkout so build-libvlc.sh cleanly re-applies 0001..0015.
#    When --clean-vlc is unset AND the checkout already has the F17 AV1 anchors
#    (va_videotoolbox.c copy() fix + Makefile.am libvt_avcodec_va_plugin), keep
#    the multi-GB contrib/arch build tree and only reset files touched by
#    scripts/patches/*.patch back to clean HEAD. Otherwise remove the checkout so
#    build-libvlc.sh re-clones and regenerates the AV1 heredoc from scratch.
vlc_checkout="$vlc/scripts/.build-libvlc/vlc"
va_vt="$vlc_checkout/modules/codec/avcodec/va_videotoolbox.c"
codec_mk="$vlc_checkout/modules/codec/Makefile.am"
if [ -d "$vlc_checkout" ]; then
  if [ "$clean_vlc" = 0 ] \
     && git -C "$vlc_checkout" rev-parse --git-dir >/dev/null 2>&1 \
     && [ -f "$va_vt" ] && grep -Fq '*(CVPixelBufferRef *)src_ctx->avframe->buf[0]->data' "$va_vt" \
     && [ -f "$codec_mk" ] && grep -Fq 'libvt_avcodec_va_plugin' "$codec_mk"; then
    python3 - "$vlc/scripts/patches" "$vlc_checkout" <<'PY'
import glob, os, re, subprocess, sys

patches_dir, vlc_checkout = sys.argv[1], sys.argv[2]
patch_files = sorted(glob.glob(os.path.join(patches_dir, "*.patch")))

paths = set()
new_paths = set()
diff_git_re = re.compile(r"^diff --git a/(.+?) b/(.+)$")
hdr_re = re.compile(r"^(--- a/|\+\+\+ b/)([^\t\r\n]+)")

for pf in patch_files:
    prev_was_dev_null = False
    with open(pf, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\r\n")
            m = diff_git_re.match(line)
            if m:
                paths.add(m.group(1))
                paths.add(m.group(2))
                prev_was_dev_null = False
                continue
            if line.startswith("--- /dev/null"):
                prev_was_dev_null = True
                continue
            m = hdr_re.match(line)
            if m:
                p = m.group(2)
                if p != "/dev/null":
                    paths.add(p)
                    if m.group(1) == "+++ b/" and prev_was_dev_null:
                        new_paths.add(p)
                prev_was_dev_null = False
            elif not line.startswith("new file mode"):
                prev_was_dev_null = False

tracked_raw = subprocess.check_output(
    ["git", "-C", vlc_checkout, "ls-files", "-z"]
).split(b"\0")
tracked_set = {p.decode("utf-8", errors="surrogateescape") for p in tracked_raw if p}

to_checkout = sorted(p for p in paths if p in tracked_set)
to_remove = sorted(
    p for p in (new_paths | (paths - tracked_set))
    if p not in tracked_set and os.path.lexists(os.path.join(vlc_checkout, p))
)

if to_checkout:
    subprocess.run(
        ["git", "-C", vlc_checkout, "checkout", "--", *to_checkout],
        check=True,
    )
for p in to_remove:
    os.remove(os.path.join(vlc_checkout, p))

print(
    f"  incremental reset: checked out {len(to_checkout)} tracked file(s), "
    f"removed {len(to_remove)} untracked patch file(s) (preserved build tree)"
)
PY
  else
    rm -rf "$vlc_checkout"
    if [ "$clean_vlc" = 1 ]; then
      echo "  removed VLC checkout (--clean-vlc; build-libvlc.sh will re-clone)"
    else
      echo "  removed stale VLC checkout (missing F17 anchor or non-git tree; build-libvlc.sh will re-clone)"
    fi
  fi
fi

cat <<EOF

Done. Next:
  cd "$vlc" && ./scripts/build-libvlc.sh --ios-only
  "$repo/patches/libvlc/verify/check-applied.sh" "$vlc/scripts/.build-libvlc/vlc"
  cd "$repo" && xcodegen
EOF
