#!/usr/bin/env sh
# Keeps the installed packages in .deps/ rather than a 111MB directory named after
# a runtime this project does not use.
#
# The name cannot go away entirely: Bun, Vite, esbuild and Rollup all resolve bare
# imports by walking up looking for a path segment literally called `node_modules`,
# and Vite's CommonJS interop only applies to files under one — point the store
# somewhere else without the link and the build fails on the first CJS package.
# So the store is .deps/ and `node_modules` is a five-byte symlink into it.
#
# Runs after an install, and moves a freshly created real directory into place.
set -e
cd "$(dirname "$0")/../frontend"

if [ -L node_modules ]; then
  mkdir -p .deps
  exit 0
fi

if [ -d node_modules ]; then
  rm -rf .deps
  mv node_modules .deps
fi
mkdir -p .deps
ln -s .deps node_modules
