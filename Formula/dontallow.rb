class Dontallow < Formula
  desc "Auto-dismiss the macOS 'Allow X to find devices on local networks?' prompt"
  homepage "https://github.com/johncassil/dontallow"
  url "https://github.com/johncassil/dontallow/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "a6efb067267f1008e95b6e453be33e1befa01f864e8fd1e958e04cc200c6bee8"
  head "https://github.com/johncassil/dontallow.git", branch: "main"
  license "MIT"
  depends_on macos: :ventura

  def install
    system "make", "dontallow"
    bin.install "dontallow"
  end

  def caveats
    <<~EOS
      Start the background agent; it walks you through granting Accessibility:
        dontallow install
      After `brew upgrade dontallow`, macOS forgets the grant (new binary signature):
        dontallow status   # tells you if a re-grant is needed and opens the right pane
      To let apps ask again for a while:
        dontallow pause 1h
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/dontallow version")
  end
end
