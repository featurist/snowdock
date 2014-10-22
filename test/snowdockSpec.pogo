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
retry = require 'trytryagain'
redis = require 'redis'
waitForSocket = require 'waitforsocket'

describe 'snowdock' =>
  min = (n) mins = n * 60 * 1000
  sec = (n) secs = n * 1000

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
    removeAllContainers(imageName: 'library/hipache')!

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
      c <- docker.listContainers { all = true } ^!
      if (imageName)
        new (RegExp "^#(imageName):?").test(c.Image)
      else if (command)
        c.Command == command

      docker.getContainer (c.Id)
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

    afterEach =>
      self.timeout (30 secs)
      api.after()!

    it 'starts proxy'
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
        waitForSocket(vip, 6379, timeout: 2000)!

      it 'can start a website'
        api.startWebsite 'nodeapp'!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

      it 'can start a website over ssh'
        config2 = clone(config)
        config2.hosts.vagrant.ssh = {
          command = "ssh -i #(process.env.HOME)/.vagrant.d/insecure_private_key"
          user = 'vagrant'
        }
        api.setConfig! (config2)

        api.startWebsite 'nodeapp'!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

      it 'can start, stop and start a website'
        self.timeout 60000

        api.startWebsite 'nodeapp'!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

        api.stopWebsite 'nodeapp'!
        httpism.get "http://#(vip)" (exceptions: false)!.statusCode.should.equal 400

        api.startWebsite 'nodeapp'!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp', timeout: 35000)!

      it 'can start and remove a website'
        api.startWebsite 'nodeapp'!
        waitFor 4 backendsToRespond (host: vip, hostname: 'nodeapp')!

        api.removeWebsite 'nodeapp'!

        httpism.get "http://#(vip)" (exceptions: false)!.statusCode.should.equal 400
        findContainers(command: 'node_modules/.bin/pogo index.pogo')!.should.eql []

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

        config2 = clone(config)
        config2.websites = {}
        api.setConfig! (config2)
        api.removeProxy()!

        findContainers(command: 'node_modules/.bin/pogo index.pogo')!.should.eql []
        findContainers(imageName: 'library/hipache')!.should.eql []

      describe 'containers'
        beforeEach
          api.setConfig! {
            hosts = config.hosts
            containers = {
              nodeapp = {
                image = imageName
                publish = ['8000:80']
                volumes = ['/blah']
                env = { PASSWORD = 'password123' }
              }
            }
          }

        it 'can start a container'
          api.start 'nodeapp'!

          retry!
            httpism.get "http://#(vip):8000"!.body.message.should.equal 'hi from nodeapp'

          container = snowdock.host (config.hosts.vagrant).container('nodeapp')
          status = container.status()!
          should.exist(status)
          status.HostConfig.PortBindings.should.eql { '80/tcp' = [{ HostIp = '', HostPort = '8000' }] }
          status.VolumesRW.should.eql { '/blah' = true }
          status.Config.Env.should.contain 'PASSWORD=password123'
          snowdock.host (config.hosts.vagrant).container('nodeapp').status()!
          container.port(80)!.should.equal '8000'

        it 'can start, stop and start a container'
          api.start 'nodeapp'!
          retry!
            httpism.get "http://#(vip):8000"!.body.message.should.equal 'hi from nodeapp'
            findContainers(command: 'node_modules/.bin/pogo index.pogo')!.length.should.eql 1

          api.stop 'nodeapp'!
          retry!
            httpism.get "http://#(vip):8000/".should.eventually.be.rejectedWith 'connect ECONNREFUSED'!
            findContainers(command: 'node_modules/.bin/pogo index.pogo')!.length.should.eql 1

          api.start 'nodeapp'!
          retry!
            httpism.get "http://#(vip):8000"!.body.message.should.equal 'hi from nodeapp'
            findContainers(command: 'node_modules/.bin/pogo index.pogo')!.length.should.eql 1

        it 'update a container'
          api.start 'nodeapp'!
          retry!
            firstBody = httpism.get "http://#(vip):8000"!.body
            firstBody.message.should.equal 'hi from nodeapp'
            firstBody.version.should.equal 1
            findContainers(command: 'node_modules/.bin/pogo index.pogo')!.length.should.eql 1

          makeChangeToApp(2)!
          buildDockerImage (imageName: imageName, dir: 'nodeapp')!

          api.update 'nodeapp'!
          retry!
            secondBody = httpism.get "http://#(vip):8000"!.body
            secondBody.message.should.equal 'hi from nodeapp'
            secondBody.version.should.equal 2
            findContainers(command: 'node_modules/.bin/pogo index.pogo')!.length.should.eql 1

        it 'remove a container'
          api.start 'nodeapp'!
          retry!
            firstBody = httpism.get "http://#(vip):8000"!.body
            firstBody.message.should.equal 'hi from nodeapp'
            firstBody.version.should.equal 1
            findContainers(command: 'node_modules/.bin/pogo index.pogo')!.length.should.eql 1

          api.remove 'nodeapp'!
          retry!
            httpism.get "http://#(vip):8000/".should.eventually.be.rejectedWith 'connect ECONNREFUSED'!
            findContainers(command: 'node_modules/.bin/pogo index.pogo')!.length.should.eql 0

  describe 'api'
    api =
      cluster = nil
      clusterConfig = nil

      {
        before() =
          clusterConfig := config
          cluster := snowdock.cluster(clusterConfig)

        after() =
          snowdock.close()!

        startProxy()! = cluster.startProxy()!
        removeProxy()! = cluster.removeProxy()!
        stopProxy()! = cluster.stopProxy()!
        startWebsite(name)! = cluster.startWebsite(name)!
        removeWebsite(name)! = cluster.removeWebsite(name)!
        stopWebsite(name)! = cluster.stopWebsite(name)!
        updateWebsite(name)! = cluster.updateWebsite(name)!
        start(name)! = cluster.start(name)!
        update(name)! = cluster.update(name)!
        stop(name)! = cluster.stop(name)!
        remove(name)! = cluster.remove(name)!

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

        after() = nil

        setConfig(c) =
          fs.writeFile "#(__dirname)/snowdock.json" (JSON.stringify(c)) ^!
      }

      for each @(cmd) in ('startProxy stopProxy removeProxy startWebsite updateWebsite stopWebsite removeWebsite start update stop remove'.split ' ')
        @(cmd)@{
          commandLineCommand = cmd.replace r/([A-Z])/g @(l) @{ ' ' + l.toLowerCase() }.trim().split ' '
          api.(cmd) (args, ...)! = spawn "bin/snowdock" "-c" "#(__dirname)/snowdock.json" (commandLineCommand, ..., args, ...)!
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
    console.log "building #(imageName)"
    child_process.exec "docker build -t #(imageName) #(dir)" ^!
    console.log "pushing #(imageName)"
    child_process.exec "docker push #(imageName)" ^!

  waitFor (n) backendsToRespond (host: nil, hostname: nil, version: 1, timeout: 5000)! =
    promise @(result, error)
      nodeapp = httpism.api "http://#(host)/" (headers: {host = hostname})

      requestAHost(hosts, timeout) =
        if (@new Date().getTime() < timeout)
          body = nodeapp.get ''!.body
          if (body.message == 'hi from nodeapp' @and body.version == version)
            if (@not hosts.(body.host))
              console.log "got response from #(body.host)"

            hosts.(body.host) = true
            if (Object.keys(hosts).length < n)
              requestAHost (hosts, timeout)!
          else
            error(@new Error "unexpected response from host: #(JSON.stringify(body))")
        else
          error(@new Error "only got reponses from #(Object.keys(hosts).length) of #(n) hosts")

      result(requestAHost ({}, @new Date ().getTime() + timeout)!)

  clone(object) = JSON.parse(JSON.stringify(object))
