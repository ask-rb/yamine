# frozen_string_literal: true

require "digest"

module Yamine
  # DNS label sanitization (RFC 1035): lowercase, hyphen-separated,
  # max 63 chars with hash suffix on truncation.
  #
  # Borrowed semantics from portless sanitizeForHostname/truncateLabel,
  # reimplemented in idiomatic Ruby.
  module Sanitize
    MAX_DNS_LABEL_LENGTH = 63

    module_function

    def truncate_label(label)
      return label if label.length <= MAX_DNS_LABEL_LENGTH

      hash = Digest::SHA256.hexdigest(label)[0, 6]
      prefix = label[0, MAX_DNS_LABEL_LENGTH - 7].gsub(/-+\z/, "")
      "#{prefix}-#{hash}"
    end

    def hostname_label(name)
      sanitized = name.to_s.downcase
        .gsub(/[^a-z0-9-]/, "-")
        .gsub(/-{2,}/, "-")
        .gsub(/\A-+|-+\z/, "")
      truncate_label(sanitized)
    end

    def valid_tld?(tld)
      return false if tld.nil? || tld.empty? || tld.length > 253

      tld.split(".").all? do |label|
        !label.empty? && label.length <= 63 &&
          label.match?(/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/)
      end
    end
  end
end
