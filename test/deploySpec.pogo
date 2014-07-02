connectToShipyard = require '../docker'
httpism = require 'httpism'
shipyardApiKey = require '../shipyardApiKey'
fs = require 'fs'

describe 'deploy'
  apikey = nil

  beforeEach
    fs.writeFile 'nodeapp/views/index.txt' 'hi from <%= host %>'!
    apikey := shipyardApiKey()!

  it 'can deploy an app' =>
    self.timeout 10000
    console.log('apikey', apikey)
    shipyard = connectToShipyard {
      apiUrl = 'http://shipyard:8000/api/v1/'
      apiKey = "admin:#(apikey)"
    }

    shipyard.application! {
      domain_name = 'nodeapp'
      containers = shipyard.4 containersFromImage 'nodeapp'!
    }

    waitFor 4 backendsToRespond (host: 'nodeapp')!

  waitFor (n) backendsToRespond (host: nil, timeout: 2000)! =
    promise @(result, error)
      setTimeout
        error(@new Error "failed to get reponses from all #(n) hosts")
      (timeout)

      nodeapp = httpism.api 'http://shipyard/' (headers: {host = host})

      requestAHost(hosts) =
        body = nodeapp.get ''!.body
        match = r/hi from (.*)/.exec (body)
        if (match)
          hosts.(match.1) = true
          if (Object.keys(hosts).length < n)
            requestAHost (hosts)!
        else
          error(@new Error "unexpected response from host: #(body)")

      result(requestAHost {}!)

  it 'can deploy an update to the app'
