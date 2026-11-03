#!/usr/bin/env bash
# Prints the Homebrew cask for a release.
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

  depends_on macos: ">= :sequoia"

  app "Sonata.app"
RUBY

if [[ "$notarized" != true ]]; then
  cat <<'RUBY'

  # This build is signed ad hoc, not notarized: clear the download quarantine so it opens.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Sonata.app"]
  end
RUBY
fi

cat <<'RUBY'

  uninstall quit: "dev.sonata.Sonata"

  zap trash: [
    "~/Library/Caches/sonata",
    "~/Library/Preferences/dev.sonata.Sonata.plist",
  ]
end
RUBY
