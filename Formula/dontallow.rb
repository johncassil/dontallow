class Dontallow < Formula
  desc "Auto-dismiss the macOS 'Allow X to find devices on local networks?' prompt"
  homepage "https://github.com/johncassil/dontallow"
  url "https://github.com/johncassil/dontallow/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "38dda44ded73b0f148777fd7a5a7003dbf8d80732809609d1b1b5500532f5e8f"
  head "https://github.com/johncassil/dontallow.git", branch: "main"
  license "MIT"
  depends_on :macos

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
