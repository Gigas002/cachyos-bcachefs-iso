#!/usr/bin/env bash
# Publish the newest ISO from out/ as a GitHub release (needs `gh` logged in).
# GitHub release assets are limited to 2 GiB, so the ISO is uploaded in parts.
#
#   ./release.sh              release newest out/*-bcachefs.iso
#                             as tag/title linux-cachyos-<ver>_bcachefs-<ver>
#   ./release.sh path/to.iso  release a specific one
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo"   # gh picks the GitHub repo from the git remote
die() { printf '\e[1;31m==> ERROR:\e[0m %s\n' "$*" >&2; exit 1; }
msg() { printf '\e[1;32m==>\e[0m \e[1m%s\e[0m\n' "$*"; }

iso="${1:-$(ls -t "$repo"/out/*-bcachefs.iso 2>/dev/null | head -1)}"
[[ -f $iso ]] || die "no ISO found, run ./build.sh first"
dir="$(dirname "$iso")"; n="$(basename "$iso" .iso)"
pkgs="$dir/$n.pkgs.txt"
[[ -f $pkgs ]] || die "missing $pkgs"
# package version without epoch/pkgrel: 3:1.39.7-1 -> 1.39.7
ver() { awk -v p="$1" '$1==p {v=$2; sub(/^[0-9]+:/,"",v); sub(/-[^-]+$/,"",v); print v}' "$pkgs"; }
kver="$(ver linux-cachyos)"; bver="$(ver bcachefs-tools)"
[[ -n $kver && -n $bver ]] || die "can't read linux-cachyos/bcachefs-tools versions from $pkgs"
tag="linux-cachyos-${kver}_bcachefs-${bver}"
gh release view "$tag" &>/dev/null && die "release $tag already exists"

msg "Verifying $n.iso"
(cd "$dir" && sha256sum -c "$n.iso.sha256")

rel="$dir/release-$tag"
rm -rf "$rel"; mkdir -p "$rel"
msg "Splitting into <2 GiB parts"
split -b 1900M -d -a 2 "$iso" "$rel/$n.iso.part"
cp "$dir/$n.iso.sha256" "$rel/"
cp "$pkgs" "$rel/"
parts=("$rel/$n.iso.part"*)
(cd "$rel" && sha256sum "${parts[@]##*/}" > "$n.parts.sha256")

# release notes from the package list
url="$(gh repo view --json url -q .url)"
up="$(awk '{print $2}' "$dir/$n.upstream.txt" 2>/dev/null || echo unknown)"
cat > "$rel/notes.md" <<EOF
CachyOS desktop live ISO (upstream [\`$up\`](https://github.com/CachyOS/CachyOS-Live-ISO/commit/$up)) with the bcachefs kernel module built in.

| | |
|---|---|
| linux-cachyos | $kver |
| linux-cachyos-lts | $(ver linux-cachyos-lts) |
| bcachefs (module + tools) | $bver |
| built | $(grep -oE '[0-9]{6}' <<<"$n" | tail -1) |

### Download
GitHub limits release files to 2 GiB, so the ISO is split into parts. Download all of them, then join and verify:

\`\`\`sh
sha256sum -c $n.parts.sha256
cat $n.iso.part* > $n.iso
sha256sum -c $n.iso.sha256
\`\`\`

The full package list is in \`$n.pkgs.txt\`. See the [README]($url#readme) for usage and rescue instructions.
EOF

msg "Creating release $tag"
files=("${parts[@]}" "$rel/$n.iso.sha256" "$rel/$n.parts.sha256")
files+=("$rel/$n.pkgs.txt")
gh release create "$tag" --target main \
    --title "$tag" --notes-file "$rel/notes.md" "${files[@]}"
rm -rf "$rel"
msg "Released $tag"
