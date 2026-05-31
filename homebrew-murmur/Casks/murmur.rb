cask "murmur" do
  version "1.0.0"
  sha256 "9859be76f35e4a88c316d5792d873273dcaa0f2757127069f271ee406f2f445e"

  url "https://github.com/Lyons800/murmur/releases/download/v#{version}/Murmur.dmg"
  name "Murmur"
  desc "On-device voice-to-text for macOS — hold a key, speak, release"
  homepage "https://murmur.dev"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Murmur.app"

  zap trash: [
    "~/Library/Application Support/Murmur",
    "~/Library/Preferences/dev.murmur.app.plist",
    "~/Library/Caches/dev.murmur.app",
  ]
end
