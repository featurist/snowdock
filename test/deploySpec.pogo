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
redis = require 'redis'
require 'longjohn'
waitForSocket = require 'waitforsocket'

describe 'snowdock'
  dockerRegistryDomain = nil
  dockerHost = nil
  dockerPort = nil
  imageName = nil
  vip = nil
  min = (n) mins = n * 60 * 1000
  config = nil

  beforeEach =>
    self.timeout (5 mins)

    fs.writeFile 'nodeapp/views/index.txt' 'hi from <%= host %>'!
    vip := vagrantIp()!
    dockerRegistryDomain := "#(vip):5000"
    dockerHost := "http://#(vip)"
    dockerPort := 4243
    imageName := "#(dockerRegistryDomain)/nodeapp"

    removeAllContainers(command: 'node_modules/.bin/pogo index.pogo')!
    removeAllContainers(imageName: 'hipache')!

    config := {
      hosts = [
        {
          docker = {
            host = vip
            port = 4243
          }
          redis = {
            host = vip
            port = 6379
          }
          internalIp = "172.17.42.1"
        }
      ]
      websites = [
        {
          nodes = 4
          hostname  = 'nodeapp'
          container = {
            image = imageName
            ports = ["80"]
          }
        }
      ]
    }

    snowdock.host(config.hosts.0).removeImage(imageName)!

  findContainers(imageName: nil, command: nil) =
    docker = @new Docker(host: dockerHost, port: dockerPort)
    [
      c <- docker.listContainers ^!
      if (imageName)
        new (RegExp "^#(imageName):?").test(c.Image)
      else if (command)
        c.Command == command

      cont = docker.getContainer (c.Id)
    ]

  removeAllContainers(opts) =
    [
      cont <- findContainers(opts)!
      cont.remove {force = true} ^!
    ]

  shouldBeRunning()! =
    retry(timeout: 10000)!
      response = httpism.get "http://#(vip)/" (exceptions: false)!
      response.statusCode.should.equal 400
      response.body.should.match r/no application configured/i

    retry(timeout: 2000)!
      hipacheRedis = redis.createClient(6379, vip)
      hipacheRedis.on 'error' @{}
      hipacheRedis.info(^)!

  shouldNotBeRunning()! =
    httpism.get "http://#(vip)/" (exceptions: false).should.eventually.be.rejectedWith 'connect ECONNREFUSED'!
    hipacheRedis = redis.createClient(6379, vip)
    hipacheRedis.on 'error' @{}
    hipacheRedis.info(^).should.eventually.be.rejectedWith 'connect ECONNREFUSED'!

  it 'installs and runs load balancer' =>
    self.timeout (5 mins)
    snowdock.cluster(config).install()!
    shouldBeRunning()!

  it "doesn't have the load balancer running"
    shouldNotBeRunning()!

  context 'when it is installed'
    cluster = nil

    beforeEach =>
      self.timeout (5 mins)
      cluster := snowdock.cluster(config)
      cluster.install()!
      waitForSocket(vip, 6379, timeout: 2000)!

    it 'can create a web cluster' =>
      self.timeout (5 mins)

      cluster.deployWebsites()!
      waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp', responseRegex: r/^hi from (.*)$/)!

    context 'with no service interruption'
      monitor = nil

      beforeEach
        monitor := serviceMonitor(host: vip, hostname: 'nodeapp')

      afterEach
        monitor.stop()

        monitor.totalInterruptionTime.should.equal 0
        should.not.exist(monitor.error)

      it 'can update a web cluster' =>
        self.timeout (5 mins)

        cluster.deployWebsites()!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp', responseRegex: r/^hi from (.*)$/)!

        makeChangeToApp('v2')!
        buildDockerImage (imageName: imageName, dir: 'nodeapp')!

        cluster.deployWebsites()!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp', responseRegex: r/^hi from (.*), v2$/)!

        makeChangeToApp('v3')!
        buildDockerImage (imageName: imageName, dir: 'nodeapp')!

        cluster.deployWebsites()!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp', responseRegex: r/^hi from (.*), v3$/)!

    it 'can stop the load balancer and start it again' =>
      self.timeout (5 * 60 * 1000)
      cluster.stop()!
      shouldNotBeRunning()!

      cluster.start()!
      shouldBeRunning()!

    it 'uninstalls the load balancer and all containers' =>
      self.timeout (5 * 60 * 1000)

      cluster.deployWebsites()!
      waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp', responseRegex: r/^hi from (.*)$/)!

      config2 = JSON.parse(JSON.stringify(config))
      config2.websites = []
      cluster2 = snowdock.cluster(config2)
      cluster2.uninstall()!

      findContainers(command: 'node_modules/.bin/pogo index.pogo')!.should.eql []
      findContainers(imageName: 'hipache')!.should.eql []

  serviceMonitor(host: nil, hostname: nil) =
    interval = nil
    timeOfLastError = nil

    {
      start () =
        setInterval
          response = httpism.get "http://#(host)/" (headers: {host = hostname}, exceptions: false)!
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

  makeChangeToApp(version) =
    fs.writeFile 'nodeapp/views/index.txt' "hi from <%= host %>, #(version)"!

  buildDockerImage (imageName: nil, dir: nil) =
    process.chdir "#(__dirname)/.."
    child_process.exec "docker build -t #(imageName) #(dir)" ^!
    child_process.exec "docker push #(imageName)" ^!

  waitFor (n) backendsToRespond (host: nil, hostname: nil, responseRegex: nil, timeout: 5000)! =
    promise @(result, error)
      setTimeout
        error(@new Error "failed to get reponses from all #(n) hosts")
      (timeout)

      nodeapp = httpism.api "http://#(host)/" (headers: {host = hostname})

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
