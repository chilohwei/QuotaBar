cask "quotabar" do
  version "1.3.3"
  sha256 "c74e807bb3b67cd943cdf4958037766471f91ee4c985eb5a934fb50e78b5c074"

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
