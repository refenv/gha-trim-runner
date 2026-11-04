#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Make room on a GitHub-hosted runner for the job's container, by removing the tooling
# the runner image preinstalls from the host underneath it
#
# Only in a container job: there the job brings its own tooling in its image, and the
# host needs only to start the container and run GitHub's runner. A job on the runner
# itself may be using that tooling, so it is left alone.
#
# Inputs, from the environment:
#   TRIM_NEED_GIB  trim, flavour by flavour, only until the runner's disk has this many
#                  GiB free;
#                   empty trims always
#   TRIM_EXTRA     more paths on the host to remove, one per line
#   TRIM_<FLAVOUR> 'false' keeps that flavour of tooling, such as TRIM_HASKELL
#   TRIM_DRY_RUN   'true' lists what would be removed, and removes nothing
#   TRIM_RUNNER_ENVIRONMENT  'github-hosted' or 'self-hosted', from the runner context
#   TRIM_RUNNER_NAME         the runner's name, from the runner context
#   TRIM_CONTAINER_ID        the job's container, from the job context
#
# The tooling is on the host, so it is removed by a container of the job's own image
# with the host's root mounted, started through the Docker Engine API on the socket
# GitHub gives a container job; nothing more is pulled. What each flavour freed is the free space of
# the host's root before and after removing it.
set -euo pipefail

# The runner's disk, where its tooling is; in a container job, / is the container's
# overlay, which is on that disk too
TRIM_PATH=/

: "${TRIM_NEED_GIB:=}" "${TRIM_EXTRA:=}" "${TRIM_DRY_RUN:=false}"
: "${TRIM_RUNNER_ENVIRONMENT:=}" "${TRIM_RUNNER_NAME:=}" "${TRIM_CONTAINER_ID:=}"

# The tooling, by flavour, in the order it is removed: the largest first, so a need is
# met by removing the fewest
flavours=(android dotnet haskell swift java codeql powershell microsoft chromium)
declare -A flavour_paths=(
	[android]="/usr/local/lib/android"
	[dotnet]="/usr/share/dotnet"
	[haskell]="/opt/ghc /usr/local/.ghcup"
	[swift]="/usr/share/swift"
	[powershell]="/usr/local/share/powershell"
	[chromium]="/usr/local/share/chromium"
	[java]="/usr/lib/jvm"
	[codeql]="/opt/hostedtoolcache/CodeQL"
	[microsoft]="/opt/microsoft"
)

fail() {
	echo "::error title=gha-trim-runner::$1"
	exit 1
}

# What the job's container must provide, here and in the helper started from the same
# image; checked first, so a missing one is named rather than failing halfway
tools=(curl awk grep df cut tr head mktemp date sh rm)
missing=()
for tool in "${tools[@]}"; do
	if ! command -v "$tool" > /dev/null 2>&1; then
		missing+=("$tool")
	fi
done
if [ "${#missing[@]}" -gt 0 ]; then
	fail "the job's container image lacks ${missing[*]}; it needs bash and ${tools[*]}"
fi

if [ -n "$TRIM_NEED_GIB" ] && ! [[ "$TRIM_NEED_GIB" =~ ^[0-9]+$ ]]; then
	fail "need-gib must be a whole number of GiB, not '${TRIM_NEED_GIB}'"
fi

# An extra path is absolute, below the root, and taken literally: whitespace, globs
# and '..' are refused, as the removal splits on whitespace and must not escape
extra=()
while IFS= read -r line; do
	if [ -z "$line" ]; then
		continue
	fi
	if [[ "$line" != /?* ]] || [[ "$line" =~ [[:space:]*?\[] ]] || [[ "$line" == *..* ]] \
		|| [[ "$line" =~ ^/+$ ]]; then
		fail "extra path '${line}' must be absolute, below /, and without whitespace, globs or '..'"
	fi
	extra+=("$line")
done <<< "$TRIM_EXTRA"
if [ "${#extra[@]}" -gt 0 ]; then
	flavours+=(extra)
	flavour_paths[extra]="${extra[*]}"
fi

removing=()
kept=()
for flavour in "${flavours[@]}"; do
	var="TRIM_${flavour^^}"
	if [ "$flavour" = "extra" ] || [ "${!var:-true}" != "false" ]; then
		removing+=("$flavour")
	else
		kept+=("$flavour")
	fi
done

kib() {
	df -Pk "$1" | awk 'NR == 2 { print $4 }'
}

gib() {
	awk -v k="$1" 'BEGIN { printf "%.1f", k / 1048576 }'
}

output() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		echo "$1=$2" >> "$GITHUB_OUTPUT"
	fi
}

summary() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		echo "$1" >> "$GITHUB_STEP_SUMMARY"
	fi
}

cloud() {
	case "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" in
	*Amazon*) echo "AWS" ;;
	*Microsoft*) echo "Azure" ;;
	*Google*) echo "GCP" ;;
	*) echo "an unknown cloud" ;;
	esac
}

where="the host underneath this container job"
removed=()
summary_host=""

before=$(kib "$TRIM_PATH")
size=$(df -Pk "$TRIM_PATH" | awk 'NR == 2 { print $2 }')
output avail-gib-before "$(gib "$before")"

echo "gha-trim-runner on $(cloud)${ImageOS:+, ${ImageOS} ${ImageVersion:-}}"
echo "  ${TRIM_PATH}: $(gib "$before") GiB free of $(gib "$size") GiB${TRIM_NEED_GIB:+, needs ${TRIM_NEED_GIB} GiB}"

# Record the outputs and the step summary's totals
finish() {
	local after=$1 trimmed=$2 note=$3
	output avail-gib-after "$(gib "$after")"
	output trimmed "$trimmed"
	output removed "${removed[*]}"
	summary "### gha-trim-runner"
	summary ""
	summary "$note${summary_host:+ Host: ${summary_host}.}"
	summary ""
	summary "| | Free at \`${TRIM_PATH}\` |"
	summary "| --- | ---: |"
	summary "| Before | $(gib "$before") GiB |"
	summary "| After | $(gib "$after") GiB |"
	summary "| Freed | $(gib $((after - before))) GiB |"
}

# Only a GitHub-hosted runner, used for one job and thrown away, is trimmed; anywhere
# else the tooling is someone's, and other jobs may need it. GitHub says which, and
# names its own runners; the removal checks the machine as well, see remove_script
hosted=true
if [ "$TRIM_RUNNER_ENVIRONMENT" != "github-hosted" ]; then
	hosted=false
	why="runner.environment is '${TRIM_RUNNER_ENVIRONMENT:-unset}'"
elif ! [[ "$TRIM_RUNNER_NAME" =~ ^GitHub\ Actions\ [0-9]+$ ]]; then
	hosted=false
	why="runner.name '${TRIM_RUNNER_NAME:-unset}' is not one GitHub gives its runners"
fi
if [ "$hosted" = "true" ] && [ ! -f /.dockerenv ]; then
	hosted=false
	why="the job runs on the runner, not in a container, and may use its tooling"
fi
if [ "$hosted" = "false" ] && [ "$TRIM_DRY_RUN" != "true" ]; then
	echo "::notice title=gha-trim-runner::nothing trimmed, as ${why}"
	finish "$before" false "Nothing was trimmed, as ${why}."
	exit 0
fi

# The host's Docker Engine, through the socket GitHub mounts into a container job; its
# API, by curl, rather than a docker client, which the job's image may lack or have
# as another engine's, such as podman's
engine() {
	local method=$1 path=$2 body=${3:-}
	if [ -n "$body" ]; then
		curl -sf --unix-socket /var/run/docker.sock -X "$method" \
			-H "Content-Type: application/json" -d "$body" "http://engine${path}"
	else
		curl -sf --unix-socket /var/run/docker.sock -X "$method" "http://engine${path}"
	fi
}

json_string() {
	local s=$1
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/\\n}
	s=${s//$'\t'/\\t}
	printf '"%s"' "$s"
}

# Run a script in a container of the job's own image, with the host's root at /host,
# printing what it prints; returns its exit status
host_run() {
	local script=$1 image cmd arg helper
	shift
	image=$(engine GET "/containers/${TRIM_CONTAINER_ID}/json" \
		| grep -o '"Image":"sha256:[0-9a-f]*"' | head -n1 | cut -d'"' -f4) || return 1
	[ -n "$image" ] || return 1
	cmd="[\"sh\",\"-c\",$(json_string "$script"),\"sh\""
	for arg in "$@"; do
		cmd+=",$(json_string "$arg")"
	done
	cmd+="]"
	helper=$(engine POST /containers/create \
		"{\"Image\":\"${image}\",\"Entrypoint\":[],\"Cmd\":${cmd},\"Tty\":true,\"HostConfig\":{\"Binds\":[\"/:/host\"]}}" \
		| grep -o '"Id":"[0-9a-f]*"' | cut -d'"' -f4) || return 1
	[ -n "$helper" ] || return 1
	local code=1
	if engine POST "/containers/${helper}/start" > /dev/null; then
		code=$(engine POST "/containers/${helper}/wait" | grep -o '"StatusCode":[0-9]*' | cut -d: -f2)
		engine GET "/containers/${helper}/logs?stdout=1&stderr=1" | tr -d '\r'
	fi
	engine DELETE "/containers/${helper}?force=1" > /dev/null || true
	return "${code:-1}"
}

# What the host is, for the log: the runner image, its kernel and Docker Engine
# shellcheck disable=SC2016 # expanded by the shell that runs it
probe='
grep -E "^Image(OS|Version)=" /host/etc/environment 2>/dev/null | cut -d= -f2 | tr "\n" " "
echo "kernel $(uname -r)"
'
reachable=false
if [ -n "$TRIM_CONTAINER_ID" ] && engine GET /version > /dev/null 2>&1; then
	reachable=true
	host=$(host_run "$probe" || true)
	engine_version=$(engine GET /version | grep -o '"Version":"[^"]*"' | head -n1 | cut -d'"' -f4)
	echo "  Host: ${host:-unknown image}, Docker Engine ${engine_version:-unknown}, runner ${TRIM_RUNNER_NAME}"
	summary_host="${host:-unknown image}, Docker Engine ${engine_version:-unknown}"
fi

if [ -n "$TRIM_NEED_GIB" ] && [ "$before" -ge $((TRIM_NEED_GIB * 1048576)) ]; then
	echo "  Enough room; nothing trimmed"
	finish "$before" false "On $(cloud), \`${TRIM_PATH}\` had enough room, so nothing was trimmed."
	exit 0
fi

if [ "${#removing[@]}" -eq 0 ]; then
	echo "  Every flavour is kept; nothing trimmed"
	finish "$before" false "Every flavour was kept, so nothing was trimmed."
	exit 0
fi

if [ "$TRIM_DRY_RUN" = "true" ]; then
	echo "  Dry run; would remove from ${where}:"
	for flavour in "${removing[@]}"; do
		printf '    %-11s %s\n' "$flavour" "${flavour_paths[$flavour]}"
	done
	if [ "${#kept[@]}" -gt 0 ]; then
		echo "  Kept: ${kept[*]}"
	fi
	finish "$before" false "Dry run on $(cloud); nothing was removed."
	exit 0
fi

# Removes each flavour, printing 'flavour freed-KiB', measured on the root it lives on
# shellcheck disable=SC2016 # expanded by the shell that runs it
remove_script='
set -f
root=$1; need=$2; shift 2
# The machine itself must be one of GitHub'"'"'s runner images, with its runner user
if ! grep -q "^ImageOS=" "$root/etc/environment" 2>/dev/null \
	|| ! grep -q "^ImageVersion=" "$root/etc/environment" 2>/dev/null \
	|| [ ! -d "$root/home/runner" ]; then
	echo "not a GitHub runner image: no ImageOS and ImageVersion in /etc/environment, or no /home/runner" >&2
	exit 3
fi
free() { df -Pk "${root:-/}" | awk "NR == 2 { print \$4 }"; }
while [ $# -gt 0 ]; do
	flavour=$1; paths=$2; shift 2
	start=$(free)
	if [ "$need" -gt 0 ] && [ "$start" -ge "$need" ]; then
		break
	fi
	for path in $paths; do
		case "$path" in /?*) rm -rf "$root$path" ;; *) echo "refusing $path" >&2 ;; esac
	done
	echo "$flavour $(( $(free) - start ))"
done
'

need_kib=$((${TRIM_NEED_GIB:-0} * 1048576))
args=()
for flavour in "${removing[@]}"; do
	args+=("$flavour" "${flavour_paths[$flavour]}")
done

if [ "$reachable" != "true" ]; then
	echo "::warning::cannot reach the host's Docker Engine through /var/run/docker.sock; nothing trimmed"
	finish "$before" false "The host's Docker Engine was not reachable, so nothing was trimmed."
	exit 0
fi


echo "  Removing from ${where}:"
rows=()
removed=()
started=$(date +%s)
status=0
log=$(mktemp)
host_run "$remove_script" /host "$need_kib" "${args[@]}" > "$log" || status=$?
grep -v '^[a-z]* -\?[0-9]*$' "$log" >&2 || true
while read -r flavour freed; do
	printf '    %-11s %7s GiB  %s\n' "$flavour" "$(gib "$freed")" "${flavour_paths[$flavour]}"
	removed+=("$flavour")
	rows+=("| ${flavour} | $(gib "$freed") GiB | \`${flavour_paths[$flavour]// /\` \`}\` |")
done < <(grep '^[a-z]* -\?[0-9]*$' "$log")
rm -f "$log"
elapsed=$(($(date +%s) - started))
if [ "$status" -ne 0 ]; then
	echo "::warning title=gha-trim-runner::the removal failed with status ${status}, after ${#rows[@]} of ${#removing[@]} flavours"
fi
if [ "${#kept[@]}" -gt 0 ]; then
	echo "  Kept: ${kept[*]}"
fi
spared=("${removing[@]:${#rows[@]}}")
if [ "$status" -eq 0 ] && [ "${#spared[@]}" -gt 0 ]; then
	echo "  Spared, as the need was met: ${spared[*]}"
fi

after=$(kib "$TRIM_PATH")
freed=$((after - before))
echo "  ${TRIM_PATH}: $(gib "$before") GiB -> $(gib "$after") GiB free, $(gib "$freed") GiB freed in ${elapsed}s"
echo "::notice title=gha-trim-runner::${TRIM_PATH}: $(gib "$before") -> $(gib "$after") GiB free, $(gib "$freed") GiB freed on $(cloud)"

trimmed=false
if [ "${#rows[@]}" -gt 0 ]; then
	trimmed=true
fi
finish "$after" "$trimmed" "On $(cloud), trimmed from ${where} in ${elapsed}s."
summary ""
summary "| Flavour | Freed | Paths |"
summary "| --- | ---: | --- |"
for row in "${rows[@]}"; do
	summary "$row"
done
if [ "${#kept[@]}" -gt 0 ]; then
	summary ""
	summary "Kept: ${kept[*]}"
fi
if [ "$status" -eq 0 ] && [ "${#spared[@]}" -gt 0 ]; then
	summary ""
	summary "Spared, as the need was met: ${spared[*]}"
fi

if [ -n "$TRIM_NEED_GIB" ] && [ "$after" -lt $((TRIM_NEED_GIB * 1048576)) ]; then
	echo "::warning::${TRIM_PATH} has $(gib "$after") GiB free, less than the ${TRIM_NEED_GIB} GiB asked for"
fi
