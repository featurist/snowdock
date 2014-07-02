httpism = require 'httpism'

module.exports () =
  response = httpism.post 'http://localhost:8000/api/login' {
    username = 'admin'
    password = 'shipyard'
  } (form: true)!

  JSON.parse(response.body).api_key
