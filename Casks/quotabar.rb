cask "quotabar" do
  version "1.2.1"
  sha256 "c83d7c5b79520a5211ebee5b29ac352fd8b8f048448f8da744467686d3cb6b2a"

  url "https://github.com/chilohwei/QuotaBar/releases/download/v#{version}/QuotaBar-#{version}-universal.dmg"
  name "QuotaBar"
  desc "Menu bar tool for viewing AI tool quotas and switching local accounts"
  homepage "https://github.com/chilohwei/QuotaBar"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "QuotaBar.app"

  zap trash: [
    "~/Library/Application Support/QuotaBar",
    "~/Library/Preferences/com.chiloh.QuotaBar.plist",
  ]
end
