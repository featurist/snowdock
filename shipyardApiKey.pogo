httpism = require 'httpism'

module.exports (host: 'localhost') =
  response = httpism.post "http://#(host):8000/api/login" {
    username = 'admin'
    password = 'shipyard'
  } (form: true)!

  JSON.parse(response.body).api_key
