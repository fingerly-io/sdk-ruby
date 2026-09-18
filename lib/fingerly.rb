# frozen_string_literal: true

require_relative "fingerly/version"
require_relative "fingerly/errors"
require_relative "fingerly/config"
require_relative "fingerly/models"
require_relative "fingerly/transport"
require_relative "fingerly/client"
require_relative "fingerly/webhooks"
require_relative "fingerly/proxy"

# Server-side Fingerly SDK.
#
# It reads stored identification events with a secret key, verifies signed
# webhooks, and serves the browser SDK's requests from a route on your own
# domain. It has no runtime dependencies.
#
#   require "fingerly"
#
#   fingerly = Fingerly::Client.new(secret_key: ENV.fetch("FINGERLY_SECRET_KEY"))
#   event = fingerly.events.get(request_id)
#
# Secret keys and webhook secrets belong in server-side code only. A browser
# must never see either.
module Fingerly
end
