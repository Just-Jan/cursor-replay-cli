#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class ReleaseTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("cursor-replay-release-test-")
    root = File.expand_path("..", __dir__)
    paths = %w[Package.swift Sources Tests scripts Formula docs .github README.md DEVELOPMENT.md LICENSE .gitignore]
    paths.each { |path| FileUtils.cp_r(File.join(root, path), @directory) }
    identity = File.read(File.join(@directory, "Sources/MouseRecorderCLI/AppIdentity.swift"))
    @version = identity[/static let version = "([^"]+)"/, 1]
    @archive_name = "cursor-replay-cli-#{@version}.tar.gz"
    git("init", "--quiet")
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def git(*args)
    output, status = Open3.capture2e(
      "git", "-c", "user.name=Release Tests", "-c", "user.email=release-tests@example.invalid",
      "-c", "commit.gpgsign=false", *args, chdir: @directory
    )
    assert status.success?, output
    output
  end

  def commit
    git("add", "--force", ".")
    git("commit", "--quiet", "-m",
        "Release fixture\n\nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>")
  end

  def prepare(ref = "HEAD", output = "dist")
    Open3.capture2e(RbConfig.ruby, File.join(@directory, "scripts/prepare-release.rb"),
                   ref, File.join(@directory, output), chdir: @directory)
  end

  def test_reproducible_allowlisted_archive_and_checksum
    FileUtils.mkdir_p(File.join(@directory, "recordings"))
    File.write(File.join(@directory, "recordings/private.json"), "synthetic excluded fixture")
    commit
    File.write(File.join(@directory, "Sources/uncommitted.txt"), "synthetic uncommitted fixture")
    output, status = prepare
    assert status.success?, output
    output, status = prepare("HEAD", "second")
    assert status.success?, output

    archive = File.join(@directory, "dist", @archive_name)
    assert_equal File.binread(archive), File.binread(File.join(@directory, "second", @archive_name))
    entries, status = Open3.capture2e("tar", "-tzf", archive)
    assert status.success?, entries
    assert_includes entries, "cursor-replay-cli-#{@version}/LICENSE\n"
    assert_includes entries, "cursor-replay-cli-#{@version}/docs/USAGE.md\n"
    assert_includes entries, "cursor-replay-cli-#{@version}/docs/assets/terminal-preview.svg\n"
    assert_includes entries, "cursor-replay-cli-#{@version}/Sources/MouseRecorderCLI/AppIdentity.swift\n"
    refute_match(/private\.json|uncommitted\.txt|\.git\//, entries)
    checksum = Digest::SHA256.file(archive).hexdigest
    assert_equal "#{checksum}  #{@archive_name}\n", File.read(File.join(@directory, "dist/SHA256SUMS"))
    formula = File.read(File.join(@directory, "dist/cursor-replay.rb"))
    assert_includes formula, "/releases/download/v#{@version}/#{@archive_name}"
    assert_includes formula, "sha256 \"#{checksum}\""
  end

  def test_release_tag_must_match_embedded_cli_version
    commit
    git("tag", "v#{@version}")
    output, status = prepare("v#{@version}")
    assert status.success?, output
    wrong_tag = @version == "9.9.9" ? "v9.9.8" : "v9.9.9"
    git("tag", wrong_tag)
    output, status = prepare(wrong_tag, "wrong")
    refute status.success?
    assert_includes output, "does not match CLI version"
    refute File.exist?(File.join(@directory, "wrong", @archive_name))
  end

  def test_rejects_nonstable_versions_and_option_like_refs
    ["v01.2.3", "v1.2.3-beta", "--all"].each do |ref|
      output, status = prepare(ref)
      refute status.success?
      assert_includes output, "Expected HEAD or a stable release tag"
    end
  end

  def test_a_release_named_branch_is_not_accepted_as_a_tag
    commit
    git("branch", "v#{@version}")
    output, status = prepare("v#{@version}")
    refute status.success?, output
    refute File.exist?(File.join(@directory, "dist", @archive_name))
  end

  def test_replaces_previous_formula_metadata_instead_of_duplicating_it
    path = File.join(@directory, "Formula/cursor-replay.rb")
    formula = File.read(path)
    formula.sub!(/^  url "[^"]+"\n  sha256 "[a-f0-9]{64}"\n/, "")
    formula.sub!(/(  homepage "[^"]+"\n)/) do
      "#{$1}  url \"https://example.invalid/previous.tar.gz\"\n  sha256 \"#{"0" * 64}\"\n"
    end
    File.write(path, formula)
    commit
    output, status = prepare
    assert status.success?, output
    result = File.read(File.join(@directory, "dist/cursor-replay.rb"))
    assert_equal 1, result.scan(/^  url /).length
    assert_equal 1, result.scan(/^  sha256 /).length
    refute_includes result, "example.invalid"
  end
end
