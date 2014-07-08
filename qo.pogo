shipyardApiKey = require './shipyardApiKey'

task 'apikey' @(args, host: 'localhost')
  console.log(shipyardApiKey(host: host)!)
