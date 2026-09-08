# frozen_string_literal: true

require_relative "test_helper"

class SanitizeTest < Minitest::Test
  def test_lowercases_and_hyphenates
    assert_equal "my-app", Yamine::Sanitize.hostname_label("My_App!")
  end

  def test_collapses_and_trims_hyphens
    assert_equal "my-app", Yamine::Sanitize.hostname_label("--My--App--")
  end

  def test_short_labels_untouched
    assert_equal "a", Yamine::Sanitize.hostname_label("a")
    assert_equal "x" * 63, Yamine::Sanitize.hostname_label("x" * 63)
  end

  def test_truncates_with_hash_suffix_for_uniqueness
    long = "a" * 100
    result = Yamine::Sanitize.truncate_label(long)
    assert_equal 63, result.length
    refute_equal Yamine::Sanitize.truncate_label("b" * 100), result
    assert_match(/\A[a-z0-9]+-[0-9a-f]{6}\z/, result)
  end

  def test_valid_tld
    assert Yamine::Sanitize.valid_tld?("localhost")
    assert Yamine::Sanitize.valid_tld?("preview.example.com")
    refute Yamine::Sanitize.valid_tld?("")
    refute Yamine::Sanitize.valid_tld?("UPPER.test")
    refute Yamine::Sanitize.valid_tld?("-bad.test")
    refute Yamine::Sanitize.valid_tld?("a" * 64 + ".test")
  end
end
