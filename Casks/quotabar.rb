cask "quotabar" do
  version "1.0.12"
  sha256 "86db21b632453821037d1451efe64fb3664f8acec7b81b6fbcf3cb9733314a90"

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
