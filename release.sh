#!/usr/bin/env bash
# Publish the newest ISOs from out/ as one GitHub release (needs `gh` logged in).
# GitHub release assets are limited to 2 GiB, so each ISO is uploaded in parts.
#
#   ./release.sh              release the newest out/cachyos-{desktop,minimal}-*-bcachefs.iso
#                             (whichever exist) as tag/title linux-cachyos-<ver>_bcachefs-<ver>
#                             (plus -<build date> when that release already exists)
#   ./release.sh a.iso b.iso  release specific ones
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo"   # gh picks the GitHub repo from the git remote
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
msg() { printf '\e[1;32m==>\e[0m \e[1m%s\e[0m\n' "$*"; }

if (( $# > 0 )); then
    isos=("$@")
else
    isos=()
    for f in desktop minimal; do
        i="$(ls -t "$repo"/out/cachyos-"$f"-*-bcachefs.iso 2>/dev/null | head -1 || true)"
        [[ -z $i ]] || isos+=("$i")
    done
fi
(( ${#isos[@]} > 0 )) || die "no ISO found, run ./build.sh first"

# package version without epoch/pkgrel: 3:1.39.7-1 -> 1.39.7
ver() { awk -v p="$1" '$1==p {v=$2; sub(/^[0-9]+:/,"",v); sub(/-[^-]+$/,"",v); print v}' "$2"; }

tag=""
for iso in "${isos[@]}"; do
    [[ -f $iso ]] || die "$iso not found"
    pkgs="${iso%.iso}.pkgs.txt"
    [[ -f $pkgs ]] || die "missing $pkgs"
    kver="$(ver linux-cachyos "$pkgs")"; bver="$(ver bcachefs-tools "$pkgs")"
    [[ -n $kver && -n $bver ]] || die "can't read linux-cachyos/bcachefs-tools versions from $pkgs"
    t="linux-cachyos-${kver}_bcachefs-${bver}"
    [[ -z $tag || $tag == "$t" ]] || die "the ISOs have different versions ($tag, $t): release them separately"
    tag=$t
done
if gh release view "$tag" &>/dev/null; then
    # A rebuild with the same kernel and bcachefs versions gets its build date appended.
    built="$(grep -oE '[0-9]{6}' <<<"$(basename "${isos[0]}")" | tail -1)"
    tag="$tag-$built"
    gh release view "$tag" &>/dev/null && die "release $tag already exists"
fi

rel="$repo/out/release-$tag"
rm -rf "$rel"; mkdir -p "$rel"
url="$(gh repo view --json url -q .url)"
files=()
rows=""
downloads=""
for iso in "${isos[@]}"; do
    dir="$(dirname "$iso")"; n="$(basename "$iso" .iso)"
    msg "Verifying $n.iso"
    (cd "$dir" && sha256sum -c "$n.iso.sha256")
    msg "Splitting $n.iso into <2 GiB parts"
    split -b 1900M -d -a 2 "$iso" "$rel/$n.iso.part"
    cp "$dir/$n.iso.sha256" "$dir/$n.pkgs.txt" "$rel/"
    parts=("$rel/$n.iso.part"*)
    (cd "$rel" && sha256sum "${parts[@]##*/}" > "$n.parts.sha256")
    files+=("${parts[@]}" "$rel/$n.iso.sha256" "$rel/$n.parts.sha256" "$rel/$n.pkgs.txt")

    case "$n" in
        cachyos-minimal-*) what="console only, with the \`cachyinstall\` TUI installer";;
        *) what="upstream's KDE Plasma desktop live ISO";;
    esac
    extra=""
    if [[ -f $dir/$n.upstream.txt ]]; then
        ci="$(awk '$1=="cachyinstall" {print $2}' "$dir/$n.upstream.txt")"
        [[ -z $ci ]] || extra=", cachyinstall \`$ci\`"
    fi
    rows+="| \`$n.iso\` | $what$extra |"$'\n'
    downloads+="sha256sum -c $n.parts.sha256 && cat $n.iso.part* > $n.iso && sha256sum -c $n.iso.sha256"$'\n'
done

first_pkgs="${isos[0]%.iso}.pkgs.txt"
up="$(awk '$1=="upstream" {print $2}' "${isos[0]%.iso}.upstream.txt" 2>/dev/null || echo unknown)"
cat > "$rel/notes.md" <<EOF
CachyOS live ISOs (upstream [\`$up\`](https://github.com/CachyOS/CachyOS-Live-ISO/commit/$up)) with the bcachefs kernel module built in.

| ISO | |
|---|---|
$rows
| | |
|---|---|
| linux-cachyos | $(ver linux-cachyos "$first_pkgs") |
| linux-cachyos-lts | $(ver linux-cachyos-lts "$first_pkgs") |
| bcachefs (module + tools) | $(ver bcachefs-tools "$first_pkgs") |
| built | $(grep -oE '[0-9]{6}' <<<"$(basename "${isos[0]}")" | tail -1) |

### Download
GitHub limits release files to 2 GiB, so each ISO is split into parts. Download the parts of the one you want, then join and verify:

\`\`\`sh
$downloads\`\`\`

The full package lists are in the \`.pkgs.txt\` files. See the [README]($url#readme) for usage and rescue instructions.
EOF

msg "Creating release $tag"
gh release create "$tag" --target main \
    --title "$tag" --notes-file "$rel/notes.md" "${files[@]}"
rm -rf "$rel"
msg "Released $tag"
