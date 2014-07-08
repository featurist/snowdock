Docker = require 'dockerode'
_ = require 'underscore'
redis = require 'redis'

connectToDocker(host) =
  @new Docker(host: 'http://' + host.host, port: host.port)

container (name, host, docker) =
  {
    status() =
      container = docker.getContainer(name)
      try
        container.inspect(^)!
      catch (e)
        if (e.statusCode == 404)
          nil
        else
          throw (e)

    name = name

    remove()! =
      container = docker.getContainer(name)
      container.remove {force = true} ^!
  }

image (name, host, docker) =
  {
    remove()! =
      image = docker.getImage(name)
      try
        image.remove(^)!
        true
      catch (e)
        if (e.statusCode == 404)
          false
        else
          throw (e)

    status()! =
      image = docker.getImage(name)
      try
        image.inspect (^)!
      catch (e)
        if (e.statusCode == 404)
          nil
        else
          throw (e)

    name = name
  }

hipache (redisHost) =
  hipacheRedis = redis.createClient(redisHost.port, redisHost.host)
  
  frontendKey (hostname) = "frontend:#(hostname)"
  backendKey (hostname) = "backend:#(hostname)"
  frontendHost (h) = "http://#(h.host):#(h.port)"

  {
    addBackends(hosts, hostname: nil) =
      hipacheRedis.on 'error' @{}

      len = hipacheRedis.llen (frontendKey(hostname)) ^!
      if (len == 0)
        hipacheRedis.rpush(frontendKey(hostname), hostname, ^)!

      [
        h <- hosts
        hipacheRedis.rpush(frontendKey(hostname), "http://#(h.host):#(h.port)", ^)!
      ]

    backendsByHostname(hostname) =
      [h <- hipacheRedis.lrange (backendKey(hostname), 0, -1) ^!, JSON.parse(h)]

    removeBackends(hosts, hostname: nil) =
      [
        h <- hosts
        hipacheRedis.lrem (frontendKey(hostname), 0, frontendHost(h)) ^!
      ]

    setBackends(hosts, hostname: nil) =
      [
        h <- hosts
        hipacheRedis.rpush(backendKey(hostname), JSON.stringify(h), ^)!
      ]
  }

exports.host (host) =
  docker = connectToDocker(host)

  portBinding (port) =
    match = r/((([0-9.]*):)?(\d+):)?(\d+)/.exec(port)
    if (match)
      {
        hostIp = match.3
        hostPort = match.4
        containerPort = match.5
      }
    else
      @throw @new Error "expected port binding to be \"[[host-ip:]host-port:]container-port\", but got #(port)"

  portBindings (ports, create: false) =
    if (ports)
      bindings = {}

      for each @(port) in (ports)
        binding = portBinding(port)
        bindings."#(binding.containerPort)/tcp" =
          if (create)
            {}
          else
            [{HostPort = binding.hostPort, HostIp = binding.hostIp}]

      bindings

  {
    runWebCluster! (containerConfig, nodes: 1, hostname: nil) =
      h = hipache(host.redis)

      existingBackends = h.backendsByHostname(hostname)!

      self.pullImage(containerConfig.image)!

      backends = [
        i <- [1..nodes]
        container = self.runContainer (containerConfig)!
        port = container.status()!.HostConfig.PortBindings."#(portBinding(containerConfig.ports.0).containerPort)/tcp".0.HostPort
        {port = port, container = container.name, host = host.lbHost @or host.host}
      ]

      setTimeout ^ 2000!

      h.addBackends! (backends, hostname: hostname)
      h.removeBackends! (existingBackends, hostname: hostname)
      h.setBackends! (backends, hostname: hostname)

      [
        b <- existingBackends
        self.container(b.container).remove()!
      ]

    runContainer (containerConfig) =
      createOptions = {
        Image = containerConfig.image
        name = containerConfig.name
      }

      if (@not self.image(containerConfig.image).status()!)
        self.pullImage(containerConfig.image)!

      container = docker.createContainer(createOptions, ^)!

      startOptions = {
        PortBindings = portBindings(containerConfig.ports)
      }

      container.start (startOptions, ^)!
      self.container(container.id)

    container(name) = container(name, self, docker)
    image(name) = image(name, self, docker)

    status(name) =
      self.container(name).status()!

    removeImage(name)! =
      self.image(name).remove()!

    pullImage (imageName)! =
      promise! @(result, error)
        docker.pull (imageName) @(e, stream)
          if (e)
            error(e)
          else
            stream.setEncoding 'utf-8'

            stream.on 'end'
              result()

            stream.resume()

      self.image(imageName)
  }

exports.lb (host) =
  docker = connectToDocker(host)
  hipacheName = 'snowdock-hipache'
  hipacheHost = exports.host(host)

  {
    isInstalled()! =
      hipacheHost.status(hipacheName)!

    isRunning()! =
      h = hipacheHost.status(hipacheName)!
      if (h)
        h.State.Running

    run() =
      if (@not self.isInstalled()!)
        hipacheHost.runContainer! {
          image = 'hipache'
          name = hipacheName
          ports = ['80:80', '6379:6379']
        }
      else
        if (@not self.isRunning()!)
          h = docker.getContainer(hipacheName)
          h.start(^)!

    stop() =
      if (self.isRunning()!)
        h = docker.getContainer(hipacheName)
        h.stop(^)!

    remove() =
      try
        h = docker.getContainer(hipacheName)
        h.remove {force = true} ^!
      catch (e)
        if (e.reason != 'no such container')
          throw (e)
  }
