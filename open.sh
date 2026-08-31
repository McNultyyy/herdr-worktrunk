#!/usr/bin/env bash
# Shared entrypoint for the plugin's workspace actions. Resolves the repo to run
# in, then opens ENTRYPOINT with the configured picker placement.
#
# Plugin panes default their cwd to the plugin root, so the workspace's repo (from
# the injected context JSON) has to be passed explicitly. Otherwise `wt` runs in
# the plugin dir, not the repo you're in.

entrypoint=${1:?usage: open.sh <entrypoint>}

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"

cwd=$(jq -r '.workspace_cwd // .focused_pane_cwd' <<<"$HERDR_PLUGIN_CONTEXT_JSON")
herdr=${HERDR_BIN_PATH:-herdr}

# A link handler invokes the action with the clicked URL in the same context, so
# the issue/PR number is lifted out of it here and handed to the picker, which
# then skips its list entirely. Absent for a menu or keybinding invocation.
clicked_url=$(jq -r '.clicked_url // empty' <<<"$HERDR_PLUGIN_CONTEXT_JSON")
prefill=""
if [[ $clicked_url =~ /(issues|pull|merge_requests)/([0-9]+) ]]; then
  prefill=${BASH_REMATCH[2]}
fi

args=(plugin pane open
  --plugin "${HERDR_PLUGIN_ID:-worktrunk}"
  --entrypoint "$entrypoint"
  --cwd "$cwd"
  --focus)

if [[ $(worktrunk_picker_placement) == popup ]]; then
  args+=(--placement popup)

  width=$(worktrunk_popup_dimension popup_width)
  height=$(worktrunk_popup_dimension popup_height)
  [[ -n $width ]] && args+=(--width "$width")
  [[ -n $height ]] && args+=(--height "$height")

  # A popup is session-modal and belongs to no pane, so herdr injects none of
  # HERDR_WORKSPACE_ID/HERDR_TAB_ID/HERDR_PANE_ID into it. The picker opens the
  # checkout in a workspace, so hand it the one the action was invoked from.
  [[ -n ${HERDR_WORKSPACE_ID:-} ]] && args+=(--env "HERDR_WORKSPACE_ID=$HERDR_WORKSPACE_ID")
else
  args+=(--placement split --direction down)
fi

[[ -n $prefill ]] && args+=(--env "WT_PICKER_PREFILL=$prefill")

exec "$herdr" "${args[@]}"
