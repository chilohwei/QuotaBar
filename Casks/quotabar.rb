cask "quotabar" do
  version "1.3.6"
  sha256 "f4cc1fcaea29c36c36db1cea89064277f37c9b835f3b46fc2b7e6cf95ff266f2"

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
