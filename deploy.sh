#!/bin/zsh
# Deploy: rebuild and update the FDA-granted /Applications copy in place.
set -e; cd "$(dirname "$0")"; ./build.sh
# Clean replace: a ditto-merge over an old bundle can corrupt the signature,
# and an invalid signature makes TCC silently ignore the FDA grant.
rm -rf /Applications/AppleTree.app
ditto build/AppleTree.app /Applications/AppleTree.app
codesign --verify --strict /Applications/AppleTree.app
echo "==> Deployed to /Applications/AppleTree.app (signature verified)"
