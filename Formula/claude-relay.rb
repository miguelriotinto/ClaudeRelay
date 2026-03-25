class ClaudeRelay < Formula
  desc "Remote terminal relay server and CLI over WebSocket"
  homepage "https://github.com/miguelriotinto/ClaudeRelay"
  url "https://github.com/miguelriotinto/ClaudeRelay/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
  # license "MIT"  # Uncomment after adding a LICENSE file
  head "https://github.com/miguelriotinto/ClaudeRelay.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build",
           "-c", "release",
           "--disable-sandbox",
           "-Xswiftc", "-cross-module-optimization"
    bin.install ".build/release/claude-relay"
    bin.install ".build/release/claude-relay-server"
  end

  service do
    run opt_bin/"claude-relay-server"
    keep_alive true
    log_path var/"log/claude-relay/stdout.log"
    error_log_path var/"log/claude-relay/stderr.log"
    working_dir var/"claude-relay"
  end

  def post_install
    (var/"claude-relay").mkpath
    (var/"log/claude-relay").mkpath
  end

  def caveats
    <<~EOS
      To start the relay server as a background service:
        brew services start claude-relay

      Create an auth token:
        claude-relay token create --label "my-device"

      Default ports:
        WebSocket: 9200
        Admin API: 9100

      Config stored at: ~/.claude-relay/config.json
    EOS
  end

  test do
    assert_match "claude-relay", shell_output("#{bin}/claude-relay --help")
    assert_match version.to_s, shell_output("#{bin}/claude-relay --version")
  end
end
