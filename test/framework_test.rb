# frozen_string_literal: true

require_relative "test_helper"

class FrameworkTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_rails
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "application.rb"),
      "module X\n class Application < Rails::Application\n end\nend\n")
    assert_equal :rails, Yamine::Framework.detect(@dir)
  end

  def test_bare_rack
    File.write(File.join(@dir, "config.ru"), "run ->(env) { [200, {}, ['hi']] }\n")
    assert_equal :rack, Yamine::Framework.detect(@dir)
  end

  def test_jekyll
    File.write(File.join(@dir, "_config.yml"), "title: x\n")
    File.write(File.join(@dir, "Gemfile"), "gem \"jekyll\"\n")
    assert_equal :jekyll, Yamine::Framework.detect(@dir)
  end

  def test_procfile
    File.write(File.join(@dir, "Procfile.dev"), "web: bin/rails s -p 3000\n")
    assert_equal :procfile, Yamine::Framework.detect(@dir)
  end

  def test_unknown
    assert_equal :unknown, Yamine::Framework.detect(@dir)
  end

  def test_sinatra_modular_is_rack
    fleet = File.expand_path("../../yamine-apps/sinatra-modular", __dir__)
    skip "fixture fleet not present" unless File.directory?(fleet)
    assert_equal :rack, Yamine::Framework.detect(fleet)
  end

  def test_foreman_port_set_is_procfile_or_rack
    fleet = File.expand_path("../../yamine-apps/foreman-port-set", __dir__)
    skip "fixture fleet not present" unless File.directory?(fleet)
    # config.ru exists so it reads as rack; the Procfile line already
    # carries $PORT, so run-mode injection must leave it alone.
    assert_includes %i[rack procfile], Yamine::Framework.detect(fleet)
  end

  def test_hanami2_slice_layout_is_rack
    fleet = File.expand_path("../../yamine-apps/hanami2", __dir__)
    skip "fixture fleet not present" unless File.directory?(fleet)
    assert_equal :rack, Yamine::Framework.detect(fleet)
    name, src = Yamine::Inference.infer(fleet)
    assert_equal "hanami2", name
  end

  def test_jekyll_livereload_detected
    fleet = File.expand_path("../../yamine-apps/jekyll-livereload", __dir__)
    skip "fixture fleet not present" unless File.directory?(fleet)
    assert_equal :jekyll, Yamine::Framework.detect(fleet)
  end

  def test_roda_plugins_is_rack
    fleet = File.expand_path("../../yamine-apps/roda-plugins", __dir__)
    skip "fixture fleet not present" unless File.directory?(fleet)
    assert_equal :rack, Yamine::Framework.detect(fleet)
  end

  def test_managed_only_for_live_rack
    assert Yamine::Framework.managed?(:rails)
    assert Yamine::Framework.managed?(:rack)
    refute Yamine::Framework.managed?(:jekyll)
    refute Yamine::Framework.managed?(:procfile)
  end
end
