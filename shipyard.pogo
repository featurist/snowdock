urlUtils = require 'url'
_ = require 'underscore'

module.exports (apiUrl: nil, proxy: nil, apiKey: nil, containerPort: 80) =
  idFromLocation (location) = urlUtils.parse (location).path

  http = require './shipyardClient'.api (apiUrl, shipyard: {apiKey = apiKey})

  {
    container (c) =
      allHosts = self.allHosts()!

      c := _.extend {
        ports = [containerPort.toString()]
        hosts = self.allHosts()!
      } (c)

      waitForContainer (containerId) toSync =
        response = http.get (containerId)!.body
        if (@not response.synced)
          setTimeout ^ 500!
          waitForContainer (containerId) toSync!

      response = http.post ('containers/', c)!
      console.log "created container" (c)
      containerId = idFromLocation (response.headers.location)
      console.log "waiting for container #(containerId) to sync"
      waitForContainer (containerId) toSync!
      console.log "created container #(containerId)"
      containerId

    applicationByName (name) =
      [
        app <- http.get 'applications/'!.body.objects
        app.name == name
        app
      ].0

    containers ()! =
      http.get 'containers/'!.body

    containersUsingImage (imageName) =
      re = @new RegExp "^(.*/)?#(imageName)$"
      [
        container <- http.get 'containers/'!.body.objects
        re.test (container.meta.Config.Image)
        container
      ]

    destroyContainer (containerId) =
      console.log "destroying #(containerId)"
      console.log(http.get "#(containerId)destroy/"!.body)

    application (app) =
      app := _.extend {
        name = app.domain_name
        backend_port = containerPort
        protocol = 'http'
        description = ''
      } (app)

      createApplication (app) =
        response = http.post ('applications/', app)!

        idFromLocation (response.headers.location)

      updateApplication (uri, app) =
        response = http.put (uri, app)!

        uri

      existingApplication = self.applicationByName (app.name)!

      if (existingApplication)
        console.log 'found existing app' (existingApplication)
        console.log 'updating app' (app)
        location = updateApplication (existingApplication.resource_uri, app)!
        [container <- existingApplication.containers, self.destroyContainer (container.resource_uri)!]
        location
      else
        console.log 'creating app' (app)
        createApplication (app)!

    allHosts() =
      if (self._allHosts)
        self._allHosts
      else
        self._allHosts = [host <- http.get 'hosts/'!.body.objects, host.resource_uri]

    (n) containersFromImage (image) =
      [
        n <- [1..(n)]
        self.container! {
          image = image
        }
      ]

    image (repo) =
      http.post 'images/import/' {
        repo_name = repo
      }!

    deleteApplication (name)! =
      app = self.applicationByName (name)!
      if (app)
        http.delete (app.resource_uri)!

    deleteContainersUsingImage (imageName)! =
      [container <- self.containersUsingImage (imageName)!, self.destroyContainer (container.resource_uri)!]
  }
