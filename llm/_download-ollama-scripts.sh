#!/bin/bash

set -o pipefail     # propagate pipeline errors
#set -eo pipefail    # fail fast, propagate pipeline errors
#set -euo pipefail   # fail fast, fail on unset vars, propagate pipeline errors


REMOTE_BASE="https://raw.githubusercontent.com/JesseNaranjo/system-setup/refs/heads/main/llm"
FILES=( "ollama-remote.sh" "ollama-screen.sh" )

LINE_COLOR="\033[0;33m"
CODE_COLOR="\033[40m"
RESET_COLOR="\033[0m"


if [[ $scriptUpdated -eq 0 || -z $scriptUpdated ]]; then
	SCRIPT_FILE="_download-ollama-scripts.sh"
	TEMP_SCRIPT_FILE="$(mktemp)"
	trap 'rm -f "${TEMP_SCRIPT_FILE}"' RETURN     # ensure cleanup even on exit/interrupt

	# -H header, -o file path, -f fail-on-HTTP-error, -s silent, -S show errors, -L follow redirects
	curl -H 'Cache-Control: no-cache' -o "${TEMP_SCRIPT_FILE}" -fsSL "${REMOTE_BASE}/${SCRIPT_FILE}"

	echo -e "${LINE_COLOR}╭───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╮${RESET_COLOR}${CODE_COLOR}"
	cat "${TEMP_SCRIPT_FILE}"

	if diff -u "${fname}" "${tmp}" > /dev/null 2>&1; then
		echo -e "${RESET_COLOR}${LINE_COLOR}╰────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╯${RESET_COLOR}"
	else
		echo -e "${RESET_COLOR}${LINE_COLOR}╰────────────────────────────────────────────────── Δ detected in ${SCRIPT_FILE} ──────────────────────────────────────────────────╮${RESET_COLOR}"
		diff -u --color "${BASH_SOURCE[0]}" "${TEMP_SCRIPT_FILE}" || true
		echo -e "${LINE_COLOR}╰───────────────────────────────────────────────────────── ${SCRIPT_FILE} ─────────────────────────────────────────────────────────╯${RESET_COLOR}"; echo

		read -p "→ Overwrite and run ${SCRIPT_FILE}?: [y/N] " continueExec
		echo

		if [[ $continueExec == [Yy] ]]; then
			chmod +x $TEMP_SCRIPT_FILE
			export scriptUpdated=1
			$TEMP_SCRIPT_FILE
			unset scriptUpdated
			mv $TEMP_SCRIPT_FILE ${BASH_SOURCE[0]}
		else
			rm -f $TEMP_SCRIPT_FILE
		fi

		exit 0
	fi
fi


for fname in "${FILES[@]}"; do
	tmp="$(mktemp)"                 # secure, race-free temp file :contentReference[oaicite:0]{index=0}
	trap 'rm -f "${tmp}"' RETURN    # ensure cleanup even on exit/interrupt

	echo "▶ Fetching ${REMOTE_BASE}/${fname}..."
	# -H header, -o file path, -f fail-on-HTTP-error, -s silent, -S show errors, -L follow redirects
	if ! curl -H 'Cache-Control: no-cache' -o "${tmp}" -fsSL "${REMOTE_BASE}/${fname}"; then
		echo "  ✖ Download failed — skipping $fname"
		continue
	fi

	if diff -u "${fname}" "${tmp}" > /dev/null 2>&1; then
		echo "  ✓ ${fname} is already up-to-date"
	else
		echo; echo -e "${LINE_COLOR}╭────────────────────────────────────────────────── Δ detected in ${fname} ──────────────────────────────────────────────────╮${RESET_COLOR}"
		diff -u --color "${fname}" "${tmp}" || true
		echo -e "${LINE_COLOR}╰───────────────────────────────────────────────────────── ${fname} ─────────────────────────────────────────────────────────╯${RESET_COLOR}"

		read -rp "→ Overwrite local ${fname} with remote copy? [y/N] " continueOverwrite
		if [[ $continueOverwrite =~ ^[Yy]$ ]]; then
			chmod +x $tmp
			mv "${tmp}" "${fname}"
			echo "  ↺ Replaced ${fname}"
		else
			echo "  ◼ Skipped ${fname}"
			rm -f "${tmp}"
		fi
	fi
done
