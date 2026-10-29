class Dontallow < Formula
  desc "Auto-dismiss the macOS 'Allow X to find devices on local networks?' prompt"
  homepage "https://github.com/johncassil/dontallow"
  # Fill in url + sha256 from a tagged release tarball; `head` works today.
  # url "https://github.com/johncassil/dontallow/archive/refs/tags/v0.1.0.tar.gz"
  # sha256 "..."
  head "https://github.com/johncassil/dontallow.git", branch: "main"
  license "MIT"
  depends_on :macos
  depends_on xcode: ["14.0", :build]

  def install
    system "make", "dontallow"
    bin.install "dontallow"
  end

  def caveats
    <<~EOS
      Start the background agent and grant Accessibility when prompted:
        dontallow install
      Prompts are then dismissed automatically. To let apps ask again for a while:
        dontallow pause 1h
    EOS
  end

  test do
    assert_match "dontallow", shell_output("#{bin}/dontallow version")
  end
end
