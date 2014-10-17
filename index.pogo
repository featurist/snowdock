Docker = require 'dockerode'
_ = require 'underscore'
redis = require 'redis'
sshForward = require 'ssh-forward'

connectToDocker(config) =
  log.debug "connecting to docker '#('http://' + config.host):#(config.port)'"
  @new Docker(host: 'http://' + config.host, port: config.port)

exports.close() =
  closeRedisConnections()!
  sshTunnels.close()!

redisClients = []

closeRedisConnections() =
  [
    c <- redisClients
    try
      c.quit(^)!
    catch (e)
      c.end(^)!
  ]

  redisClients := []

closeSshConnections() =
  [c <- sshConnections, c.close()!]

connectToRedis(config) =
  log.debug "connecting to redis '#(config.host):#(config.port)'"
  client = redis.createClient(config.port, config.host)
  redisClients.push(client)
  client

sshConnections = []

exports.cluster (config) =
  withLoadBalancers (block) =
    [
      hostKey <- Object.keys(config.hosts)
      hostConfig = config.hosts.(hostKey)
      lb = exports.host(hostConfig).proxy()
      block(lb)!
    ]

  withWebsites (block) =
    [
      hostKey <- Object.keys(config.hosts)
      hostConfig = config.hosts.(hostKey)
      host = exports.host(hostConfig)
      websiteKey <- Object.keys(config.websites)
      websiteConfig = config.websites.(websiteKey)
      block(host, websiteConfig)!
    ]

  hosts () =
    [
      hostKey <- Object.keys(config.hosts)
      hostConfig = config.hosts.(hostKey)
      exports.host(hostConfig)
    ]

  {
    startWebsite(name)! =
      [
        host <- hosts()
        host.website (config.websites.(name)).start()!
      ]

    stopWebsite(name)! =
      [
        host <- hosts()
        host.website (config.websites.(name)).stop()!
      ]

    updateWebsite(name)! =
      [
        host <- hosts()
        host.website (config.websites.(name)).update()!
      ]

    removeWebsite(name)! =
      [
        host <- hosts()
        host.website (config.websites.(name)).remove()!
      ]

    startProxy()! =
      withLoadBalancers! @(lb)
        lb.start(config.websites.proxy)!

    removeProxy()! =
      withLoadBalancers! @(lb)
        lb.remove()!

    stopProxy()! =
      withLoadBalancers! @(lb)
        lb.stop()!

    start(name)! =
      containerConfig = config.containers.(name)

      if (containerConfig)
        [host <- hosts(), host.start (_.extend({name = name}, containerConfig))!]
      else
        @throw @new Erorr "no such container defined #(name)"

    update(name)! =
      containerConfig = config.containers.(name)

      [host <- hosts(), host.update (_.extend({name = name}, containerConfig))!]

    stop(name)! =
      [host <- hosts(), host.container(name).stop()!]

    remove(name)! =
      [host <- hosts(), host.container(name).remove(force: true)!]
  }

exports.host (host) =
  connectToSsh(service)! =
    if (host.ssh)
      port = sshTunnels.open! {
        host = service.host
        port = service.port
        command = host.ssh.command
        user = host.ssh.user
      }

      { host = 'localhost', port = port }
    else
      service

  docker =
    dockerClient = nil
    cachedDocker()! =
      if (dockerClient)
        dockerClient
      else
        dockerClient := connectToDocker(connectToSsh(host.docker)!)

  redisDb =
    client = nil
    cachedRedisDb()! =
      if (client)
        client
      else
        client := connectToRedis(connectToSsh(host.redis)!)
        client.on 'error' @{}
        client

  {
    internalIp = host.internalIp

    proxy() = proxy(self, docker, redisDb)

    start(containerConfig)! =
      container = self.container(containerConfig.name)
      if (container.status()!)
        container.start()!
      else
        self.runContainer(containerConfig)!

    update(containerConfig)! =
      container = self.container(containerConfig.name)

      self.pullImage(containerConfig.image)!

      if (container.status()!)
        container.remove(force: true)!

      self.runContainer(containerConfig)!

    runContainer (containerConfig) =
      log.debug "running container with image '#(containerConfig.image)'"

      if (@not self.image(containerConfig.image).status()!)
        self.pullImage(containerConfig.image)!

      createOptions = {
        Image = containerConfig.image
        name = containerConfig.name
        Volumes = volumes(containerConfig.volumes)
        Env = environmentVariables(containerConfig.env)
      }

      container = docker()!.createContainer(createOptions, ^)!

      startOptions = {
        PortBindings = portBindings(containerConfig.publish)
        NetworkMode = containerConfig.net
      }

      container.start (startOptions, ^)!
      self.container(container.id)

    container(name) = container(name, self, docker)
    image(name) = image(name, self, docker)
    website(websiteConfig) = website(websiteConfig, self, docker)

    status(name) =
      self.container(name).status()!

    ensureImagePresent! (imageName) =
      if (@not self.image(imageName).status()!)
        self.pullImage! (imageName)

    pullImage (imageName)! =
      image = parseImageName(imageName)

      if (image.fromImage.indexOf '/' != -1)
        if (host.docker.auth)
          log.debug "pulling image '#(imageName)' as user '#(host.docker.auth.username)'"
        else
          log.debug "pulling image '#(imageName)'"

        promise! @(result, error)
          docker()!.createImage (host.docker.auth, image) @(e, stream)
            if (e)
              error(e)
            else
              stream.setEncoding 'utf-8'

              if (false)
                stream.on 'data' @(data)
                  try
                    obj = JSON.parse(data)
                    if (obj.error)
                      error(obj.error)
                    else
                      console.log(obj.status)
                  catch (e)
                    console.log(data)
                    nil

              stream.on 'end'
                result()

              stream.resume()

        log.debug "pulled image '#(imageName)'"
      else
        log.debug "not pulling local image '#(imageName)'"

      self.image(imageName)
  }

container (name, host, docker) =
  {
    status() =
      container = docker()!.getContainer(name)
      try
        container.inspect(^)!
      catch (e)
        if (e.statusCode == 404)
          nil
        else
          throw (e)

    port(internalPort) =
      port = self.status()!.NetworkSettings.Ports."#(internalPort)/tcp".0.HostPort
      log.debug "port for container: #(name), #(internalPort)/tcp -> #(port)"
      port

    name = name

    remove(force: false)! =
      try
        log.debug "removing container '#(name)'"
        container = docker()!.getContainer(name)
        container.remove {force = force} ^!
        true
      catch (e)
        if (e.reason != 'no such container')
          throw (e)
        else
          false

    start()! =
      log.debug "starting container '#(name)'"
      docker()!.getContainer(name).start(^)!

    stop()! =
      log.debug "stopping container '#(name)'"
      docker()!.getContainer(name).stop(^)!

    isRunning()! =
      h = self.status()!
      if (h)
        h.State.Running
  }

image (name, host, docker) =
  {
    remove(force: false)! =
      log.debug "removing image '#(name)'"
      image = docker()!.getImage(name)
      try
        image.remove({force = force}, ^)!
        true
      catch (e)
        if (e.statusCode == 404)
          false
        else
          throw (e)

    status()! =
      image = docker()!.getImage(name)
      try
        image.inspect (^)!
      catch (e)
        if (e.statusCode == 404)
          nil
        else
          throw (e)

    name = name
  }

website (websiteConfig, host, docker) = {
  start! () =
    lb = host.proxy()
    existingBackends = lb.backendsByHostname(websiteConfig.hostname)!

    backends =
      if (existingBackends.length > 0)
        containers = [
          b <- existingBackends
          host.container(b.container)
        ]

        [
          container <- containers
          container.start()!
        ]

        lb.removeBackends! (existingBackends, hostname: websiteConfig.hostname)

        self.backends!(containers)
      else
        host.ensureImagePresent! (websiteConfig.container.image)
        self.startBackends! ()

    self.waitForWebContainersToStart()!
    lb.addBackends! (backends, hostname: websiteConfig.hostname)
    lb.setBackends! (backends, hostname: websiteConfig.hostname)
    backends

  stop! () =
    lb = host.proxy()
    existingBackends = lb.backendsByHostname(websiteConfig.hostname)!

    if (existingBackends.length > 0)
      [
        b <- existingBackends
        host.container(b.container).stop()!
      ]

    lb.setBackends! ([], hostname: websiteConfig.hostname)

  update! () =
    log.debug "updating website '#(websiteConfig.hostname)'"
    lb = host.proxy()

    existingBackends = lb.backendsByHostname(websiteConfig.hostname)!

    host.pullImage(websiteConfig.container.image)!

    backends = self.startBackends! ()

    self.waitForWebContainersToStart()!

    log.debug "setting up backends"
    lb.addBackends! (backends, hostname: websiteConfig.hostname)
    lb.removeBackends! (existingBackends, hostname: websiteConfig.hostname)
    lb.setBackends! (backends, hostname: websiteConfig.hostname)

    log.debug "removing backends"
    [
      b <- existingBackends
      host.container(b.container).remove(force: true)!
    ]

    log.debug "deployed website"

  remove! () =
    hostname = websiteConfig.hostname
    log.debug "removing website '#(hostname)'"
    lb = host.proxy()

    existingBackends = lb.backendsByHostname(hostname)!

    lb.removeBackends! (existingBackends, hostname: hostname)
    lb.setBackends! ([], hostname: hostname)

    [
      b <- existingBackends
      host.container(b.container).remove(force: true)!
    ]

  waitForWebContainersToStart()! =
    log.debug "waiting 2000"
    setTimeout ^ 2000!

  backends(containers) =
    [
      container <- containers
      port = container.port(portBinding(websiteConfig.container.publish.0).containerPort)!
      {port = port, container = container.name, host = host.internalIp}
    ]
    

  startBackends! () =
    self.backends! [
      i <- [1..websiteConfig.nodes]
      host.runContainer (websiteConfig.container)!
    ]
}

proxy (host, docker, redisDb) =
  hipacheName = 'snowdock-hipache'
  hipacheImageName = 'library/hipache'

  frontendKey (hostname) = "frontend:#(hostname)"
  backendKey (hostname) = "backend:#(hostname)"
  frontendHost (h) = "http://#(h.host):#(h.port)"

  {
    isInstalled()! =
      host.container(hipacheName).status()!

    isRunning()! =
      host.container(hipacheName).isRunning()!

    start(config) =
      if (@not self.isInstalled()!)
        host.runContainer! (_.extend {
          image = hipacheImageName
          name = hipacheName
          publish = ['80:80', '6379:6379']
        } (config))
      else
        if (@not self.isRunning()!)
          host.container(hipacheName).start()!

    stop() =
      if (self.isRunning()!)
        h = docker()!.getContainer(hipacheName)
        h.stop(^)!

    remove() =
      if (self.isRunning()!)
        [
          key <- redisDb()!.keys(backendKey '*', ^)!
          hostname = key.split ':'.1
          host.website { hostname = hostname }.remove()!
        ]

      host.container(hipacheName).remove(force: true)!

    addBackends(hosts, hostname: nil) =
      log.debug "adding hosts: #([h <- hosts, "http://#(h.host):#(h.port)"].join ', ')"
      redis = redisDb()!

      len = redis.llen (frontendKey(hostname)) ^!
      if (len == 0)
        redis.rpush(frontendKey(hostname), hostname, ^)!

      [
        h <- hosts
        redis.rpush(frontendKey(hostname), "http://#(h.host):#(h.port)", ^)!
      ]

    backendsByHostname(hostname) =
      redis = redisDb()!

      [h <- redis.lrange (backendKey(hostname), 0, -1) ^!, JSON.parse(h)]

    removeBackends(hosts, hostname: nil) =
      log.debug "removing hosts: #([h <- hosts, "http://#(h.host):#(h.port)"].join ', ')"
      redis = redisDb()!

      [
        h <- hosts
        redis.lrem (frontendKey(hostname), 0, frontendHost(h)) ^!
      ]

    setBackends(hosts, hostname: nil) =
      log.debug "setting hosts: #([h <- hosts, "http://#(h.host):#(h.port)"].join ', ')"
      redis = redisDb()!

      redis.del(backendKey(hostname), ^)!
      [
        h <- hosts
        redis.rpush(backendKey(hostname), JSON.stringify(h), ^)!
      ]
  }

log = {
  debug (msg, ...) = console.log(msg, ...)
}

portBindings (ports, create: false) =
  if (ports)
    bindings = {}

    for each @(port) in ((ports) toArray)
      binding = portBinding(port)
      bindings."#(binding.containerPort)/tcp" =
        if (create)
          {}
        else
          [{HostPort = binding.hostPort, HostIp = binding.hostIp}]

    bindings

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

(s) toArray =
  if (s :: Array)
    s
  else if (s)
    [s]
  else
    []

volumes(vols) =
  v = {}

  for each @(vol) in ((vols) toArray)
    split = vol.split ':'

    v.(split.0) =
      if (split.1)
        mapping = {}
        mapping.(split.1) = split.2 @or 'rw'
        mapping
      else
        {}

  v

environmentVariables(env) =
  if (env)
    [
      key <- Object.keys(env)
      "#(key)=#(env.(key))"
    ]

sshTunnels =
  tunnels = []
  port = 42468
  tunnelCache = {}

  {
    open(config)! =
      key = "#(config.host):#(config.port):#(config.user):#(config.command)"

      if (@not tunnelCache.(key))
        log.debug "opening SSH tunnel to #(config.host):#(config.port) on #(port)"
        tunnel = sshForward! {
          hostname =
            if (config.user)
              "#(config.user)@#(config.host)"
            else
              config.host

          localPort = port
          remoteHost = 'localhost'
          remotePort = config.port
          command = config.command
        }
        tunnelCache.(key) = port
        tunnels.push {
          config = config
          port = port
          close() = tunnel.close()!
        }
        port := port + 1
      else
        log.debug "using cached SSH tunnel to #(config.host):#(config.port) on #(port)"

      tunnelCache.(key)

    close()! =
      [
        t <- tunnels
        @{
          log.debug "closing SSH tunnel to #(t.config.host):#(t.config.port) on #(t.port)"
          t.close()!
        }()!
      ]
      tunnels := []
  }

parseImageName(imageName) =
  match = r/^(.*):([^\/:]*)$|^(.*)$/.exec(imageName)

  if (match.4)
    {
      fromImage = match.1
      tag = match.2
    }
  else
    {
      fromImage = match.3
    }
