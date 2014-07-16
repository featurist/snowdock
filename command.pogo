argv = (require 'minimist')(process.argv.slice 2)
snowdock = require './'
fs = require 'fs'

command = argv._.shift()

filename = argv.c @or argv.config @or 'snowdock.json'
console.log "reading config file: #(filename)"
cluster = snowdock.cluster(JSON.parse(fs.readFile (filename, 'utf-8', ^)!))

try
  if (command == 'start')
    container = argv._.shift()

    if (container == 'all')
    else if (container == 'proxy')
      cluster.startProxy()!
    else if (container == 'website')
      cluster.startWebsite(argv._.shift())!
    else
      cluster.start(container)!
  else if (command == 'uninstall')
    cluster.uninstall()!
  else if (command == 'deploy')
    cluster.deployWebsites()!
  else if (command == 'start')
    cluster.start()!
  else if (command == 'stop')
    cluster.stop()!
  else if (command == 'remove')
    cluster.removeWebsites()!
  else if (command == 'run')
    cluster.run(argv._, ...)!
  else
    console.log "no such command: #(command)"
catch (e)
  console.log (e)
  process.exit(1)
finally
  snowdock.closeRedisConnections()
