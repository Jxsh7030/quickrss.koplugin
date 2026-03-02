#!/bin/bash

# Define your plugin name
PLUGIN_NAME="quickrss.koplugin"

# Define paths
SOURCE_DIR="./${PLUGIN_NAME}"
TARGET_DIR="$HOME/.config/koreader/plugins/${PLUGIN_NAME}"

# Create the target directory if it doesn't exist
mkdir -p "$TARGET_DIR"

# Sync the files cleanly (removes old files in target if deleted in source)
rsync -av --delete "$SOURCE_DIR/" "$TARGET_DIR/"

echo "Successfully synced ${PLUGIN_NAME} to local KOReader"
# Optional: If you want to automatically kill a running local KOReader to restart it
pkill -f koreader
koreader
