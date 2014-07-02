httpism = require 'httpism'

module.exports =
  httpism.api @(request, next)
    request.headers.'authorization' = "ApiKey #(request.options.shipyard.apiKey)"
    next (request)!
