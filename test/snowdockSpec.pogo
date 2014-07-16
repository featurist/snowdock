httpism = require 'httpism'
fs = require 'fs'
vagrantIp = require './vagrantIp'
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
waitForSocket = require 'waitforsocket'

describe 'snowdock' =>
  min = (n) mins = n * 60 * 1000

  self.timeout (5 mins)

  dockerRegistryDomain = nil
  dockerHost = nil
  dockerPort = nil
  imageName = nil
  vip = nil
  config = nil

  beforeEach

    makeChangeToApp(1)!
    vip := vagrantIp()!
    dockerRegistryDomain := "#(vip):5000"
    dockerHost := "http://#(vip)"
    dockerPort := 4243
    imageName := "#(dockerRegistryDomain)/nodeapp"

    removeAllContainers(command: 'node_modules/.bin/pogo index.pogo')!
    removeAllContainers(imageName: 'hipache')!

    config := {
      hosts = {
        "vagrant" = {
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
      }
      websites = {
        "nodeapp" = {
          nodes = 4
          hostname  = 'nodeapp'
          container = {
            image = imageName
            publish = ["80"]
          }
        }
      }
    }

    snowdock.host(config.hosts.vagrant).image(imageName).remove(force: true)!
    buildDockerImage (imageName: imageName, dir: 'nodeapp')!

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

  proxyShouldBeRunning(hipachePort: 80)! =
    retry(timeout: 10000)!
      response = httpism.get "http://#(vip):#(hipachePort)/" (exceptions: false)!
      response.statusCode.should.equal 400
      response.body.should.match r/no application configured/i

    retry(timeout: 2000)!
      hipacheRedis = redis.createClient(6379, vip)
      hipacheRedis.on 'error' @{}
      hipacheRedis.info(^)!

  proxyShouldNotBeRunning()! =
    httpism.get "http://#(vip)/" (exceptions: false).should.eventually.be.rejectedWith 'connect ECONNREFUSED'!
    hipacheRedis = redis.createClient(6379, vip)
    hipacheRedis.on 'error' @{}
    hipacheRedis.info(^).should.eventually.be.rejectedWith 'connect ECONNREFUSED'!

  describeApi (api) =
    beforeEach
      api.setConfig! (config)!
      api.before()!

    it 'installs and runs proxy'
      api.startProxy()!
      proxyShouldBeRunning()!

    it "doesn't have the proxy running"
      proxyShouldNotBeRunning()!

    it 'can start the proxy with container options'
      api.setConfig! {
        hosts = config.hosts
        websites = {
          proxy = {
            publish = ['8000:80', '6379:6379']
          }
        }
      }
      api.startProxy()!

      proxyShouldBeRunning(hipachePort: 8000)!

    context 'when it is installed'
      beforeEach
        api.startProxy()!
        console.log "waiting for socket: #(vip):#(6379)"
        waitForSocket(vip, 6379, timeout: 2000)!

      it 'can start a website'
        api.startWebsite 'nodeapp'!
        console.log "waiting for backends"
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

      it 'can start, stop and start a website'
        api.startWebsite 'nodeapp'!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

        api.stopWebsite 'nodeapp'!
        httpism.get "http://#(vip)" (exceptions: false)!.statusCode.should.equal 400

        api.startWebsite 'nodeapp'!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

      context 'with no service interruption'
        monitor = nil

        beforeEach
          monitor := serviceMonitor(host: vip, hostname: 'nodeapp')

        afterEach
          monitor.stop()

          monitor.totalInterruptionTime.should.equal 0
          should.not.exist(monitor.error)

        it 'can update a website'
          api.updateWebsite 'nodeapp'!
          waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

          makeChangeToApp(2)!
          buildDockerImage (imageName: imageName, dir: 'nodeapp')!

          api.updateWebsite 'nodeapp'!
          waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp', version: 2)!

          makeChangeToApp(3)!
          buildDockerImage (imageName: imageName, dir: 'nodeapp')!

          api.updateWebsite 'nodeapp'!
          waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp', version: 3)!

      it 'can stop the proxy and start it again'
        api.stopProxy()!
        proxyShouldNotBeRunning()!

        api.startProxy()!
        proxyShouldBeRunning()!

      it 'removes the proxy and all website containers'
        api.startWebsite 'nodeapp'!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

        config2 = JSON.parse(JSON.stringify(config))
        config2.websites = {}
        api.setConfig! (config2)
        api.removeProxy()!

        findContainers(command: 'node_modules/.bin/pogo index.pogo')!.should.eql []
        findContainers(imageName: 'hipache')!.should.eql []

      describe 'containers'
        it 'can start a container'
          api.setConfig! {
            hosts = config.hosts
            containers = {
              nodeapp = {
                image = imageName
                publish = ['8000:80']
                volumes = ['/blah']
              }
            }
          }
          api.run 'nodeapp'!

          httpism.get "http://#(vip):8000"!.body.message.should.equal 'hi from nodeapp'
          status = snowdock.host (config.hosts.vagrant).container('nodeapp').status()!
          should.exist(status)
          status.HostConfig.PortBindings.should.eql { '80/tcp' = [{ HostIp = '0.0.0.0', HostPort = '8000' }] }
          status.VolumesRW.should.eql { '/blah' = true }

  describe 'api'
    api =
      cluster = nil
      clusterConfig = nil

      {
        before() =
          clusterConfig := config
          cluster := snowdock.cluster(clusterConfig)

        startProxy()! = cluster.startProxy()!
        removeProxy()! = cluster.removeProxy()!
        startWebsite(name)! = cluster.startWebsite(name)!
        stopWebsite(name)! = cluster.stopWebsite(name)!
        updateWebsite(name)! = cluster.updateWebsite(name)!
        stopProxy()! = cluster.stopProxy()!
        run(args, ...)! = cluster.run(args, ...)!

        setConfig(c) =
          clusterConfig := c
          cluster := snowdock.cluster(clusterConfig)
      }

    describeApi (api)

  describe 'command line'
    commandLine =
      cluster = nil
      clusterConfig = nil

      spawn(command, args, ...)! =
        console.log "launching #(command) #(args.join ' ')"
        promise @(result, error)
          process = child_process.spawn(command, args, stdio: 'inherit')

          process.on 'error' @(e)
            console.log "error: #(e)"
            error(e)

          process.on 'close' @(exitCode)
            console.log "exited: #(exitCode)"
            if (exitCode == 0)
              result(exitCode)
            else
              error(@new Error "command #(command) #(args.join ' ') exited with #(exitCode)")

      api = {
        before() =
          fs.writeFile "#(__dirname)/snowdock.json" (JSON.stringify(config)) ^!

        setConfig(c) =
          fs.writeFile "#(__dirname)/snowdock.json" (JSON.stringify(c)) ^!
      }

      for each @(cmd) in ('startProxy removeProxy deploy start stop run'.split ' ')
        @(cmd)@{
          commandLineCommand = cmd.replace r/([A-Z])/g @(l) @{ ' ' + l.toLowerCase() }.trim()
          api.(cmd) (args, ...)! = spawn "bin/snowdock" (commandLineCommand) "-c" "#(__dirname)/snowdock.json" (args) ...!
        }(cmd)

      api

    describeApi (commandLine)

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
    fs.writeFile 'nodeapp/version.txt' "#(version)"!

  buildDockerImage (imageName: nil, dir: nil) =
    process.chdir "#(__dirname)/.."
    child_process.exec "docker build -t #(imageName) #(dir)" ^!
    child_process.exec "docker push #(imageName)" ^!

  waitFor (n) backendsToRespond (host: nil, hostname: nil, version: 1, timeout: 5000)! =
    promise @(result, error)
      setTimeout
        error(@new Error "failed to get reponses from all #(n) hosts")
      (timeout)

      nodeapp = httpism.api "http://#(host)/" (headers: {host = hostname})

      requestAHost(hosts) =
        body = nodeapp.get ''!.body
        if (body.message == 'hi from nodeapp' @and body.version == version)
          hosts.(body.host) = true
          if (Object.keys(hosts).length < n)
            requestAHost (hosts)!
        else
          error(@new Error "unexpected response from host: #(JSON.stringify(body))")

      result(requestAHost {}!)
