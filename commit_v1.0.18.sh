#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Adding files..."
git add cli/__init__.py \
  main/pipelines/container/dockerfile.lr \
  main/pipelines/container/dockerfile.sr

echo "Committing..."
git commit -m "fix: Add required Perl modules for Krona tools

- Added libxml-simple-perl, libjson-perl, liblist-moreutils-perl to runtime
- Added explicit Krona tool symlinks to LR dockerfile
- Both LR and SR images now have ktImportTaxonomy, ktImportBLAST, ktImportXML
- Fixes 'command not found' error for Krona tools

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"

echo "Tagging..."
git tag -a v1.0.18 -m "Release v1.0.18 - Fix Krona Perl dependencies"

echo "Pushing to origin..."
git push origin main
git push origin v1.0.18

echo "Done! Version 1.0.18 pushed successfully."
