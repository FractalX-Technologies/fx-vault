cask "fx-vault" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/FractalX-Technologies/fx-vault/releases/download/v#{version}/FXVault-#{version}.dmg"
  name "FX Vault"
  desc "Manage GitHub Actions secrets and variables from a local encrypted vault"
  homepage "https://github.com/FractalX-Technologies/fx-vault"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on formula: "gh"
  depends_on macos: :sonoma

  app "FX Vault.app"

  zap trash: [
    "~/Library/Application Support/FX Vault",
    "~/Library/Caches/io.fractalx.fxvault",
    "~/Library/Preferences/io.fractalx.fxvault.plist",
    "~/Library/Saved Application State/io.fractalx.fxvault.savedState",
  ]

  caveats <<~EOS
    `brew uninstall --zap --cask fx-vault` permanently deletes the local vault
    (~/Library/Application Support/FX Vault), including every stored value that
    has not been synced to GitHub. Export or sync anything you need first.
  EOS
end
