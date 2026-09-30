#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
mkdir -p "$project_dir/build"
cd "$project_dir/Extensions/warden-terminal"
npx --yes @vscode/vsce package --allow-missing-repository --skip-license --out "$project_dir/build/warden-terminal.vsix"
code --install-extension "$project_dir/build/warden-terminal.vsix" --force
