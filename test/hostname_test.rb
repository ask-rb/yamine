# frozen_string_literal: true

require_relative "test_helper"

class HostnameTest < Minitest::Test
  H = Yamine::Hostname

  def test_bare_app
    assert_equal ["myapp.localhost"], H.build(app: "myapp")
  end

  def test_service_prefixes
    assert_equal ["api.myapp.localhost"], H.build(app: "myapp", service: "api")
  end

  def test_variant_prefixes_everything
    assert_equal ["fix-ui.myapp.localhost"],
      H.build(app: "myapp", variant: "fix-ui")
    assert_equal ["fix-ui.api.myapp.localhost"],
      H.build(app: "myapp", service: "api", variant: "fix-ui")
  end

  def test_multiple_tlds
    assert_equal ["myapp.localhost", "myapp.preview.example.com"],
      H.build(app: "myapp", tlds: ["localhost", "preview.example.com"])
  end

  def test_url_omits_default_ports
    assert_equal "https://myapp.localhost", H.url("myapp.localhost", port: 443, tls: true)
    assert_equal "http://myapp.localhost", H.url("myapp.localhost", port: 80, tls: false)
    assert_equal "https://myapp.localhost:1355", H.url("myapp.localhost", port: 1355, tls: true)
  end

  def test_strip_port
    assert_equal "myapp.localhost", H.strip_port("myapp.localhost:443")
    assert_equal "myapp.localhost", H.strip_port("MyApp.Localhost")
  end
end
