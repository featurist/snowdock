Docker = require 'dockerode'
_ = require 'underscore'

connectToDocker(host) =
  @new Docker(host: host.host, port: host.port)

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
    runWebCluster! (containerConfig, nodes: 1) =
      [
        i <- [1..nodes]
        self.runContainer (containerConfig)!
      ]

    runContainer (containerConfig) =
      createOptions = {
        Image = containerConfig.image
        name = containerConfig.name
      }

      if (@not self.image(containerConfig.image).status()!)
        console.log "no image: #(containerConfig.image), pulling"
        self.pullImage(containerConfig.image)!

      console.log "creating container"
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
            console.log "pulling #(imageName)"
            stream.setEncoding 'utf-8'

            stream.on 'data' @(data)
              process.stdout.write '.'

            stream.on 'end'
              process.stdout.write "\n"
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
      hipache = hipacheHost.status(hipacheName)!
      if (hipache)
        hipache.State.Running

    run() =
      installed = self.isInstalled()!
      if (@not self.isInstalled()!)
        hipacheHost.runContainer! {
          image = 'hipache'
          name = hipacheName
          ports = ['80:80', '6379:6379']
        }
      else
        if (@not self.isRunning()!)
          hipache = docker.getContainer(hipacheName)
          hipache.start(^)!

    stop() =
      if (self.isRunning()!)
        hipache = docker.getContainer(hipacheName)
        hipache.stop(^)!

    remove() =
      try
        hipache = docker.getContainer(hipacheName)
        hipache.remove {force = true} ^!
      catch (e)
        if (e.reason != 'no such container')
          throw (e)
  }
