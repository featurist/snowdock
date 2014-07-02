httpism = require 'httpism'

module.exports =
  httpism.json.api @(request, next)
    request.headers.'authorization' = "ApiKey #(request.options.shipyard.apiKey)"
    next (request)!
