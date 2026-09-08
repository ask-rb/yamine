# frozen_string_literal: true

require_relative "test_helper"

class InferenceTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_config_name_wins
    File.write(File.join(@dir, "yamine.json"), '{"name": "custom"}')
    name, source = Yamine::Inference.infer(@dir)
    assert_equal "custom", name
    assert_equal "yamine.json", source
  end

  def test_rails_module
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "application.rb"),
      "module CoolApp\n  class Application < Rails::Application\n  end\nend\n")
    name, source = Yamine::Inference.infer(@dir)
    assert_equal "cool-app", name
    assert_equal "config/application.rb", source
  end

  def test_gemspec_name
    File.write(File.join(@dir, "cool-gem.gemspec"), "spec.name = \"cool-gem\"\n")
    name, source = Yamine::Inference.infer(@dir)
    assert_equal "cool-gem", name
    assert_equal "cool-gem.gemspec", source
  end

  def test_package_json_strips_scope
    File.write(File.join(@dir, "package.json"), '{"name": "@org/web"}')
    name, source = Yamine::Inference.infer(@dir)
    assert_equal "web", name
    assert_equal "package.json", source
  end

  def test_directory_basename_fallback
    nested = File.join(@dir, "My_Cool App!")
    FileUtils.mkdir_p(nested)
    name, source = Yamine::Inference.infer(nested)
    assert_equal "my-cool-app", name
    assert_equal "directory name", source
  end

  def test_git_root_fallback
    system("git", "init", "-q", @dir, out: File::NULL, err: File::NULL)
    sub = File.join(@dir, "sub")
    FileUtils.mkdir_p(sub)
    name, source = Yamine::Inference.infer(sub)
    assert_equal File.basename(@dir).downcase.gsub(/[^a-z0-9-]/, "-"), name
    assert_equal "git root", source
  end

  def test_invalid_config_json_ignored
    File.write(File.join(@dir, "yamine.json"), "not json")
    # Falls through to directory basename rather than raising.
    name, = Yamine::Inference.infer(@dir)
    refute_nil name
  end
end
