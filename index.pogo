Docker = require 'dockerode'
fs = require 'fs'
_ = require 'underscore'
redis = require 'then-redis'
sshForward = require 'ssh-forward'
substitute = require 'shellsubstitute'
portfinder = require 'portfinder'
waitForSocket = require 'waitforsocket'

connectToDocker(config) =
  log.debug "connecting to docker '#("#(config.protocol @or 'http')://" + config.host):#(config.port)'"
  @new Docker(config)

exports.close() =
  closeRedisConnections()!
  sshTunnels.close()!

redisClients = []

closeRedisConnections() =
  [
    c <- redisClients
    try
      c.quit()!
    catch (e)
      c.end()
  ]

  redisClients := []

closeSshConnections() =
  [c <- sshConnections, c.close()!]

connectToRedis(config) =
  log.debug "connecting to redis '#(config.host):#(config.port)'"
  client = redis.createClient(port: config.port, host: config.host)
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

  configForContainer(name) =
    containerConfig = config.containers.(name)

    if (containerConfig)
      containerConfig
    else
      @throw @new Error "no such container defined #(name)"

  {
    startWebsite(name)! =
      self.startProxy()!
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
      self.startProxy()!
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
      containerConfig = configForContainer(name)
      [host <- hosts(), host.start (_.extend({name = name}, containerConfig))!]

    update(name)! =
      containerConfig = configForContainer(name)
      [host <- hosts(), host.update (_.extend({name = name}, containerConfig))!]

    stop(name)! =
      [host <- hosts(), host.container(name).stop()!]

    remove(name)! =
      [host <- hosts(), host.container(name).remove(force: true)!]

    status() =
      stripCerts(config) =
        c = JSON.parse(JSON.stringify(config))
        delete (c.docker.ca)
        delete (c.docker.cert)
        delete (c.docker.key)
        c

      [
        hostKey <- Object.keys(config.hosts)
        hostConfig = config.hosts.(hostKey)
        host = exports.host(hostConfig)
        status = host.status(config)!
        {
          name = hostKey
          host = stripCerts(hostConfig)
          containers = status.containers
          proxy = status.proxy
        }
      ]
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

      _.extend {} (service) { host = 'localhost', port = port }
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

    waitForService(serviceName) =
      connectionDetails = connectToSsh(host.(serviceName))!
      waitForSocket(connectionDetails.host, connectionDetails.port, timeout: 2000)!

    status(config) =
      r = redisDb()!

      scan(pattern, keys, cursor) =
        keys := keys @or []
        cursor := cursor @or "0"

        results = r.scan(cursor @or 0, 'match', pattern)!
        keys.push(results.1, ...)

        if (results.0 != "0")
          scan(pattern, keys, results.0)!
        else
          keys

      websites = [
        key <- scan('frontend:*')!
        values = r.lrange(key, 0, -1)!
        {
          host = values.0
          frontends = [
            frontend <- values.slice(1)
            frontend
          ]
        }
      ]

      backends = [
        backendKey <- scan('backend:*')!
        backend <- r.lrange(backendKey, 0, -1)!
        JSON.parse(backend)
      ]

      containers = [
        c <- docker()!.listContainers(^)!
        {
          id = c.Id
          status = c
        }
      ]

      containersIndex = _.indexBy (containers) 'id'

      for each @(b) in (backends)
        if (containersIndex.(b.container))
          containersIndex.(b.container).backend = b

      containersByUrl = _.indexBy [c <- containers, c.backend, c] @(c)
        "http://#(c.backend.host):#(c.backend.port)"

      websitesByHostname = _.indexBy[wsName <- Object.keys(config.websites @or {}), { name = wsName, website = config.websites.(wsName) }] @(w)
        w.website.hostname

      for each @(w) in (websites)
        for each @(f) in (w.frontends)
          cont = containersByUrl.(f)
          if (cont)
            cont.frontend = f
            cont.websiteHostname = w.host
            websiteConfig = websitesByHostname.(w.host)
            if (websiteConfig)
              cont.websiteConfig = websiteConfig.website
              cont.websiteConfigName = websiteConfig.name

            cont.proxyCorrect =
              f == "http://#(cont.backend.host):#(cont.backend.port)" \
              @and cont.status.Ports.0.PublicPort == Number(cont.backend.port)

      for each @(conta) in (containers)
        name = conta.status.Names.0.substring(1)
        if (name == 'snowdock-hipache')
          conta.proxyConfig = (config.websites @and config.websites.proxy) @or {}
        else
          if (config.containers)
            conta.containerConfig = config.containers.(name)
            if (conta.containerConfig)
              conta.containerConfigName = name

      proxyStatus = self.proxy().status()!

      {
        containers = containers
        proxy = nil
      }

    start(containerConfig)! =
      c = self.container(containerConfig.name)
      if (c.status()!)
        c.start()!
      else
        self.runContainer(containerConfig)!

    update(containerConfig)! =
      c = self.container(containerConfig.name)

      self.pullImage(containerConfig.image)!

      if (c.status()!)
        c.remove(force: true)!

      self.runContainer(containerConfig)!

    runContainer (containerConfig) =
      log.debug "running container with image '#(containerConfig.image)'"

      if (@not self.image(containerConfig.image).status()!)
        self.pullImage(containerConfig.image)!

      createOptions = {
        Image = containerConfig.image
        name = containerConfig.name
        Env = environmentVariables(containerConfig.env)
        ExposedPorts = portBindings(containerConfig.publish, create = true)

        HostConfig = {
          Binds = containerConfig.volumes
          Links = containerConfig.links
          VolumesFrom = containerConfig.volumesFrom
          NetworkMode = containerConfig.net
          PortBindings = portBindings(containerConfig.publish)
          Privileged = containerConfig.privileged
        }
      }

      c = docker()!.createContainer(createOptions, ^)!
      c.start ({}, ^)!
      self.container(c.id)

    container(name) = container(name, self, docker)
    image(name) = image(name, self, docker)
    website(websiteConfig) = website(websiteConfig, self, docker)

    ensureImagePresent! (imageName) =
      if (@not self.image(imageName).status()!)
        self.pullImage! (imageName)

    pullImage (imageName)! =
      i = parseImageName(imageName)

      if (i.fromImage.indexOf '/' != -1)
        if (host.docker.auth)
          log.debug "pulling image '#(imageName)' as user '#(host.docker.auth.username)'"
        else
          log.debug "pulling image '#(imageName)'"

        promise! @(result, error)
          docker()!.createImage (host.docker.auth, i) @(e, stream)
            if (e)
              error(e)
            else
              stream.setEncoding 'utf-8'

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

              stream.on ('error', error)

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
      c = docker()!.getContainer(name)
      try
        c.inspect(^)!
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
        c = docker()!.getContainer(name)
        c.remove {force = force} ^!
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
      i = docker()!.getImage(name)
      try
        i.remove({force = force}, ^)!
        true
      catch (e)
        if (e.statusCode == 404)
          false
        else
          throw (e)

    status()! =
      i = docker()!.getImage(name)
      try
        i.inspect (^)!
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

  status() =
    lb = host.proxy()
    existingBackends = lb.backendsByHostname(websiteConfig.hostname)!

    [
      b <- existingBackends
      status = host.container(b.container).status()!
      {
        port = b.port
        host = b.host
        publishedPorts = [
          port <- Object.keys(status.NetworkSettings.Ports)
          binding <- status.NetworkSettings.Ports.(port)
          {
            port = port
            internalPort = binding.HostPort
          }
        ]
        container = host.container(b.container).status()!
      }
    ]

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

    status() =
      host.container(hipacheName).status()!

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

      host.waitForService('redis')!

    stop() =
      if (self.isRunning()!)
        h = docker()!.getContainer(hipacheName)
        h.stop(^)!

    remove() =
      if (self.isRunning()!)
        [
          key <- redisDb()!.keys(backendKey '*')!
          hostname = key.split ':'.1
          host.website { hostname = hostname }.remove()!
        ]

      host.container(hipacheName).remove(force: true)!

    addBackends(hosts, hostname: nil) =
      log.debug "adding hosts: #([h <- hosts, "http://#(h.host):#(h.port)"].join ', ')"
      r = redisDb()!

      len = r.llen (frontendKey(hostname))!
      if (len == 0)
        r.rpush(frontendKey(hostname), hostname)!

      [
        h <- hosts
        r.rpush(frontendKey(hostname), "http://#(h.host):#(h.port)")!
      ]

    backendsByHostname(hostname) =
      r = redisDb()!
      [h <- r.lrange (backendKey(hostname), 0, -1)!, JSON.parse(h)]

    removeBackends(hosts, hostname: nil) =
      log.debug "removing hosts: #([h <- hosts, "http://#(h.host):#(h.port)"].join ', ')"
      r = redisDb()!

      [
        h <- hosts
        r.lrem (frontendKey(hostname), 0, frontendHost(h))!
      ]

    setBackends(hosts, hostname: nil) =
      log.debug "setting hosts: #([h <- hosts, "http://#(h.host):#(h.port)"].join ', ')"
      r = redisDb()!

      r.del(backendKey(hostname))!
      [
        h <- hosts
        r.rpush(backendKey(hostname), JSON.stringify(h))!
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
      "#(key)=#(substitute(env.(key), process.env))"
    ]

sshTunnels =
  tunnels = []
  tunnelCache = {}

  {
    open(config)! =
      key = "#(config.host):#(config.port):#(config.user):#(config.command)"

      if (@not tunnelCache.(key))
        openPort() =
          localPort = portfinder.getPort(^)!
          // we have the port, so we need to prevent it being found again
          // before SSH uses it. Remember this is a concurrent app!
          portfinder.basePort = localPort + 1
          log.debug "opening SSH tunnel to #(config.host):#(config.port) on #(localPort)"
          tunnel = sshForward! {
            hostname =
              if (config.user)
                "#(config.user)@#(config.host)"
              else
                config.host

            localPort = localPort
            remoteHost = 'localhost'
            remotePort = config.port
            command = config.command
          }

          tunnels.push {
            config = config
            port = localPort
            close() = tunnel.close()!
          }

          localPort

        tunnelCache.(key) = openPort()
      else
        log.debug "using cached SSH tunnel to #(config.host):#(config.port)"

      (tunnelCache.(key))!

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

parseImageName = exports.parseImageName (imageName) =
  match = r/^([^\/:]+(:\d+)?\/[^:]+)(:(.*))?$/.exec(imageName)

  if (match.4)
    {
      fromImage = match.1
      tag = match.4
    }
  else
    {
      fromImage = match.1
    }
