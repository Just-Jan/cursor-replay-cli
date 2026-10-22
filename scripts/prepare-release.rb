#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"

def git(*args)
  output, status = Open3.capture2e("git", *args)
  abort output unless status.success?
  output
end

abort "Usage: ruby scripts/prepare-release.rb [HEAD|vX.Y.Z] [output-directory]" if ARGV.length > 2
ref = ARGV.fetch(0, "HEAD")
version_pattern = /(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)/
unless ref == "HEAD" || ref.match?(/\Av#{version_pattern}\z/)
  abort "Expected HEAD or a stable release tag such as v0.1.0."
end
output_dir = File.expand_path(ARGV.fetch(1, "dist"))

Dir.chdir(File.expand_path("..", __dir__)) do
  revision_ref = ref == "HEAD" ? ref : "refs/tags/#{ref}"
  revision = git("rev-parse", "--verify", "#{revision_ref}^{commit}").strip
  identity = git("show", "#{revision}:Sources/MouseRecorderCLI/AppIdentity.swift")
  version = identity[/^\s*static let version = "(#{version_pattern})"$/, 1]
  abort "AppIdentity.swift must declare a stable X.Y.Z version." unless version
  tag = "v#{version}"
  abort "Tag #{ref} does not match CLI version #{version}." unless ref == "HEAD" || ref == tag

  formula = git("show", "#{revision}:Formula/cursor-replay.rb")
  archive_name = "cursor-replay-cli-#{version}.tar.gz"
  FileUtils.mkdir_p(output_dir)
  archive_path = File.join(output_dir, archive_name)
  tar_path = File.join(output_dir, "cursor-replay-cli-#{version}.tar")
  abort "Release output already exists: #{archive_path}" if File.exist?(archive_path) || File.exist?(tar_path)

  # Archive only committed, explicitly allowed paths, never local captures or build caches.
  paths = %w[Package.swift Sources Tests scripts Formula docs .github README.md DEVELOPMENT.md LICENSE .gitignore]
  git("archive", "--format=tar", "--prefix=cursor-replay-cli-#{version}/",
      "--output=#{tar_path}", revision, "--", *paths)
  begin
    File.open(archive_path, "wb") do |archive|
      success = system("gzip", "-n", "-c", tar_path, out: archive)
      abort "Failed to compress the source archive." unless success
    end
  ensure
    FileUtils.rm_f(tar_path)
  end
  checksum = Digest::SHA256.file(archive_path).hexdigest
  metadata = "  url \"https://github.com/Just-Jan/cursor-replay-cli/releases/download/#{tag}/#{archive_name}\"\n" \
             "  sha256 \"#{checksum}\"\n"
  unless formula.sub!(/(  homepage "[^"]+"\n)(?:  url "[^"]+"\n  sha256 "[a-f0-9]{64}"\n)?/) { "#{$1}#{metadata}" }
    abort "Cannot locate Homebrew release metadata in Formula/cursor-replay.rb."
  end
  File.write(File.join(output_dir, "cursor-replay.rb"), formula)
  File.write(File.join(output_dir, "SHA256SUMS"), "#{checksum}  #{archive_name}\n")
  puts "Prepared #{tag} from #{revision} in #{output_dir}"
end
