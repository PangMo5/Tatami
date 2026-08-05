#!/usr/bin/env bash
# Swap the demo workspaces in/out for recording while keeping YOUR real
# settings. `apply` backs up your config, then writes your settings followed by
# the controlled demo Shared Apps + profiles from demo-workspaces.toml.
# `restore` puts your config back.
# Tatami hot-reloads config.toml, so workspaces switch live — no relaunch.
set -euo pipefail
cd "$(dirname "$0")"

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/tatami/config.toml"
BACKUP="${CFG}.pre-demo-backup"

case "${1:-}" in
  apply)
    mkdir -p "$(dirname "$CFG")"
    if [[ -f "$CFG" && ! -f "$BACKUP" ]]; then
      cp "$CFG" "$BACKUP"
      echo "Backed up your config → $BACKUP"
    fi
    # Source of your real settings: the backup (your untouched config).
    local_src="$BACKUP"
    [[ -f "$local_src" ]] || local_src="$CFG"
    {
      awk '/^\[\[(sharedApps|floatingApps|profiles)\]\]/{exit} {print}' "$local_src"
      echo
      cat demo-workspaces.toml
    } > "$CFG"
    echo "Applied: your settings kept, demo Shared Apps + workspaces swapped in."
    echo "Restore: $0 restore"
    ;;
  restore)
    if [[ -f "$BACKUP" ]]; then
      mv "$BACKUP" "$CFG"
      echo "Restored your config from backup."
    else
      echo "No backup at $BACKUP — nothing to restore."
    fi
    ;;
  *)
    echo "Usage: $0 apply|restore"
    exit 1
    ;;
esac
