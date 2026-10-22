class CursorReplay < Formula
  desc "Record and replay mouse sessions in a native macOS terminal interface"
  homepage "https://github.com/Just-Jan/cursor-replay-cli"
  license "MIT"
  head "https://github.com/Just-Jan/cursor-replay-cli.git", branch: "main"

  depends_on :macos

  uses_from_macos "swift" => :build

  on_macos do
    depends_on macos: :sequoia
  end

  def install
    system "swift", "build", "--product", "cursor-replay", *std_swift_args
    bin.install ".build/release/cursor-replay"
  end

  def caveats
    <<~EOS
      Run `cursor-replay doctor` from your terminal, then grant Accessibility
      and Input Monitoring in System Settings > Privacy & Security.
      Homebrew cannot grant these permissions for you.

      Menu recordings stay in:
        ~/Library/Application Support/Cursor Replay CLI/recordings
      Upgrading or uninstalling this formula does not remove recordings.
    EOS
  end

  test do
    assert_match "Usage:", shell_output("#{bin}/cursor-replay --help")
    output = shell_output("#{bin}/cursor-replay --version")
    assert_match(/^cursor-replay \d+\.\d+\.\d+\n$/, output)
    assert_equal "cursor-replay #{version}\n", output unless build.head?
    assert_match "ERROR:", shell_output("#{bin}/cursor-replay info missing.json 2>&1", 1)
  end
end
