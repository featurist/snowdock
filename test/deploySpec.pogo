connectToShipyard = require '../shipyard'
httpism = require 'httpism'
shipyardApiKey = require '../shipyardApiKey'
fs = require 'fs'
vagrantIp = require '../vagrantIp'
chai = require 'chai'
should = chai.should()
chaiAsPromised = require 'chai-as-promised'
chai.use(chaiAsPromised)
child_process = require 'child_process'
Docker = require 'dockerode'
sshForward = require 'ssh-forward'
snowdock = require '../index'
retry = require '../../../VCP.API/IMD.VCP.API/ui/common/retry'

describe 'deploy'
  dockerRegistryDomain = nil
  dockerHost = nil
  dockerPort = nil
  imageName = nil

  beforeEach =>
    self.timeout 60000

    fs.writeFile 'nodeapp/views/index.txt' 'hi from <%= host %>'!
    shipyardHost = 'shipyard'
    vip = vagrantIp()!
    dockerRegistryDomain := "#(vip):5000"
    dockerHost := "http://#(vip)"
    dockerPort := 4243
    imageName := "#(dockerRegistryDomain)/nodeapp"

  describe.only 'snowdock'
    snowdockHost = nil
    snowdockLb = nil

    beforeEach
      snowdockHost := snowdock.host(host: 'http://snowdock', port: 4243)
      snowdockLb := snowdock.lb(host: 'http://snowdock', port: 4243)

    describe 'web clusters'
      beforeEach =>
        self.timeout (5 * 60 * 1000)
        snowdockLb.remove()!
        snowdockLb.run()!

        removeAllContainers(imageName: imageName)!
        snowdockHost.removeImage(imageName)!

      removeAllContainers(imageName: nil) =
        docker = @new Docker(host: dockerHost, port: dockerPort)
        [
          c <- docker.listContainers ^!
          r/^(.*):/.exec(c.Image).1 == imageName
          cont = docker.getContainer (c.Id)
          cont.remove {force = true} ^!
        ]
      
      it 'can create a web cluster' =>
        self.timeout (5 * 60 * 1000)
        port = 80
        containers = snowdockHost.runWebCluster {image = imageName, ports = ["#(port)"]} (nodes: 2)!
        console.log (containers)
      
      xit 'run container' =>
        self.timeout (5 * 60 * 1000)
        container = snowdockHost.runContainer {image = imageName}!
        container.status()!.State.Running.should.equal (true)

    describe 'load balancer'
      beforeEach =>
        self.timeout (5 * 60 * 1000)
        snowdockLb.remove()!

      shouldBeRunning()! =
        retry(timeout: 10000)!
          response = httpism.get 'http://snowdock/' (exceptions: false)!
          response.statusCode.should.equal 400
          response.body.should.match r/no application configured/i

      shouldNotBeRunning()! =
        httpism.get 'http://snowdock/' (exceptions: false).should.eventually.be.rejectedWith 'connect ECONNREFUSED'!

      it "doesn't have the load balancer running"
        shouldNotBeRunning()!

      it 'installs hipache' =>
        self.timeout (5 * 60 * 1000)

        snowdockLb.run()!
        shouldBeRunning()!

      context 'given that it is installed'
        beforeEach =>
          self.timeout (5 * 60 * 1000)
          snowdockLb.run()!

        it 'can stop it and start it again' =>
          self.timeout (5 * 60 * 1000)
          snowdockLb.stop()!
          shouldNotBeRunning()!

          snowdockLb.run()!
          shouldBeRunning()!

  context 'given a built image'
    shipyard = nil
    apikey = nil

    beforeEach =>
      apikey := shipyardApiKey(host: shipyardHost)!

      shipyard := connectToShipyard {
        apiUrl = "http://#(shipyardHost):8000/api/v1/"
        apiKey = "admin:#(apikey)"
      }

      shipyard.deleteApplication 'nodeapp'!
      shipyard.deleteContainersUsingImage 'nodeapp'!

      self.timeout 60000
      buildDockerImage (imageName: imageName, dir: 'nodeapp')!
      pullImage (imageName)!

    it 'should not have anything running'
      shipyard.containersUsingImage 'nodeapp'!.length.should.eql 0
      should.not.exist(shipyard.applicationByName 'nodeapp'!)

    it 'can deploy an app' =>
      self.timeout 60000

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

      it 'can deploy an update to the app' =>
        self.timeout 60000

        shipyard.application! {
          domain_name = 'nodeapp'
          containers = shipyard.4 containersFromImage (imageName)!
        }

        waitFor 4 backendsToRespond (host: 'nodeapp', responseRegex: r/^hi from (.*)$/)!

        monitor.start()

        makeChangeToApp()!
        buildDockerImage (imageName: imageName, dir: 'nodeapp')!
        pullImage (imageName)!

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
          response = httpism.get "http://#(shipyardHost)/" (headers: {host = host}, exceptions: false)!
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

  dockerSSH(block)! =
    sshForward! {
      hostname = 'vagrant@shipyard'
      remoteHost = 'localhost'
      remotePort = dockerPort
      localPort = 6000
    } @(port)
      block(host: 'http://localhost', port: port)!

  pullImage (imageName)! =
    console.log 'pulling image'
    // dockerSSH! @(host: nil, port: nil)
    host = 'http://localhost'
    port = 4243
    console.log 'have ssh port' (port)
    promise! @(result, error)
      docker = @new Docker(host: host, port: port)
      docker.pull (imageName) @(e, stream)
        console.log 'pulling' (e)
        if (e)
          error(e)
        else
          stream.setEncoding 'utf-8'

          stream.on 'data' @(data)
            console.log '.'

          stream.on 'end'
            result()

          stream.resume()

    console.log 'finished'

  waitFor (n) backendsToRespond (host: nil, responseRegex: nil, timeout: 5000)! =
    promise @(result, error)
      setTimeout
        error(@new Error "failed to get reponses from all #(n) hosts")
      (timeout)

      nodeapp = httpism.api 'http://rhel/' (headers: {host = host})

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
