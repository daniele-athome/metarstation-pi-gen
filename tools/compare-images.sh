#!/usr/bin/env bash
#
# compare-images.sh - Compare two pi-gen disk images partition by partition.
#
# For each selected partition the script produces its own output directory
# containing a text report (files only in A, only in B, differing files, with
# the overall percentage of differences) and, for differing text files, a
# unified .diff mirroring the original directory layout.
#
# Two entries are considered "different" when their content differs, or when
# type / permissions / ownership (uid, gid) / symlink target differ.
#
# Requires root: images are attached with losetup and mounted read-only.
#
set -euo pipefail

PROG=${0##*/}

# ---------------------------------------------------------------- defaults ---
PARTS="1,2"
OUTDIR="./image-diff-report"
MAX_DIFF_SIZE=$((1024 * 1024))   # per-file size limit for .diff generation
EXCLUDES=()
KEEP_WORK=0

# Enabled with -X: paths that change on every build / every boot.
VOLATILE_PATTERNS=(
	'tmp/*'
	'run/*'
	'var/run/*'
	'var/log/*'
	'var/cache/*'
	'var/tmp/*'
	'var/backups/*'
	'var/lib/systemd/random-seed'
	'var/lib/systemd/catalog/database'
	'var/lib/dbus/machine-id'
	'var/lib/dhcp/*'
	'var/lib/NetworkManager/*'
	'etc/machine-id'
	'etc/ssh/ssh_host_*'
	'etc/blkid.tab*'
	'lost+found'
	'lost+found/*'
)

usage() {
	cat <<EOF
Usage: $PROG [options] IMAGE_A IMAGE_B

Compare the first partitions of two pi-gen disk images (must run as root).

Options:
  -o DIR       output directory (default: $OUTDIR)
  -p LIST      comma separated partition numbers (default: $PARTS)
  -x PATTERN   exclude paths matching PATTERN (glob on the path relative to the
               partition root, '*' also matches '/'); repeatable
  -X           add a built-in exclusion list of volatile paths (logs, caches,
               machine-id, ssh host keys, ...)
  -s BYTES     do not generate a .diff for files larger than BYTES
               (default: $MAX_DIFF_SIZE, 0 = no limit)
  -k           keep the temporary work directory (for debugging)
  -h           this help

Output layout:
  OUTDIR/summary.txt
  OUTDIR/partition<N>/report.txt
  OUTDIR/partition<N>/diffs/<path>.diff
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# --------------------------------------------------------------- resources ---
MOUNTS=()
LOOPS=()
TMP=""
RET_DEV=""
RET_FSTYPE=""

cleanup() {
	local i
	if ((${#MOUNTS[@]})); then
		for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
			umount "${MOUNTS[i]}" 2>/dev/null || umount -l "${MOUNTS[i]}" 2>/dev/null || true
		done
	fi
	if ((${#LOOPS[@]})); then
		for ((i = ${#LOOPS[@]} - 1; i >= 0; i--)); do
			losetup -d "${LOOPS[i]}" 2>/dev/null || true
		done
	fi
	if [[ -n $TMP && -d $TMP && $KEEP_WORK -eq 0 ]]; then
		rm -rf "$TMP"
	elif [[ -n $TMP && $KEEP_WORK -eq 1 ]]; then
		log "work directory kept: $TMP"
	fi
}

check_deps() {
	local missing=() c
	for c in losetup mount umount blkid find sort awk diff sha256sum xargs stat grep; do
		command -v "$c" >/dev/null 2>&1 || missing+=("$c")
	done
	((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}"
}

# Sets RET_DEV. NOTE: these helpers must not be called in a command
# substitution, otherwise LOOPS/MOUNTS would be updated in a subshell only and
# cleanup would leak loop devices and mounts.
attach_image() {
	local img=$1 dev
	dev=$(losetup --find --show --read-only --partscan -- "$img") ||
		die "losetup failed on $img"
	LOOPS+=("$dev")
	command -v udevadm >/dev/null 2>&1 && udevadm settle >/dev/null 2>&1 || true
	RET_DEV=$dev
}

wait_part() {
	local part=$1 tries=${2:-50} i
	for ((i = 0; i < tries; i++)); do
		[[ -b $part ]] && return 0
		sleep 0.1
	done
	return 1
}

# partition_geometry <image> <index> -> "start_sector size_sectors sector_size"
partition_geometry() {
	local img=$1 idx=$2
	sfdisk -d -- "$img" 2>/dev/null | awk -v want="$idx" '
		/^sector-size:/ { ss = $2 }
		/start=/ {
			n++
			if (n != want) next
			s = z = ""
			if (match($0, /start=[ \t]*[0-9]+/)) { t = substr($0, RSTART, RLENGTH); sub(/start=[ \t]*/, "", t); s = t }
			if (match($0, /size=[ \t]*[0-9]+/))  { t = substr($0, RSTART, RLENGTH); sub(/size=[ \t]*/,  "", t); z = t }
			if (s != "" && z != "") print s, z, (ss ? ss : 512)
			exit
		}
	'
}

# part_device <image> <loop device> <index>; sets RET_DEV.
part_device() {
	local img=$1 loop=$2 idx=$3
	local node="${loop}p${idx}" geo start size ss dev
	if wait_part "$node" 20; then
		RET_DEV=$node
		return 0
	fi
	# Fallback: some environments (containers, kernels without loop partition
	# scanning) never expose /dev/loopXpN. Attach the partition range directly.
	command -v sfdisk >/dev/null 2>&1 ||
		die "no $node and sfdisk is not available to compute partition offsets"
	geo=$(partition_geometry "$img" "$idx")
	read -r start size ss <<< "${geo:-}"
	[[ -n ${start:-} && -n ${size:-} ]] || die "partition $idx not found in $img"
	dev=$(losetup --find --show --read-only \
		--offset $((start * ss)) --sizelimit $((size * ss)) -- "$img") ||
		die "losetup failed for partition $idx of $img"
	LOOPS+=("$dev")
	RET_DEV=$dev
}

# Sets RET_FSTYPE.
mount_part() {
	local part=$1 mnt=$2 fstype opts
	fstype=$(blkid -o value -s TYPE -- "$part" 2>/dev/null || true)
	opts="ro,nosuid,nodev"
	case "$fstype" in
		ext2 | ext3 | ext4) opts="$opts,noload" ;;                 # never touch the journal
		vfat | msdos) opts="$opts,umask=022,uid=0,gid=0" ;;        # deterministic metadata
	esac
	mkdir -p "$mnt"
	mount -o "$opts" -- "$part" "$mnt" || die "cannot mount $part (type='${fstype:-unknown}')"
	MOUNTS+=("$mnt")
	RET_FSTYPE=${fstype:-unknown}
}

# ---------------------------------------------------------------- inventory ---
exclude_filter() {
	if ((${#EXCLUDES[@]} == 0)); then
		cat
		return
	fi
	local pats
	pats=$(printf '%s\n' "${EXCLUDES[@]}")
	LC_ALL=C awk -F'\t' -v pats="$pats" '
		function glob2re(g,   r, i, c) {
			r = "^"
			for (i = 1; i <= length(g); i++) {
				c = substr(g, i, 1)
				if (c == "*")      r = r ".*"
				else if (c == "?") r = r "."
				else if (index(".^$+(){}|[]\\", c)) r = r "\\" c
				else               r = r c
			}
			return r "$"
		}
		BEGIN {
			n = split(pats, P, "\n")
			for (i = 1; i <= n; i++) if (P[i] != "") RE[++m] = glob2re(P[i])
		}
		{ for (i = 1; i <= m; i++) if ($1 ~ RE[i]) next; print }
	'
}

# inventory <root> <out.tsv>
# fields: path, type, mode, uid, gid, size, symlink target
inventory() {
	local root=$1 out=$2
	(cd "$root" && find . -mindepth 1 -printf '%P\t%y\t%m\t%U\t%G\t%s\t%l\n') |
		exclude_filter | LC_ALL=C sort > "$out"
}

# hash_side <root> <list of relative paths> <out.tsv>
hash_side() {
	local root=$1 list=$2 out=$3
	: > "$out"
	[[ -s $list ]] || return 0
	(cd "$root" && tr '\n' '\0' < "$list" | xargs -0 -r -n 500 sha256sum --) |
		awk '
			{
				line = $0; esc = 0
				if (substr(line, 1, 1) == "\\") { line = substr(line, 2); esc = 1 }
				h = substr(line, 1, 64)
				p = substr(line, 67)
				if (esc) gsub(/\\\\/, "\\", p)
				print p "\t" h
			}
		' > "$out"
}

is_text() {
	# empty files count as text; grep -I flags binary content
	[[ -s $1 ]] || return 0
	LC_ALL=C grep -qI -e '' -- "$1" 2>/dev/null
}

# ------------------------------------------------------------ the real work ---
# compare_partition <index> <mount A> <mount B> <fstype A> <fstype B> <outdir>
compare_partition() {
	local idx=$1 ma=$2 mb=$3 fta=$4 ftb=$5 od=$6
	local wd="$TMP/work$idx"
	mkdir -p "$wd" "$od/diffs"

	log "partition $idx: building inventories"
	inventory "$ma" "$wd/a.tsv"
	inventory "$mb" "$wd/b.tsv"

	: > "$wd/only_a.raw"; : > "$wd/only_b.raw"; : > "$wd/common.tsv"
	LC_ALL=C awk -F'\t' -v OFS='\t' \
		-v oa="$wd/only_a.raw" -v ob="$wd/only_b.raw" -v cm="$wd/common.tsv" '
		NR == FNR {
			t[$1] = $2; m[$1] = $3; u[$1] = $4; g[$1] = $5; s[$1] = $6; l[$1] = $7
			seen[$1] = 1
			next
		}
		{
			p = $1
			if (!(p in seen)) { print p > ob; next }
			r = ""
			if (t[p] != $2) r = r "type,"
			else {
				if (m[p] != $3) r = r "mode,"
				if (u[p] != $4 || g[p] != $5) r = r "owner,"
				if ($2 == "l" && l[p] != $7) r = r "link,"
			}
			sub(/,$/, "", r)
			print p, r, $2, s[p], $6 > cm
			delete seen[p]
		}
		END { for (p in seen) print p > oa }
	' "$wd/a.tsv" "$wd/b.tsv"

	LC_ALL=C sort "$wd/only_a.raw" > "$wd/only_a.lst"
	LC_ALL=C sort "$wd/only_b.raw" > "$wd/only_b.lst"

	log "partition $idx: comparing contents"
	awk -F'\t' '$3 == "f" && $4 == $5 { print $1 }' "$wd/common.tsv" > "$wd/cand.lst"
	awk -F'\t' '$3 == "f" && $4 != $5 { print $1 }' "$wd/common.tsv" > "$wd/size_diff.lst"

	hash_side "$ma" "$wd/cand.lst" "$wd/hash_a.tsv"
	hash_side "$mb" "$wd/cand.lst" "$wd/hash_b.tsv"
	LC_ALL=C awk -F'\t' '
		NR == FNR { h[$1] = $2; next }
		($1 in h) && h[$1] != $2 { print $1 }
	' "$wd/hash_a.tsv" "$wd/hash_b.tsv" > "$wd/hash_diff.lst"

	cat "$wd/size_diff.lst" "$wd/hash_diff.lst" | LC_ALL=C sort -u > "$wd/content_diff.lst"

	# merge metadata differences and content differences into one list
	awk -F'\t' '$2 != "" { print "M\t" $1 "\t" $2 }' "$wd/common.tsv" > "$wd/merge.in"
	awk '{ print "C\t" $0 }' "$wd/content_diff.lst" >> "$wd/merge.in"
	LC_ALL=C awk -F'\t' -v OFS='\t' '
		$1 == "M" { meta[$2] = $3; paths[$2] = 1; next }
		$1 == "C" { cont[$2] = 1;  paths[$2] = 1; next }
		END {
			for (p in paths) {
				r = (p in meta) ? meta[p] : ""
				if (p in cont) r = (r == "") ? "content" : r ",content"
				print p, r
			}
		}
	' "$wd/merge.in" | LC_ALL=C sort > "$wd/different.tsv"

	# ---- diffs for text files ------------------------------------------------
	log "partition $idx: generating .diff files"
	local n_diff_files=0 n_skip_big=0 n_skip_bin=0
	local p fa fb sza szb target rc
	while IFS= read -r p; do
		fa="$ma/$p"; fb="$mb/$p"
		[[ -f $fa && -f $fb ]] || continue
		sza=$(stat -c %s -- "$fa"); szb=$(stat -c %s -- "$fb")
		if ((MAX_DIFF_SIZE > 0)) && { ((sza > MAX_DIFF_SIZE)) || ((szb > MAX_DIFF_SIZE)); }; then
			n_skip_big=$((n_skip_big + 1)); continue
		fi
		if ! is_text "$fa" || ! is_text "$fb"; then
			n_skip_bin=$((n_skip_bin + 1)); continue
		fi
		target="$od/diffs/$p.diff"
		mkdir -p "$(dirname "$target")"
		set +e
		diff -u --label "a/$p" --label "b/$p" -- "$fa" "$fb" > "$target"
		rc=$?
		set -e
		if ((rc > 1)); then rm -f "$target"; continue; fi
		n_diff_files=$((n_diff_files + 1))
	done < "$wd/content_diff.lst"

	# ---- numbers -------------------------------------------------------------
	local n_a n_b n_only_a n_only_b n_common n_different n_content n_meta_only union total_diff pct
	n_a=$(wc -l < "$wd/a.tsv")
	n_b=$(wc -l < "$wd/b.tsv")
	n_only_a=$(wc -l < "$wd/only_a.lst")
	n_only_b=$(wc -l < "$wd/only_b.lst")
	n_common=$(wc -l < "$wd/common.tsv")
	n_different=$(wc -l < "$wd/different.tsv")
	n_content=$(wc -l < "$wd/content_diff.lst")
	n_meta_only=$((n_different - n_content))
	union=$((n_only_a + n_only_b + n_common))
	total_diff=$((n_only_a + n_only_b + n_different))
	pct=$(awk -v d="$total_diff" -v u="$union" 'BEGIN { printf "%.4f", (u ? d * 100 / u : 0) }')

	# ---- report --------------------------------------------------------------
	local rep="$od/report.txt"
	{
		printf '================================================================\n'
		printf ' Partition %s\n' "$idx"
		printf '================================================================\n'
		printf 'Image A          : %s\n' "$IMG_A"
		printf 'Image B          : %s\n' "$IMG_B"
		printf 'Filesystem A / B : %s / %s\n' "$fta" "$ftb"
		printf 'Generated        : %s\n' "$(date -Is)"
		if ((${#EXCLUDES[@]})); then
			printf 'Exclusions       : %s\n' "${EXCLUDES[*]}"
		else
			printf 'Exclusions       : (none)\n'
		fi
		printf '\n'
		printf -- '--- Summary ----------------------------------------------------\n'
		printf 'Entries in A            : %d\n' "$n_a"
		printf 'Entries in B            : %d\n' "$n_b"
		printf 'Union of entries        : %d\n' "$union"
		printf 'Only in A               : %d\n' "$n_only_a"
		printf 'Only in B               : %d\n' "$n_only_b"
		printf 'Present in both         : %d\n' "$n_common"
		printf '  different             : %d\n' "$n_different"
		printf '    content differs     : %d\n' "$n_content"
		printf '    metadata only       : %d\n' "$n_meta_only"
		printf '  identical             : %d\n' "$((n_common - n_different))"
		printf 'TOTAL DIFFERENCES       : %d / %d = %s %%\n' "$total_diff" "$union" "$pct"
		printf '\n'
		printf 'Generated .diff files   : %d\n' "$n_diff_files"
		printf '  skipped (binary)      : %d\n' "$n_skip_bin"
		printf '  skipped (size limit)  : %d\n' "$n_skip_big"
		printf '\n'
		printf 'Difference criteria: content (sha256), type, mode, uid/gid, symlink target.\n'
		printf 'Not compared: timestamps, xattrs, ACLs, hard-link topology, device major/minor.\n'
		printf '\n'
		printf -- '--- Only in A (%d) ---------------------------------------------\n' "$n_only_a"
		cat "$wd/only_a.lst"
		printf -- '\n--- Only in B (%d) ---------------------------------------------\n' "$n_only_b"
		cat "$wd/only_b.lst"
		printf -- '\n--- Different (%d) ---------------------------------------------\n' "$n_different"
		awk -F'\t' '{ printf "%-70s [%s]\n", $1, $2 }' "$wd/different.tsv"
	} > "$rep"

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$idx" "$union" "$n_only_a" "$n_only_b" "$n_different" "$total_diff" "$pct" \
		>> "$TMP/summary.tsv"

	log "partition $idx: $total_diff/$union differences ($pct %) -> $rep"
}

main() {
	local opt
	while getopts ":o:p:x:Xs:kh" opt; do
		case $opt in
			o) OUTDIR=$OPTARG ;;
			p) PARTS=$OPTARG ;;
			x) EXCLUDES+=("$OPTARG") ;;
			X) EXCLUDES+=("${VOLATILE_PATTERNS[@]}") ;;
			s) MAX_DIFF_SIZE=$OPTARG ;;
			k) KEEP_WORK=1 ;;
			h) usage; exit 0 ;;
			:) die "option -$OPTARG requires an argument" ;;
			\?) die "unknown option -$OPTARG (try -h)" ;;
		esac
	done
	shift $((OPTIND - 1))
	[[ $# -eq 2 ]] || { usage >&2; exit 2; }

	IMG_A=$(readlink -f -- "$1")
	IMG_B=$(readlink -f -- "$2")
	[[ -f $IMG_A ]] || die "not a file: $1"
	[[ -f $IMG_B ]] || die "not a file: $2"
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root (losetup/mount)"
	check_deps

	mkdir -p "$OUTDIR"
	OUTDIR=$(readlink -f -- "$OUTDIR")
	TMP=$(mktemp -d -t compare-images.XXXXXX)
	trap cleanup EXIT
	: > "$TMP/summary.tsv"

	local loop_a loop_b
	attach_image "$IMG_A"; loop_a=$RET_DEV
	attach_image "$IMG_B"; loop_b=$RET_DEV
	log "attached: $IMG_A -> $loop_a, $IMG_B -> $loop_b"

	local idx pa pb ma mb fta ftb od
	IFS=',' read -r -a PART_LIST <<< "$PARTS"
	for idx in "${PART_LIST[@]}"; do
		[[ $idx =~ ^[0-9]+$ ]] || die "invalid partition number: $idx"
		part_device "$IMG_A" "$loop_a" "$idx"; pa=$RET_DEV
		part_device "$IMG_B" "$loop_b" "$idx"; pb=$RET_DEV
		ma="$TMP/mnt/a$idx"; mb="$TMP/mnt/b$idx"
		mount_part "$pa" "$ma"; fta=$RET_FSTYPE
		mount_part "$pb" "$mb"; ftb=$RET_FSTYPE
		od="$OUTDIR/partition$idx"
		mkdir -p "$od"
		compare_partition "$idx" "$ma" "$mb" "$fta" "$ftb" "$od"
	done

	{
		printf 'Comparison of:\n  A = %s\n  B = %s\nGenerated: %s\n\n' \
			"$IMG_A" "$IMG_B" "$(date -Is)"
		printf '%-5s %10s %10s %10s %10s %10s %8s\n' \
			PART ENTRIES ONLY_A ONLY_B DIFFERENT TOTALDIFF 'PCT%'
		awk -F'\t' '{ printf "%-5s %10s %10s %10s %10s %10s %8s\n", $1, $2, $3, $4, $5, $6, $7 }' \
			"$TMP/summary.tsv"
		printf '\nDetails in %s/partition<N>/report.txt\n' "$OUTDIR"
	} > "$OUTDIR/summary.txt"

	cat "$OUTDIR/summary.txt"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
