# frozen_string_literal: true

require "socket"

module Yamine
  # Ephemeral TCP ports for run-mode backends (4000-4999, portless range).
  # Random-first then sequential; WHATWG blocked ports skipped.
  module Ports
    MIN_PORT = 4000
    MAX_PORT = 4999
    RANDOM_ATTEMPTS = 50

    # Browsers refuse these (WHATWG fetch "bad port" list); Next.js too.
    BLOCKED = [0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42,
      43, 53, 69, 77, 79, 87, 95, 101, 102, 103, 104, 109, 110, 111, 113,
      115, 117, 119, 123, 135, 137, 139, 143, 161, 179, 389, 427, 465, 512,
      513, 514, 515, 526, 530, 531, 532, 540, 548, 554, 556, 563, 587, 601,
      636, 989, 990, 993, 995, 1719, 1720, 1723, 2049, 3659, 4045, 4190,
      5060, 5061, 6000, 6566, 6665, 6666, 6667, 6668, 6669, 6679, 6697,
      10080].to_h { |p| [p, true] }.freeze

    module_function

    def free?(port)
      server = TCPServer.new("127.0.0.1", port)
      server.close
      true
    rescue SystemCallError
      false
    end

    def find_free(min: MIN_PORT, max: MAX_PORT)
      raise Error, "min (#{min}) must be <= max (#{max})" if min > max

      RANDOM_ATTEMPTS.times do
        port = min + rand(max - min + 1)
        return port if !BLOCKED[port] && free?(port)
      end
      (min..max).each do |port|
        return port if !BLOCKED[port] && free?(port)
      end
      raise Error, "No free port found in range #{min}-#{max}"
    end
  end
end
