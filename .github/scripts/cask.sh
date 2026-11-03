#!/usr/bin/env bash
# Prints the Homebrew cask for a release (stanzas in the order `brew style` expects).
#   cask.sh <version> <owner/repo> <sha256> <notarized: true|false>
set -euo pipefail
version=$1 repo=$2 sha=$3 notarized=$4

cat <<RUBY
cask "sonata" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$repo/releases/download/v#{version}/Sonata-#{version}.zip"
  name "Sonata"
  desc "Solana leader schedule and validator earnings in the menu bar"
  homepage "https://github.com/$repo"

  depends_on macos: :sequoia

  app "Sonata.app"

  uninstall quit: "sh.scarce.Sonata"

  zap trash: [
    "~/Library/Caches/sonata",
    "~/Library/Preferences/dev.sonata.Sonata.plist",
    "~/Library/Preferences/sh.scarce.Sonata.plist",
  ]
RUBY

if [[ "$notarized" != true ]]; then
  cat <<'RUBY'

  caveats <<~EOS
    This build of Sonata is signed ad hoc, not notarized. If macOS won't open it,
    allow it once in System Settings → Privacy & Security → Open Anyway.
  EOS
RUBY
fi

echo "end"
