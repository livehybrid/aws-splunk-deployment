#!/usr/bin/env bash
# Package the apps repo into per-scope tarballs and upload them to the SOK apps
# bucket (App Framework source). The SOK counterpart of deploy-apps.sh's EC2
# git-sync — under deployment_model=sok apps flow git -> S3 -> operator Download
# -> PodCopy instead of being cloned on-instance.
#
#   ./scripts/package-apps.sh <env> [scope]
#
#   scope: all (default) | cm | sh | idx | shc | mc  — which tier prefix(es) to sync
#
# Repo dir  ->  S3 prefix   ->  reaches (via the CR appFrameworkConfig)
#   apps/          cm-apps/      ClusterManager  (scope local, CM's etc/apps)
#   apps/          sh-apps/      Standalone SH   (scope local)
#   manager-apps/  idx-apps/     indexers        (CM, scope cluster -> bundle)
#   shcluster/apps/ shc-apps/    SHC members     (scope local)   [prod]
#   mc-apps/       mc-apps/      MonitoringConsole (scope local)
#   deployment-apps/  —          skipped: no DS CRD in SOK (edge stays EC2)
#
# ⚠ Archive filenames are STABLE forever (change detection is Etag-by-filename;
#   a rename breaks upgrade tracking — SOK #1105). Never embed versions.
# ⚠ Deleting an archive does NOT uninstall the app (#893) — retire by shipping a
#   final version with state=disabled in app.conf.
# ⚠ These apps carry EC2-specific bits (#splunksecret:...# placeholders, a prod
#   master_uri) that are substituted on-instance on EC2 but NOT by App Framework.
#   Parameterise before relying on their runtime behaviour under SOK; they still
#   install cleanly, which is what the K4 pipeline proves.
set -euo pipefail
export AWS_PAGER=""

ENV="${1:?usage: package-apps.sh <env> [all|cm|sh|idx|shc|mc]}"
SCOPE="${2:-all}"
case "$SCOPE" in all|cm|sh|idx|shc|mc) ;; *) echo "invalid scope '$SCOPE'" >&2; exit 2 ;; esac
REGION="${AWS_REGION:-eu-west-2}"
BUCKET="livehybrid-splunk-${ENV}-splunk-apps-${ENV}"
APPS_REPO="${APPS_GIT_REPO:-github.com/livehybrid/splunk-apps.git}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== cloning $APPS_REPO"
TOKEN="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id /git/login --query SecretString --output text)"
git clone --depth 1 "https://${TOKEN}@${APPS_REPO}" "$WORK/repo" 2>&1 | grep -v "$TOKEN" || true
unset TOKEN
[ -d "$WORK/repo" ] || { echo "clone failed" >&2; exit 1; }

# (source dir, prefix, scope-tag) — one row per upload target.
MAP="
apps|cm-apps|cm
apps|sh-apps|sh
manager-apps|idx-apps|idx
shcluster/apps|shc-apps|shc
mc-apps|mc-apps|mc
"

staged=0
while IFS='|' read -r src prefix tag; do
  [ -z "${src:-}" ] && continue
  [ "$SCOPE" = "all" ] || [ "$SCOPE" = "$tag" ] || continue
  srcdir="$WORK/repo/$src"
  [ -d "$srcdir" ] || { echo "   (no $src/ in repo — skip $prefix)"; continue; }
  for appdir in "$srcdir"/*/; do
    [ -d "$appdir" ] || continue
    app="$(basename "$appdir")"
    tgz="$WORK/${app}.tgz"
    # Deterministic archive (OPS-11): identical content => identical bytes, so
    # the App Framework's checksum-driven redeploys fire only on real changes.
    # Portable across GNU tar (CI) and bsdtar (macOS), whose flags differ:
    #   - stage a copy and pin every mtime (bsdtar has no --mtime),
    #   - archive a sorted FILE list via -T (bsdtar has no --sort); listing
    #     files only sidesteps recursion double-adds, and extraction still
    #     creates parent dirs (Splunk apps carry no empty dirs),
    #   - zero uid/gid (flavor-specific flags), gzip -n (no embedded mtime).
    # COPYFILE_DISABLE strips macOS ._AppleDouble metadata.
    stage="$WORK/stage"; rm -rf "$stage"; mkdir -p "$stage"
    cp -R "$srcdir/$app" "$stage/"
    find "$stage" -exec touch -t 202001010000 {} +
    if tar --version 2>/dev/null | grep -qi 'gnu tar'; then
      ( cd "$stage" && find "$app" \( -type f -o -type l \) -print | LC_ALL=C sort \
        | COPYFILE_DISABLE=1 tar --no-recursion --owner=0 --group=0 --numeric-owner -cf - -T - \
        | gzip -n ) > "$tgz"
    else
      ( cd "$stage" && find "$app" \( -type f -o -type l \) -print | LC_ALL=C sort \
        | COPYFILE_DISABLE=1 tar -n --uid 0 --gid 0 -cf - -T - \
        | gzip -n ) > "$tgz"
    fi
    aws s3 cp "$tgz" "s3://${BUCKET}/${prefix}/${app}.tgz" --region "$REGION" --only-show-errors
    echo "   -> s3://${BUCKET}/${prefix}/${app}.tgz"
    staged=$((staged+1))
  done
done <<< "$MAP"

echo "== staged $staged archive(s) to $BUCKET"
echo "   the operator polls every 600s; force now with:"
echo "     kubectl patch cm splunk-splunk-manual-app-update -n splunk --type merge \\"
echo "       -p '{\"data\":{\"ClusterManager\":\"status: on\\nrefCount: 1\"}}'"
