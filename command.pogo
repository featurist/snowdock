argv = (require 'minimist')(process.argv.slice 2)
snowdock = require './'
fs = require 'fs'

command = argv._.shift()

filename = argv.c @or argv.config @or 'snowdock.json'
console.log "reading config file: #(filename)"
cluster = snowdock.cluster(JSON.parse(fs.readFile (filename, 'utf-8', ^)!))

try
  if (command == 'start')
    startContainer = argv._.shift()

    if (startContainer == 'proxy')
      cluster.startProxy()!
    else if (startContainer == 'website')
      cluster.startWebsite(argv._.shift())!
    else
      cluster.start(startContainer)!
  else if (command == 'remove')
    removeContainer = argv._.shift()

    if (removeContainer == 'proxy')
      cluster.removeProxy()!
    else if (removeContainer == 'website')
      cluster.removeWebsite(argv._.shift())!
    else
      cluster.remove(removeContainer)!
  else if (command == 'update')
    updateContainer = argv._.shift()

    if (updateContainer == 'website')
      cluster.updateWebsite(argv._.shift())!
    else
      cluster.update(updateContainer)!
  else if (command == 'stop')
    stopContainer = argv._.shift()

    if (stopContainer == 'proxy')
      cluster.stopProxy()!
    else if (stopContainer == 'website')
      cluster.stopWebsite(argv._.shift())!
    else
      cluster.stop(stopContainer)!
  else
    console.log "no such command: #(command)"
catch (e)
  console.log (e)
  process.exit(1)
finally
  snowdock.closeRedisConnections()
