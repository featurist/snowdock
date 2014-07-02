connectToShipyard = require '../shipyard'
httpism = require 'httpism'
shipyardApiKey = require '../shipyardApiKey'
fs = require 'fs'
vagrantIp = require '../vagrantIp'
should = require 'chai'.should()
child_process = require 'child_process'
Docker = require 'dockerode'

describe 'deploy'
  apikey = nil
  dockerRegistryDomain = nil
  shipyard = nil
  dockerHost = nil
  dockerPort = nil
  imageName = nil

  beforeEach
    fs.writeFile 'nodeapp/views/index.txt' 'hi from <%= host %>'!
    apikey := shipyardApiKey()!
    vip = vagrantIp()!
    dockerRegistryDomain := "#(vip):5000"
    dockerHost := "http://#(vip)"
    dockerPort := 4243
    imageName := "#(dockerRegistryDomain)/nodeapp"

    shipyard := connectToShipyard {
      apiUrl = 'http://shipyard:8000/api/v1/'
      apiKey = "admin:#(apikey)"
    }

    shipyard.deleteApplication 'nodeapp'!
    shipyard.deleteContainersUsingImage 'nodeapp'!

  it 'should not have anything running'
    shipyard.containersUsingImage 'nodeapp'!.length.should.eql 0
    should.not.exist(shipyard.applicationByName 'nodeapp'!)

  it 'can deploy an app' =>
    self.timeout 10000

    shipyard.application! {
      domain_name = 'nodeapp'
      containers = shipyard.4 containersFromImage (imageName)!
    }

    waitFor 4 backendsToRespond (host: 'nodeapp', responseRegex: r/^hi from (.*)$/)!

  describe 'updates'
    monitor = nil

    beforeEach
      monitor := serviceMonitor(host: 'nodeapp')

    afterEach
      monitor.stop()

    it.only 'can deploy an update to the app' =>
      self.timeout 60000

      shipyard.application! {
        domain_name = 'nodeapp'
        containers = shipyard.4 containersFromImage (imageName)!
      }

      waitFor 4 backendsToRespond (host: 'nodeapp', responseRegex: r/^hi from (.*)$/)!

      monitor.start()

      makeChangeToApp()!
      buildDockerImage (imageName: imageName, dir: 'nodeapp')!
      pullImage "#(dockerRegistryDomain)/nodeapp"!

      shipyard.application! {
        domain_name = 'nodeapp'
        containers = shipyard.4 containersFromImage (imageName)!
      }

      waitFor 4 backendsToRespond (host: 'nodeapp', responseRegex: r/^hi from (.*), v2$/)!

      monitor.stop()

      monitor.totalInterruptionTime.should.equal 0
      should.not.exist(monitor.error)

  serviceMonitor(host: nil) =
    interval = nil
    timeOfLastError = nil

    {
      start () =
        setInterval
          response = httpism.get 'http://shipyard/' (headers: {host = host}, exceptions: false)!
          if (response.statusCode >= 400)
            thisTime = @new Date().getTime()
            if (timeOfLastError)
              self.totalInterruptionTime = self.totalInterruptionTime + (thisTime - timeOfLastError)

            timeOfLastError := thisTime

            console.log "#(@new Date().getTime()): service interruption #(response.statusCode)"
            console.log (response.body)
            self.error := response
        10

      stop () =
        clearInterval (interval)

      totalInterruptionTime = 0
    }

  makeChangeToApp() =
    fs.writeFile 'nodeapp/views/index.txt' 'hi from <%= host %>, v2'!

  buildDockerImage (imageName: nil, dir: nil) =
    process.chdir "#(__dirname)/.."
    console.log(child_process.exec "docker build -t #(imageName) #(dir)" ^!)
    console.log(child_process.exec "docker push #(imageName)" ^!)

  pullImage (imageName)! =
    promise @(result, error)
      docker = @new Docker(host: dockerHost, port: dockerPort)
      docker.pull (imageName) @(e, stream)
        if (e)
          error(e)
        else
          stream.setEncoding 'utf-8'

          stream.on 'end'
            result()

          stream.resume()

  waitFor (n) backendsToRespond (host: nil, responseRegex: nil, timeout: 5000)! =
    promise @(result, error)
      setTimeout
        error(@new Error "failed to get reponses from all #(n) hosts")
      (timeout)

      nodeapp = httpism.api 'http://shipyard/' (headers: {host = host})

      requestAHost(hosts) =
        body = nodeapp.get ''!.body
        match = responseRegex.exec (body)
        if (match)
          hosts.(match.1) = true
          if (Object.keys(hosts).length < n)
            requestAHost (hosts)!
        else
          error(@new Error "unexpected response from host: #(body)")

      result(requestAHost {}!)
