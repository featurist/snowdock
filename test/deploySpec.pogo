connectToShipyard = require '../docker'
httpism = require 'httpism'

describe 'deploy'
  it 'can deploy an app'
    shipyard = connectToShipyard {
      apiUrl = 'http://centos:8000/api/v1/'
      apiKey = 'admin:9cc0e15267857da3135f95bcc9a36d19f64769ec'
    }

    shipyard.application! {
      domain_name = 'myapp2.linux'
      containers = shipyard.4 containersFromImage 'nodeapp'!
    }

    console.log (httpism.json.get 'http://centos/' (headers: {host = 'myapp2.linux'})!.body)

  it 'can deploy an update to the app'
