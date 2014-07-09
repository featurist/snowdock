Docker = require 'dockerode'
_ = require 'underscore'
redis = require 'redis'

connectToDocker(host) =
  @new Docker(host: 'http://' + host.docker.host, port: host.docker.port)

connectToRedis(host) =
  redis.createClient(host.redis.port, host.redis.host)

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

exports.cluster (config) =
  withLoadBalancers (block) =
    [
      hostConfig <- config.hosts
      lb = exports.host(hostConfig).loadBalancer()
      block(lb)!
    ]
    
  {
    deployWebsites()! =
      [
        hostConfig <- config.hosts
        host = exports.host(hostConfig)
        websiteConfig <- config.websites
        host.deployWebsite! (websiteConfig)
      ]

    removeWebsites()! =
      [
        hostConfig <- config.hosts
        host = exports.host(hostConfig)
        websiteConfig <- config.websites
        host.removeWebsite! (websiteConfig.hostname)
      ]

    install()! =
      withLoadBalancers @(lb)
        lb.install()!

    uninstall()! =
      self.removeWebsites()!
      withLoadBalancers @(lb)
        lb.uninstall()!

    start()! =
      withLoadBalancers @(lb)
        lb.start()!

    stop()! =
      withLoadBalancers @(lb)
        lb.stop()!
  }

exports.host (host) =
  docker = connectToDocker(host)
  redisDb =
    client = nil
    @()
      if (client)
        client
      else
        client := connectToRedis(host)
        client.on 'error' @{}
        client

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
    deployWebsite! (websiteConfig) =
      lb = self.loadBalancer()

      existingBackends = lb.backendsByHostname(websiteConfig.hostname)!

      self.pullImage(websiteConfig.container.image)!

      backends = [
        i <- [1..websiteConfig.nodes]
        container = self.runContainer (websiteConfig.container)!
        port = container.status()!.HostConfig.PortBindings."#(portBinding(websiteConfig.container.ports.0).containerPort)/tcp".0.HostPort
        {port = port, container = container.name, host = host.internalIp}
      ]

      setTimeout ^ 2000!

      lb.addBackends! (backends, hostname: websiteConfig.hostname)
      lb.removeBackends! (existingBackends, hostname: websiteConfig.hostname)
      lb.setBackends! (backends, hostname: websiteConfig.hostname)

      [
        b <- existingBackends
        self.container(b.container).remove()!
      ]

    removeWebsite! (hostname) =
      lb = self.loadBalancer()

      existingBackends = lb.backendsByHostname(hostname)!

      lb.removeBackends! (existingBackends, hostname: hostname)
      lb.setBackends! ([], hostname: hostname)

      [
        b <- existingBackends
        self.container(b.container).remove()!
      ]
      
    loadBalancer() = loadBalancer(self, docker, redisDb)

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
        NetworkMode = containerConfig.net
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

loadBalancer (host, docker, redisDb) =
  hipacheName = 'snowdock-hipache'

  frontendKey (hostname) = "frontend:#(hostname)"
  backendKey (hostname) = "backend:#(hostname)"
  frontendHost (h) = "http://#(h.host):#(h.port)"

  {
    isInstalled()! =
      host.status(hipacheName)!

    isRunning()! =
      h = host.status(hipacheName)!
      if (h)
        h.State.Running

    install() =
      if (@not self.isInstalled()!)
        host.runContainer! {
          image = 'hipache'
          name = hipacheName
          ports = ['80:80', '6379:6379']
        }
      else
        if (@not self.isRunning()!)
          h = docker.getContainer(hipacheName)
          h.start(^)!

    start() =
      if (@not self.isInstalled()!)
        throw (new (Error "not installed"))
      else
        if (@not self.isRunning()!)
          h = docker.getContainer(hipacheName)
          h.start(^)!

    stop() =
      if (self.isRunning()!)
        h = docker.getContainer(hipacheName)
        h.stop(^)!

    uninstall() =
      [
        key <- redisDb().keys(backendKey '*', ^)!
        hostname = key.split ':'.1
        host.removeWebsite(hostname)!
      ]

      try
        h = docker.getContainer(hipacheName)
        h.remove {force = true} ^!
      catch (e)
        if (e.reason != 'no such container')
          throw (e)

    addBackends(hosts, hostname: nil) =
      len = redisDb().llen (frontendKey(hostname)) ^!
      if (len == 0)
        redisDb().rpush(frontendKey(hostname), hostname, ^)!

      [
        h <- hosts
        redisDb().rpush(frontendKey(hostname), "http://#(h.host):#(h.port)", ^)!
      ]

    backendsByHostname(hostname) =
      [h <- redisDb().lrange (backendKey(hostname), 0, -1) ^!, JSON.parse(h)]

    removeBackends(hosts, hostname: nil) =
      [
        h <- hosts
        redisDb().lrem (frontendKey(hostname), 0, frontendHost(h)) ^!
      ]

    setBackends(hosts, hostname: nil) =
      redisDb().del(backendKey(hostname), ^)!
      [
        h <- hosts
        redisDb().rpush(backendKey(hostname), JSON.stringify(h), ^)!
      ]
  }
