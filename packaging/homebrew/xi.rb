# typed: false
# frozen_string_literal: true

# Homebrew formula for the Ξ (Xi) programming language toolchain.
#
# This file is the source of truth for the `code-by-sia/homebrew-xi` tap; the
# release workflow regenerates the version/url/sha256 lines via
# `scripts/update-formula.sh` and pushes the result to the tap repo. See
# packaging/homebrew/README.md for the one-time tap setup.
class Xi < Formula
  desc "The Ξ (Xi) programming language toolchain (compiler + REPL)"
  homepage "https://github.com/code-by-sia/xi"
  version "0.1.14"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/code-by-sia/xi/releases/download/v0.1.14/xi-v0.1.14-macos-arm64.tar.gz"
      sha256 "5f5b46b7989866933ea896c6325ca0ffdd2c32e58fcda4b5fff3c17723c40462"
    end
    on_intel do
      url "https://github.com/code-by-sia/xi/releases/download/v0.1.14/xi-v0.1.14-macos-x86_64.tar.gz"
      sha256 "39a25927bbc5d2d938cff4e6e5c7a938a6f6ed794d662a8ebe8a4e6b0ee75011"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/code-by-sia/xi/releases/download/v0.1.14/xi-v0.1.14-linux-arm64.tar.gz"
      sha256 "301e92f6f6bfdb7e419c31453262ef948f2cce897a0dc283fc2f224613edf966"
    end
    on_intel do
      url "https://github.com/code-by-sia/xi/releases/download/v0.1.14/xi-v0.1.14-linux-x86_64.tar.gz"
      sha256 "79f0bf78d1b3d7ada5740d0e3f57c301bea8d9e31c31bcefdfcaaaa5b8de7b62"
    end
  end

  def install
    # The tarball expands to a single top-level dir (Homebrew has already cd'd
    # into it). Stash the bundle under libexec and write absolute-path wrappers
    # so xc/xi find the runtime and stdlib regardless of how bin is symlinked.
    libexec.install Dir["*"]

    (bin/"xc").write <<~SH
      #!/bin/sh
      export XC_RUNTIME="${XC_RUNTIME:-#{libexec}/runtime}"
      export XC_STD="${XC_STD:-#{libexec}}"
      exec "#{libexec}/libexec/xc" "$@"
    SH

    (bin/"xi").write <<~SH
      #!/bin/sh
      export XC_RUNTIME="${XC_RUNTIME:-#{libexec}/runtime}"
      export XC_STD="${XC_STD:-#{libexec}}"
      export XC="${XC:-#{bin}/xc}"
      exec "#{libexec}/libexec/xi" "$@"
    SH

    chmod 0755, bin/"xc"
    chmod 0755, bin/"xi"
  end

  def caveats
    <<~EOS
      xc compiles Xi to C and invokes a C compiler to produce native binaries,
      so a working `cc` (clang/gcc) must be on your PATH.
    EOS
  end

  test do
    (testpath/"hello.xi").write <<~XI
      import "std/log.xi"
      async entry (logger: Logger) main(args: String[]) {
          logger.info("brew ok")
      }
      module App {}
    XI
    assert_match "brew ok", shell_output("#{bin}/xi hello.xi")
  end
end
